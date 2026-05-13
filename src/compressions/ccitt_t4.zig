//! CCITT Group 3 (T.4) 1D modified-Huffman decoder.
//!
//! Compression code 3 in TIFF. Used by 1990s fax machines and 1-bit
//! scanned documents. Per ITU-T T.4 §4.1.4:
//!
//! Each scan-line is a sequence of run-length codes, alternating
//! white and black runs (every line starts with a white run, which
//! may be zero-length). Runs of length 0..63 are encoded as a single
//! "terminating" code; runs ≥ 64 use a "make-up" code (multiples of
//! 64, up to 2560) followed by a terminating code for the remainder.
//! White and black have separate Huffman tables.
//!
//! Each row begins with the EOL synchronization code: 12 bits, value
//! 000000000001 (0x001). Some encoders pad the row to a byte boundary
//! before the next EOL (T4Options bit 2 = "EOL byte alignment");
//! we honor that.
//!
//! TIFF FillOrder tag (266) is honored: 1 = MSB-first within each
//! storage byte (default), 2 = LSB-first (common for fax-origin data).
//!
//! 2D mode (T4Options bit 0) is NOT supported in this module — that's
//! M4-E territory (CCITT G4 / T.6 shares the 2D state machine).
//! Files with the 2D bit set will surface as Malformed; the
//! decoder.zig dispatcher returns UnsupportedCompression in that case.

const std = @import("std");

const errors = @import("../errors.zig");

pub const FillOrder = enum { msb_first, lsb_first };

/// Decode a single G3 1D-encoded strip. The strip must contain
/// `rows` complete scan-lines, each `width` pixels wide. Output is
/// 1-bit-per-pixel packed MSB-first into `dest`, one row per
/// `(width + 7) / 8` bytes. Bit value 1 = "ink" (canonically black,
/// before photometric interpretation flips it). The caller's
/// photometric expansion handles the eventual u8 polarity.
///
/// `eol_byte_align` corresponds to T4Options bit 2 ("EOL padding"):
/// when true, after each EOL the encoder pads zero bits up to the
/// next byte boundary before the next code starts. Both spec values
/// (true / false) round-trip.
pub fn decode(
    src: []const u8,
    dest: []u8,
    width: u32,
    rows: u32,
    fill_order: FillOrder,
    eol_byte_align: bool,
) errors.Error!usize {
    const bytes_per_row: usize = (@as(usize, width) + 7) / 8;
    const total_out: usize = bytes_per_row * rows;
    if (dest.len < total_out) return error.DestTooSmall;
    @memset(dest[0..total_out], 0);

    var reader = BitReader.init(src, fill_order);
    // Per TIFF 6.0 §11 + T.4: when T4Options bit 2 ("EOL byte aligned") is
    // set, the encoder pads zero bits BEFORE each EOL so that the EOL
    // itself starts at a byte boundary. syncToEol absorbs the leading
    // zeros (both the padding and the EOL prefix). After it returns, we
    // are mid-byte (12 bits past the byte boundary) and the next
    // line's data starts immediately — NO post-EOL alignment. The
    // `eol_byte_align` flag is therefore informational only at the
    // decoder's level; the syncToEol logic itself handles arbitrary
    // pre-EOL padding identically.
    _ = eol_byte_align;
    var rows_done: u32 = 0;
    while (rows_done < rows) : (rows_done += 1) {
        try reader.syncToEol();
        const row_dest = dest[rows_done * bytes_per_row ..][0..bytes_per_row];
        try decodeRow(&reader, row_dest, width);
    }
    return total_out;
}

/// Decode one scan-line: alternating white/black runs that sum to
/// `width`. Output bits set into `row_dest` MSB-first within bytes;
/// caller pre-zeroed dest, so we only set 1-bits.
fn decodeRow(reader: *BitReader, row_dest: []u8, width: u32) errors.Error!void {
    var x: u32 = 0;
    var color: Color = .white; // every row starts with a white run

    // Loop-progress guard: a malformed code stream that decodes as
    // alternating zero-runs would infinite-loop without this. Cap
    // total iterations at width × 2 (worst case: every pixel its own
    // alternating run).
    var safety_iters: u32 = 0;
    const safety_cap: u32 = (width + 1) * 2;

    while (x < width) {
        if (safety_iters > safety_cap) return error.Malformed;
        safety_iters += 1;

        var run: u32 = 0;
        // A make-up + terminating pair encodes one logical run.
        // Loop until a terminating code (run < 64) lands.
        var inner_iters: u32 = 0;
        while (true) {
            inner_iters += 1;
            if (inner_iters > 64) return error.Malformed; // > 64 make-ups in a single run is pathological
            const m = try matchCode(reader, color);
            run += m.run;
            if (m.kind == .terminating) break;
            if (run > std.math.maxInt(u24)) return error.Malformed; // sanity
        }
        if (x + run > width) return error.Malformed;
        if (color == .black and run > 0) {
            setBitsBlack(row_dest, x, run);
        }
        x += run;
        color = if (color == .white) .black else .white;
    }
}

const Color = enum { white, black };

const CodeKind = enum { terminating, makeup, extended_makeup };

const Match = struct {
    run: u32,
    kind: CodeKind,
};

/// Comptime-built lookup table indexed by `len * 8192 + acc`.
/// `len` ∈ 2..13 (white codes start at 4 bits, black at 2). Entries
/// for unmatched (len, acc) pairs are sentinel-filled. The result of
/// a lookup is either a valid Match or `null` (encoded via the
/// sentinel run = 0xFFFF).
///
/// Total entries: 14 × 8192 = 114688 per color = 229376 across both,
/// plus 14 × 8192 = 114688 for extended (color-independent) — three
/// flat u16 arrays of 229376 entries each. ~700 KB total but
/// compile-time-initialized into the static binary, zero runtime
/// cost to construct.
const Lookup = struct {
    /// run value, or 0xFFFF = no match.
    run: u16,
    kind: u8, // 0 = terminating, 1 = makeup, 2 = extended_makeup, 0xFF = none
};

const NO_MATCH: Lookup = .{ .run = 0xFFFF, .kind = 0xFF };

const white_lookup: [14][1 << 13]Lookup = buildLookupForColor(.white);
const black_lookup: [14][1 << 13]Lookup = buildLookupForColor(.black);

fn buildLookupForColor(comptime color: Color) [14][1 << 13]Lookup {
    @setEvalBranchQuota(2_000_000);
    var t: [14][1 << 13]Lookup = .{.{NO_MATCH} ** (1 << 13)} ** 14;

    const table = switch (color) {
        .white => &white_codes,
        .black => &black_codes,
    };
    for (table) |entry| {
        const kind: u8 = if (entry.run < 64) 0 else 1;
        t[entry.length][entry.bits] = .{ .run = entry.run, .kind = kind };
    }

    // Extended make-up codes are color-independent — included in both tables.
    for (extended_codes) |entry| {
        t[entry.length][entry.bits] = .{ .run = entry.run, .kind = 2 };
    }

    return t;
}

/// Read bits one at a time, accumulating MSB-first into a u16, and
/// look up against precomputed (len, acc)-keyed tables. Returns the
/// matched run + kind, or Malformed if no code matches within 13 bits.
fn matchCode(reader: *BitReader, color: Color) errors.Error!Match {
    var acc: u16 = 0;
    var len: u4 = 0;
    const table_ptr: *const [14][1 << 13]Lookup = switch (color) {
        .white => &white_lookup,
        .black => &black_lookup,
    };
    while (len < 13) {
        acc = (acc << 1) | (try reader.readBit());
        len += 1;
        const hit = table_ptr[len][acc];
        if (hit.run != 0xFFFF) {
            const kind: CodeKind = switch (hit.kind) {
                0 => .terminating,
                1 => .makeup,
                2 => .extended_makeup,
                else => unreachable,
            };
            return .{ .run = hit.run, .kind = kind };
        }
    }
    return error.Malformed;
}

fn setBitsBlack(row: []u8, start: u32, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const x: u32 = start + i;
        const byte_idx: usize = x / 8;
        const bit_idx: u3 = @intCast(7 - (x % 8));
        row[byte_idx] |= @as(u8, 1) << bit_idx;
    }
}

const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3,
    fill_order: FillOrder,

    fn init(data: []const u8, fill_order: FillOrder) BitReader {
        return .{ .data = data, .byte_pos = 0, .bit_pos = 0, .fill_order = fill_order };
    }

    /// Read one bit. Returns the bit's value (0 or 1). Advances the cursor.
    fn readBit(self: *BitReader) errors.Error!u1 {
        if (self.byte_pos >= self.data.len) return error.SourceTooShort;
        const byte = self.data[self.byte_pos];
        const bit_idx: u3 = switch (self.fill_order) {
            .msb_first => @intCast(7 - @as(u4, self.bit_pos)),
            .lsb_first => self.bit_pos,
        };
        const bit: u1 = @intCast((byte >> bit_idx) & 1);
        if (self.bit_pos == 7) {
            self.byte_pos += 1;
            self.bit_pos = 0;
        } else {
            self.bit_pos += 1;
        }
        return bit;
    }

    /// Skip 0-bits until we land on the EOL sync code. EOL is exactly
    /// 12 bits: eleven 0s followed by one 1. The encoder may pad the
    /// preceding row's last code with extra 0-bits before the EOL —
    /// either to the next byte boundary (T4Options bit 2) or to the
    /// minimum 11 zeros required. We handle both.
    fn syncToEol(self: *BitReader) errors.Error!void {
        var zeros: u32 = 0;
        while (true) {
            const b = try self.readBit();
            if (b == 0) {
                zeros += 1;
                continue;
            }
            // Saw a 1 bit. EOL requires ≥ 11 leading zeros.
            if (zeros >= 11) return; // EOL consumed
            // Spurious 1 inside the inter-line padding — the encoder
            // shouldn't emit this. Reset zero count and keep scanning;
            // a pathologically rare case in well-formed files.
            zeros = 0;
        }
    }

    /// Skip remaining bits in the current byte. After this call, the
    /// next read starts at bit_idx 0 of the next byte. T4Options bit 2
    /// "EOL byte alignment" requires this after every EOL.
    fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.byte_pos += 1;
            self.bit_pos = 0;
        }
    }
};

const TableEntry = struct {
    bits: u16,
    length: u4,
    run: u16,
};

// Tables transcribed from ITU-T T.4 §4.1.4 (Tables 1, 2 and 3).
// Reading the spec PDF is the primary source; libtiff's tif_fax3sm.c
// is a cross-check (BSD-3, MIT-compatible).

const white_codes = [_]TableEntry{
    // Terminating (lengths 0..63)
    .{ .bits = 0b00110101, .length = 8, .run = 0 },
    .{ .bits = 0b000111, .length = 6, .run = 1 },
    .{ .bits = 0b0111, .length = 4, .run = 2 },
    .{ .bits = 0b1000, .length = 4, .run = 3 },
    .{ .bits = 0b1011, .length = 4, .run = 4 },
    .{ .bits = 0b1100, .length = 4, .run = 5 },
    .{ .bits = 0b1110, .length = 4, .run = 6 },
    .{ .bits = 0b1111, .length = 4, .run = 7 },
    .{ .bits = 0b10011, .length = 5, .run = 8 },
    .{ .bits = 0b10100, .length = 5, .run = 9 },
    .{ .bits = 0b00111, .length = 5, .run = 10 },
    .{ .bits = 0b01000, .length = 5, .run = 11 },
    .{ .bits = 0b001000, .length = 6, .run = 12 },
    .{ .bits = 0b000011, .length = 6, .run = 13 },
    .{ .bits = 0b110100, .length = 6, .run = 14 },
    .{ .bits = 0b110101, .length = 6, .run = 15 },
    .{ .bits = 0b101010, .length = 6, .run = 16 },
    .{ .bits = 0b101011, .length = 6, .run = 17 },
    .{ .bits = 0b0100111, .length = 7, .run = 18 },
    .{ .bits = 0b0001100, .length = 7, .run = 19 },
    .{ .bits = 0b0001000, .length = 7, .run = 20 },
    .{ .bits = 0b0010111, .length = 7, .run = 21 },
    .{ .bits = 0b0000011, .length = 7, .run = 22 },
    .{ .bits = 0b0000100, .length = 7, .run = 23 },
    .{ .bits = 0b0101000, .length = 7, .run = 24 },
    .{ .bits = 0b0101011, .length = 7, .run = 25 },
    .{ .bits = 0b0010011, .length = 7, .run = 26 },
    .{ .bits = 0b0100100, .length = 7, .run = 27 },
    .{ .bits = 0b0011000, .length = 7, .run = 28 },
    .{ .bits = 0b00000010, .length = 8, .run = 29 },
    .{ .bits = 0b00000011, .length = 8, .run = 30 },
    .{ .bits = 0b00011010, .length = 8, .run = 31 },
    .{ .bits = 0b00011011, .length = 8, .run = 32 },
    .{ .bits = 0b00010010, .length = 8, .run = 33 },
    .{ .bits = 0b00010011, .length = 8, .run = 34 },
    .{ .bits = 0b00010100, .length = 8, .run = 35 },
    .{ .bits = 0b00010101, .length = 8, .run = 36 },
    .{ .bits = 0b00010110, .length = 8, .run = 37 },
    .{ .bits = 0b00010111, .length = 8, .run = 38 },
    .{ .bits = 0b00101000, .length = 8, .run = 39 },
    .{ .bits = 0b00101001, .length = 8, .run = 40 },
    .{ .bits = 0b00101010, .length = 8, .run = 41 },
    .{ .bits = 0b00101011, .length = 8, .run = 42 },
    .{ .bits = 0b00101100, .length = 8, .run = 43 },
    .{ .bits = 0b00101101, .length = 8, .run = 44 },
    .{ .bits = 0b00000100, .length = 8, .run = 45 },
    .{ .bits = 0b00000101, .length = 8, .run = 46 },
    .{ .bits = 0b00001010, .length = 8, .run = 47 },
    .{ .bits = 0b00001011, .length = 8, .run = 48 },
    .{ .bits = 0b01010010, .length = 8, .run = 49 },
    .{ .bits = 0b01010011, .length = 8, .run = 50 },
    .{ .bits = 0b01010100, .length = 8, .run = 51 },
    .{ .bits = 0b01010101, .length = 8, .run = 52 },
    .{ .bits = 0b00100100, .length = 8, .run = 53 },
    .{ .bits = 0b00100101, .length = 8, .run = 54 },
    .{ .bits = 0b01011000, .length = 8, .run = 55 },
    .{ .bits = 0b01011001, .length = 8, .run = 56 },
    .{ .bits = 0b01011010, .length = 8, .run = 57 },
    .{ .bits = 0b01011011, .length = 8, .run = 58 },
    .{ .bits = 0b01001010, .length = 8, .run = 59 },
    .{ .bits = 0b01001011, .length = 8, .run = 60 },
    .{ .bits = 0b00110010, .length = 8, .run = 61 },
    .{ .bits = 0b00110011, .length = 8, .run = 62 },
    .{ .bits = 0b00110100, .length = 8, .run = 63 },
    // Make-up (64..1728 in steps of 64)
    .{ .bits = 0b11011, .length = 5, .run = 64 },
    .{ .bits = 0b10010, .length = 5, .run = 128 },
    .{ .bits = 0b010111, .length = 6, .run = 192 },
    .{ .bits = 0b0110111, .length = 7, .run = 256 },
    .{ .bits = 0b00110110, .length = 8, .run = 320 },
    .{ .bits = 0b00110111, .length = 8, .run = 384 },
    .{ .bits = 0b01100100, .length = 8, .run = 448 },
    .{ .bits = 0b01100101, .length = 8, .run = 512 },
    .{ .bits = 0b01101000, .length = 8, .run = 576 },
    .{ .bits = 0b01100111, .length = 8, .run = 640 },
    .{ .bits = 0b011001100, .length = 9, .run = 704 },
    .{ .bits = 0b011001101, .length = 9, .run = 768 },
    .{ .bits = 0b011010010, .length = 9, .run = 832 },
    .{ .bits = 0b011010011, .length = 9, .run = 896 },
    .{ .bits = 0b011010100, .length = 9, .run = 960 },
    .{ .bits = 0b011010101, .length = 9, .run = 1024 },
    .{ .bits = 0b011010110, .length = 9, .run = 1088 },
    .{ .bits = 0b011010111, .length = 9, .run = 1152 },
    .{ .bits = 0b011011000, .length = 9, .run = 1216 },
    .{ .bits = 0b011011001, .length = 9, .run = 1280 },
    .{ .bits = 0b011011010, .length = 9, .run = 1344 },
    .{ .bits = 0b011011011, .length = 9, .run = 1408 },
    .{ .bits = 0b010011000, .length = 9, .run = 1472 },
    .{ .bits = 0b010011001, .length = 9, .run = 1536 },
    .{ .bits = 0b010011010, .length = 9, .run = 1600 },
    .{ .bits = 0b011000, .length = 6, .run = 1664 },
    .{ .bits = 0b010011011, .length = 9, .run = 1728 },
};

const black_codes = [_]TableEntry{
    // Terminating (lengths 0..63)
    .{ .bits = 0b0000110111, .length = 10, .run = 0 },
    .{ .bits = 0b010, .length = 3, .run = 1 },
    .{ .bits = 0b11, .length = 2, .run = 2 },
    .{ .bits = 0b10, .length = 2, .run = 3 },
    .{ .bits = 0b011, .length = 3, .run = 4 },
    .{ .bits = 0b0011, .length = 4, .run = 5 },
    .{ .bits = 0b0010, .length = 4, .run = 6 },
    .{ .bits = 0b00011, .length = 5, .run = 7 },
    .{ .bits = 0b000101, .length = 6, .run = 8 },
    .{ .bits = 0b000100, .length = 6, .run = 9 },
    .{ .bits = 0b0000100, .length = 7, .run = 10 },
    .{ .bits = 0b0000101, .length = 7, .run = 11 },
    .{ .bits = 0b0000111, .length = 7, .run = 12 },
    .{ .bits = 0b00000100, .length = 8, .run = 13 },
    .{ .bits = 0b00000111, .length = 8, .run = 14 },
    .{ .bits = 0b000011000, .length = 9, .run = 15 },
    .{ .bits = 0b0000010111, .length = 10, .run = 16 },
    .{ .bits = 0b0000011000, .length = 10, .run = 17 },
    .{ .bits = 0b0000001000, .length = 10, .run = 18 },
    .{ .bits = 0b00001100111, .length = 11, .run = 19 },
    .{ .bits = 0b00001101000, .length = 11, .run = 20 },
    .{ .bits = 0b00001101100, .length = 11, .run = 21 },
    .{ .bits = 0b00000110111, .length = 11, .run = 22 },
    .{ .bits = 0b00000101000, .length = 11, .run = 23 },
    .{ .bits = 0b00000010111, .length = 11, .run = 24 },
    .{ .bits = 0b00000011000, .length = 11, .run = 25 },
    .{ .bits = 0b000011001010, .length = 12, .run = 26 },
    .{ .bits = 0b000011001011, .length = 12, .run = 27 },
    .{ .bits = 0b000011001100, .length = 12, .run = 28 },
    .{ .bits = 0b000011001101, .length = 12, .run = 29 },
    .{ .bits = 0b000001101000, .length = 12, .run = 30 },
    .{ .bits = 0b000001101001, .length = 12, .run = 31 },
    .{ .bits = 0b000001101010, .length = 12, .run = 32 },
    .{ .bits = 0b000001101011, .length = 12, .run = 33 },
    .{ .bits = 0b000011010010, .length = 12, .run = 34 },
    .{ .bits = 0b000011010011, .length = 12, .run = 35 },
    .{ .bits = 0b000011010100, .length = 12, .run = 36 },
    .{ .bits = 0b000011010101, .length = 12, .run = 37 },
    .{ .bits = 0b000011010110, .length = 12, .run = 38 },
    .{ .bits = 0b000011010111, .length = 12, .run = 39 },
    .{ .bits = 0b000001101100, .length = 12, .run = 40 },
    .{ .bits = 0b000001101101, .length = 12, .run = 41 },
    .{ .bits = 0b000011011010, .length = 12, .run = 42 },
    .{ .bits = 0b000011011011, .length = 12, .run = 43 },
    .{ .bits = 0b000001010100, .length = 12, .run = 44 },
    .{ .bits = 0b000001010101, .length = 12, .run = 45 },
    .{ .bits = 0b000001010110, .length = 12, .run = 46 },
    .{ .bits = 0b000001010111, .length = 12, .run = 47 },
    .{ .bits = 0b000001100100, .length = 12, .run = 48 },
    .{ .bits = 0b000001100101, .length = 12, .run = 49 },
    .{ .bits = 0b000001010010, .length = 12, .run = 50 },
    .{ .bits = 0b000001010011, .length = 12, .run = 51 },
    .{ .bits = 0b000000100100, .length = 12, .run = 52 },
    .{ .bits = 0b000000110111, .length = 12, .run = 53 },
    .{ .bits = 0b000000111000, .length = 12, .run = 54 },
    .{ .bits = 0b000000100111, .length = 12, .run = 55 },
    .{ .bits = 0b000000101000, .length = 12, .run = 56 },
    .{ .bits = 0b000001011000, .length = 12, .run = 57 },
    .{ .bits = 0b000001011001, .length = 12, .run = 58 },
    .{ .bits = 0b000000101011, .length = 12, .run = 59 },
    .{ .bits = 0b000000101100, .length = 12, .run = 60 },
    .{ .bits = 0b000001011010, .length = 12, .run = 61 },
    .{ .bits = 0b000001100110, .length = 12, .run = 62 },
    .{ .bits = 0b000001100111, .length = 12, .run = 63 },
    // Make-up (64..1728 in steps of 64)
    .{ .bits = 0b0000001111, .length = 10, .run = 64 },
    .{ .bits = 0b000011001000, .length = 12, .run = 128 },
    .{ .bits = 0b000011001001, .length = 12, .run = 192 },
    .{ .bits = 0b000001011011, .length = 12, .run = 256 },
    .{ .bits = 0b000000110011, .length = 12, .run = 320 },
    .{ .bits = 0b000000110100, .length = 12, .run = 384 },
    .{ .bits = 0b000000110101, .length = 12, .run = 448 },
    .{ .bits = 0b0000001101100, .length = 13, .run = 512 },
    .{ .bits = 0b0000001101101, .length = 13, .run = 576 },
    .{ .bits = 0b0000001001010, .length = 13, .run = 640 },
    .{ .bits = 0b0000001001011, .length = 13, .run = 704 },
    .{ .bits = 0b0000001001100, .length = 13, .run = 768 },
    .{ .bits = 0b0000001001101, .length = 13, .run = 832 },
    .{ .bits = 0b0000001110010, .length = 13, .run = 896 },
    .{ .bits = 0b0000001110011, .length = 13, .run = 960 },
    .{ .bits = 0b0000001110100, .length = 13, .run = 1024 },
    .{ .bits = 0b0000001110101, .length = 13, .run = 1088 },
    .{ .bits = 0b0000001110110, .length = 13, .run = 1152 },
    .{ .bits = 0b0000001110111, .length = 13, .run = 1216 },
    .{ .bits = 0b0000001010010, .length = 13, .run = 1280 },
    .{ .bits = 0b0000001010011, .length = 13, .run = 1344 },
    .{ .bits = 0b0000001010100, .length = 13, .run = 1408 },
    .{ .bits = 0b0000001010101, .length = 13, .run = 1472 },
    .{ .bits = 0b0000001011010, .length = 13, .run = 1536 },
    .{ .bits = 0b0000001011011, .length = 13, .run = 1600 },
    .{ .bits = 0b0000001100100, .length = 13, .run = 1664 },
    .{ .bits = 0b0000001100101, .length = 13, .run = 1728 },
};

// Color-independent extended make-up codes (T.4 Table 3): runs of
// 1792, 1856, 1920 (length 11) and 1984..2560 step 64 (length 12).
const extended_codes = [_]TableEntry{
    .{ .bits = 0b00000001000, .length = 11, .run = 1792 },
    .{ .bits = 0b00000001100, .length = 11, .run = 1856 },
    .{ .bits = 0b00000001101, .length = 11, .run = 1920 },
    .{ .bits = 0b000000010010, .length = 12, .run = 1984 },
    .{ .bits = 0b000000010011, .length = 12, .run = 2048 },
    .{ .bits = 0b000000010100, .length = 12, .run = 2112 },
    .{ .bits = 0b000000010101, .length = 12, .run = 2176 },
    .{ .bits = 0b000000010110, .length = 12, .run = 2240 },
    .{ .bits = 0b000000010111, .length = 12, .run = 2304 },
    .{ .bits = 0b000000011100, .length = 12, .run = 2368 },
    .{ .bits = 0b000000011101, .length = 12, .run = 2432 },
    .{ .bits = 0b000000011110, .length = 12, .run = 2496 },
    .{ .bits = 0b000000011111, .length = 12, .run = 2560 },
};

// ---- tests ----

test "ccitt_t4.matchCode: white terminating run length 7 (code = 1111)" {
    // 0b1111 = white run 7 (4-bit terminating code).
    var src = [_]u8{0b11110000};
    var reader = BitReader.init(&src, .msb_first);
    const m = try matchCode(&reader, .white);
    try std.testing.expectEqual(@as(u32, 7), m.run);
    try std.testing.expectEqual(CodeKind.terminating, m.kind);
}

test "ccitt_t4.matchCode: black terminating run length 2 (code = 11)" {
    var src = [_]u8{0b11000000};
    var reader = BitReader.init(&src, .msb_first);
    const m = try matchCode(&reader, .black);
    try std.testing.expectEqual(@as(u32, 2), m.run);
}

test "ccitt_t4.matchCode: white make-up 64 (code = 11011)" {
    var src = [_]u8{0b11011000};
    var reader = BitReader.init(&src, .msb_first);
    const m = try matchCode(&reader, .white);
    try std.testing.expectEqual(@as(u32, 64), m.run);
    try std.testing.expectEqual(CodeKind.makeup, m.kind);
}

test "ccitt_t4.matchCode: extended make-up 1792 (code = 00000001000)" {
    // 11 bits MSB-first: 0,0,0,0,0,0,0,1,0,0,0
    // Packed: byte0 = 00000001 (= 0x01), byte1 high 3 bits = 000.
    var src = [_]u8{ 0x01, 0x00 };
    var reader = BitReader.init(&src, .msb_first);
    const m = try matchCode(&reader, .white);
    try std.testing.expectEqual(@as(u32, 1792), m.run);
    try std.testing.expectEqual(CodeKind.extended_makeup, m.kind);
}

test "ccitt_t4.matchCode: lsb-first FillOrder reverses byte's bit order" {
    // Same logical code as the first test (white run 7, code 0b1111),
    // but stored with bits in LSB-first order. In a 4-bit code 1111,
    // the value is invariant under bit reversal.
    // Use a less symmetric code: white 0 = 8 bits 00110101.
    // MSB-first byte: 0x35. LSB-first byte (reversed): 0xAC.
    var src_msb = [_]u8{0x35};
    var rdr_msb = BitReader.init(&src_msb, .msb_first);
    try std.testing.expectEqual(@as(u32, 0), (try matchCode(&rdr_msb, .white)).run);

    var src_lsb = [_]u8{0xAC};
    var rdr_lsb = BitReader.init(&src_lsb, .lsb_first);
    try std.testing.expectEqual(@as(u32, 0), (try matchCode(&rdr_lsb, .white)).run);
}

test "ccitt_t4.BitReader: syncToEol skips zero padding then consumes the 1-bit" {
    // 8 zero bits followed by 0b00011 (3 zeros + 1) — total 11 zeros, 1 one,
    // followed by garbage to confirm we stop right after the EOL terminator.
    var src = [_]u8{ 0b00000000, 0b00010101 };
    //                ^^^^^^^^   ^^^         ^^^^^
    //                8 zeros    EOL=000_1   garbage 0101
    var reader = BitReader.init(&src, .msb_first);
    try reader.syncToEol();
    // Next 4 bits should be 0101 — we read them off.
    var observed: u4 = 0;
    var i: u4 = 0;
    while (i < 4) : (i += 1) {
        observed = (observed << 1) | (try reader.readBit());
    }
    try std.testing.expectEqual(@as(u4, 0b0101), observed);
}

test "ccitt_t4.decode: synthetic 8-pixel row of all-white" {
    // Pre-compose: EOL (12 bits 000000000001) + white-0 terminating
    // (00110101, 8 bits) + white run 7 wait that's not all-white.
    // Simpler: EOL + white-8 terminating (10011, 5 bits).
    // After 8 white pixels (= width), the row terminates without
    // emitting a black run (per spec, the implicit-zero black run
    // at row-end is fine since x already equals width).
    //
    // bit stream: 000000000001 10011 (17 bits)
    //   byte 0:    00000000
    //   byte 1:    00011001
    //   byte 2:    1xxx_xxxx  (x = padding)
    var src = [_]u8{ 0b00000000, 0b00011001, 0b10000000 };
    var dest: [1]u8 = undefined; // 8 pixels = 1 byte row
    const n = try decode(&src, &dest, 8, 1, .msb_first, false);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x00), dest[0]); // all bits = white = 0
}

test "ccitt_t4.decode: real fax2d strip prefix decodes 2 all-white rows" {
    // Bytes lifted from /Volumes/Fileserver/.../fax2d.tif strip 0
    // (FillOrder=2, T4Options=4=EOL byte aligned, width=1728).
    // First 8 bytes of the strip:
    //   0x00 0x80   (LSB-first): 4 zero pad + 12-bit EOL
    //   0xb2 0x59 0x01 0x80   (LSB-first): white-1728 makeup +
    //                                      white-0 term + EOL pad +
    //                                      12-bit EOL
    //   0xb2 0x59   continues into row 2's data
    //
    // Decoding 2 rows of width=1728 should produce 2 × 216 = 432
    // bytes of all-zero output (all-white rows under the 1-bit
    // packed convention; photometric inversion happens later).
    const strip_prefix = [_]u8{ 0x00, 0x80, 0xb2, 0x59, 0x01, 0x80, 0xb2, 0x59, 0x01, 0x80 };
    var dest: [432]u8 = .{0xAA} ** 432; // poisoned to detect missed writes
    const n = try decode(&strip_prefix, &dest, 1728, 2, .lsb_first, true);
    try std.testing.expectEqual(@as(usize, 432), n);
    for (dest, 0..) |b, idx| {
        if (b != 0x00) {
            std.debug.print("row-0/1 byte {d} = {x:0>2} (expected 0x00)\n", .{ idx, b });
            return error.TestUnexpectedResult;
        }
    }
}

test "ccitt_t4.decode: full fax2d.tif strip (1728x1082) hashes deterministically" {
    // Decoder regression guard for the M4-E marquee target. Uses
    // @embedFile so the test is independent of the file-I/O +
    // photometric pipeline that fixture_test.zig exercises. If this
    // SHA changes on any platform without an intentional decoder
    // change, the decoder has regressed (or has new UB).
    //
    // Pinned hash captured 2026-05-13 from a known-good run on both
    // Mac aarch64-darwin and Linux x86_64-musl (both produce the
    // same value).
    const tiff_bytes = @embedFile(".fax2d.tif");
    // strip 0 lives at file offset 8, length 32525 (per tiffinfo).
    const strip = tiff_bytes[8..][0..32525];

    var dest: [216 * 1082]u8 = undefined; // 216 bytes/row × 1082 rows
    const n = try decode(&strip.*, &dest, 1728, 1082, .lsb_first, true);
    try std.testing.expectEqual(@as(usize, 216 * 1082), n);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(dest[0..n]);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const expected: [32]u8 = .{
        0xa2, 0x02, 0x4d, 0xd6, 0xe7, 0x90, 0xf7, 0x5a,
        0xca, 0x2d, 0x7f, 0xd6, 0xe9, 0x6b, 0xea, 0x5c,
        0x02, 0x52, 0x1e, 0x49, 0x6a, 0x0b, 0x7a, 0x1f,
        0x7d, 0xae, 0xc4, 0x5c, 0xaa, 0xdb, 0xc4, 0x85,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "ccitt_t4.decode: synthetic row of all-black" {
    // EOL + white-0 (00110101, 8 bits) + black-8 (000101, 6 bits)
    // 12 + 8 + 6 = 26 bits.
    //   byte 0: 0000_0000  (8 zeros — EOL prefix)
    //   byte 1: 0001_0011  (3 zeros + EOL "1" + 0011 of white-0)
    //   byte 2: 0101_0001  (0101 of white-0 + 0001 of black-8 prefix)
    //   byte 3: 0100_0000  (01 of black-8 + 6 padding)
    var src = [_]u8{ 0b00000000, 0b00010011, 0b01010001, 0b01000000 };
    var dest: [1]u8 = undefined;
    const n = try decode(&src, &dest, 8, 1, .msb_first, false);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0xFF), dest[0]);
}
