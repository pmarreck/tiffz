//! JPEG Huffman decoder.
//!
//! T.81 §C.2 / Annex C: a JPEG Huffman table is described by 16
//! "code length count" bytes (BITS[i] = number of codes of length
//! i+1, for i in 0..15) followed by a flat list of value bytes
//! (HUFFVAL[]) sorted by ascending code length. The codes themselves
//! aren't stored — they're derived from the BITS counts via the
//! canonical generator (T.81 Annex C, Figure C.2).
//!
//! Decode hot path uses a 256-entry first-level lookup table indexed
//! by the next 8 bits — covers all codes of length ≤ 8 in one
//! constant-time hop. Codes longer than 8 bits fall through to a
//! linear search by length.
//!
//! Reference: ITU-T T.81 §C.2, Annex C.

const std = @import("std");
const bitstream = @import("bitstream.zig");

pub const Error = error{
    /// DHT segment body is malformed (length mismatch, > 256 codes,
    /// invalid HUFFVAL count).
    InvalidHuffmanTable,
    /// Decoded code didn't match any entry in the table — file is corrupt.
    HuffmanDecodeError,
} || bitstream.Error;

/// One Huffman table — DC class or AC class, identified by Th index
/// inside a DHT segment. JPEG allows up to 4 of each class.
pub const HuffmanTable = struct {
    /// Number of codes for each length 1..16.
    bits: [16]u8,
    /// Values (HUFFVAL) sorted by code length.
    values: [256]u8,
    /// Total number of codes (sum of bits[]).
    total: u16,
    /// `huffcode[i]` = the canonical code for `values[i]`. Length
    /// implied by the cumulative position in `bits[]`.
    codes: [256]u16,
    /// `code_size[i]` = bit length of `codes[i]`.
    code_sizes: [256]u8,

    /// First-level fast lookup: indexed by next 8 bits, maps to value
    /// (0xFF = no match in this range — fall through to slow path).
    fast_value: [256]u8,
    fast_size: [256]u8,

    /// Slow-path lookup: for codes longer than 8 bits, we know the
    /// minimum and maximum code value at each length. To decode: read
    /// bits one at a time, accumulate `code`, and check whether
    /// `code <= max_code[len]`. If yes, look up
    /// `values[val_offset[len] + (code - min_code[len])]`.
    /// Index 0..16 (only 9..16 are used by the slow path).
    max_code: [17]i32,
    val_offset: [17]i32,

    pub fn buildFromDht(bits: [16]u8, values: []const u8) Error!HuffmanTable {
        var t: HuffmanTable = undefined;
        t.bits = bits;
        var total: u16 = 0;
        for (bits) |b| total += b;
        if (total == 0 or total > 256) return error.InvalidHuffmanTable;
        if (values.len < total) return error.InvalidHuffmanTable;
        t.total = total;
        @memset(&t.values, 0);
        @memcpy(t.values[0..total], values[0..total]);

        // Generate canonical Huffman codes (T.81 Annex C, Figure C.2).
        var code: u32 = 0;
        var idx: usize = 0;
        for (bits, 1..) |count, len_plus_1| {
            const len: u8 = @intCast(len_plus_1);
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (idx >= 256) return error.InvalidHuffmanTable;
                t.codes[idx] = @intCast(code);
                t.code_sizes[idx] = len;
                code += 1;
                idx += 1;
            }
            code <<= 1;
        }

        // Build first-level fast lookup table.
        @memset(&t.fast_value, 0xFF);
        @memset(&t.fast_size, 0);
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const len = t.code_sizes[i];
            if (len > 8) continue;
            const c = t.codes[i];
            // The 8-bit prefix that begins with this code: c shifted
            // left by (8 - len), spanning `1 << (8 - len)` table entries.
            const shift: u3 = @intCast(8 - len);
            const start: usize = @as(usize, c) << shift;
            const span: usize = @as(usize, 1) << shift;
            var k: usize = 0;
            while (k < span) : (k += 1) {
                t.fast_value[start + k] = t.values[i];
                t.fast_size[start + k] = len;
            }
        }

        // Build slow-path tables (max_code / val_offset by length).
        // Track first_code_at_len in lockstep with the canonical generator
        // above. CRITICAL: shift left even when count==0 — the first loop's
        // `code <<= 1` runs for every length regardless of count, and this
        // table must mirror that. (T.81 Annex C, Figure C.3 generate_decoder_tables.)
        for (&t.max_code) |*v| v.* = -1;
        for (&t.val_offset) |*v| v.* = 0;
        var ci: usize = 0;
        var first_code_at_len: u32 = 0;
        for (bits, 1..) |count, len_plus_1| {
            const len: u8 = @intCast(len_plus_1);
            if (count == 0) {
                t.max_code[len] = -1;
                first_code_at_len <<= 1;
                continue;
            }
            t.val_offset[len] = @as(i32, @intCast(ci)) - @as(i32, @intCast(first_code_at_len));
            t.max_code[len] = @intCast(first_code_at_len + count - 1);
            ci += count;
            first_code_at_len = (first_code_at_len + count) << 1;
        }

        return t;
    }

    /// Decode the next Huffman symbol from the bit stream.
    pub fn decode(self: *const HuffmanTable, br: *bitstream.BitReader) Error!u8 {
        // Fast path: 8-bit lookup. Only safe when 8 valid bits exist —
        // otherwise peekBits zero-pads and we'd consume phantom bits.
        const peek = br.peekBits(8);
        if (br.bits_valid >= 8) {
            const fv = self.fast_value[peek];
            if (fv != 0xFF) {
                const sz: u5 = @intCast(self.fast_size[peek]);
                br.consume(sz);
                return fv;
            }
            // Slow path: walk bit-by-bit for codes > 8 bits.
            var code: i32 = @intCast(peek);
            br.consume(8);
            var len: u8 = 9;
            while (len <= 16) : (len += 1) {
                const bit = br.readBits(1) catch return error.HuffmanDecodeError;
                code = (code << 1) | @as(i32, bit);
                if (code <= self.max_code[len]) {
                    const idx: usize = @intCast(code + self.val_offset[len]);
                    if (idx >= self.total) return error.HuffmanDecodeError;
                    return self.values[idx];
                }
            }
            return error.HuffmanDecodeError;
        }
        // Short-buffer path: stream is near a marker / EOI. Walk bit-by-bit
        // so readBits surfaces NotEnoughBits cleanly instead of asserting.
        var code: i32 = 0;
        var len: u8 = 1;
        while (len <= 16) : (len += 1) {
            const bit = br.readBits(1) catch return error.HuffmanDecodeError;
            code = (code << 1) | @as(i32, bit);
            if (code <= self.max_code[len]) {
                const idx: usize = @intCast(code + self.val_offset[len]);
                if (idx >= self.total) return error.HuffmanDecodeError;
                return self.values[idx];
            }
        }
        return error.HuffmanDecodeError;
    }
};

/// Read an N-bit signed coefficient amplitude per T.81 §F.1.2.1.1
/// (Table F.1). The Huffman symbol's RRRRSSSS gives `ssss = N`; the
/// next N bits are the magnitude with the standard "negative if MSB
/// is 0" sign extension.
pub fn extendSign(value: u16, n: u5) i16 {
    if (n == 0) return 0;
    const top_bit_mask: u16 = @as(u16, 1) << @intCast(n - 1);
    if ((value & top_bit_mask) != 0) {
        // Positive value; just zero-extend.
        return @intCast(value);
    } else {
        // Negative: subtract (2^n - 1).
        const sub: u16 = (@as(u16, 1) << @as(u4, @intCast(n))) - 1;
        return @intCast(@as(i32, value) - @as(i32, sub));
    }
}

// ── Tests ────────────────────────────────────────────────────

test "buildFromDht: tiny 3-symbol table" {
    // bits = 1, 2 → one length-1 code, two length-2 codes
    // values = 0, 1, 2 (in code-length order)
    // canonical codes: '0' (length 1), '10' (length 2), '11' (length 2)
    const bits = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const vals = [_]u8{ 0, 1, 2 };
    const t = try HuffmanTable.buildFromDht(bits, &vals);
    try std.testing.expectEqual(@as(u16, 3), t.total);
    try std.testing.expectEqual(@as(u16, 0b0), t.codes[0]);
    try std.testing.expectEqual(@as(u8, 1), t.code_sizes[0]);
    try std.testing.expectEqual(@as(u16, 0b10), t.codes[1]);
    try std.testing.expectEqual(@as(u8, 2), t.code_sizes[1]);
    try std.testing.expectEqual(@as(u16, 0b11), t.codes[2]);
    try std.testing.expectEqual(@as(u8, 2), t.code_sizes[2]);
}

test "decode: round-trip via fast lookup table" {
    // Same 3-symbol table; encode bits "0 10 11 0" → values 0,1,2,0
    const bits = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const vals = [_]u8{ 0, 1, 2 };
    const t = try HuffmanTable.buildFromDht(bits, &vals);

    // Encoded bitstream: 0 10 11 0 = 0b01011000 (left-aligned in byte)
    const data = [_]u8{0b01011000};
    var br = bitstream.BitReader.init(&data);

    try std.testing.expectEqual(@as(u8, 0), try t.decode(&br));
    try std.testing.expectEqual(@as(u8, 1), try t.decode(&br));
    try std.testing.expectEqual(@as(u8, 2), try t.decode(&br));
    try std.testing.expectEqual(@as(u8, 0), try t.decode(&br));
}

test "extendSign: T.81 Table F.1" {
    // n=0: always 0
    try std.testing.expectEqual(@as(i16, 0), extendSign(0, 0));

    // n=1: 0 → -1, 1 → +1
    try std.testing.expectEqual(@as(i16, -1), extendSign(0, 1));
    try std.testing.expectEqual(@as(i16, 1), extendSign(1, 1));

    // n=2: 0 → -3, 1 → -2, 2 → +2, 3 → +3
    try std.testing.expectEqual(@as(i16, -3), extendSign(0, 2));
    try std.testing.expectEqual(@as(i16, -2), extendSign(1, 2));
    try std.testing.expectEqual(@as(i16, 2), extendSign(2, 2));
    try std.testing.expectEqual(@as(i16, 3), extendSign(3, 2));

    // n=8: 0 → -255, 0x7F → -128, 0x80 → 128, 0xFF → 255
    try std.testing.expectEqual(@as(i16, -255), extendSign(0, 8));
    try std.testing.expectEqual(@as(i16, -128), extendSign(0x7F, 8));
    try std.testing.expectEqual(@as(i16, 128), extendSign(0x80, 8));
    try std.testing.expectEqual(@as(i16, 255), extendSign(0xFF, 8));
}

test "buildFromDht: rejects empty table" {
    const bits = [_]u8{0} ** 16;
    const vals = [_]u8{};
    try std.testing.expectError(error.InvalidHuffmanTable, HuffmanTable.buildFromDht(bits, &vals));
}

test "buildFromDht: rejects HUFFVAL too short" {
    const bits = [_]u8{ 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const vals = [_]u8{ 0, 1 }; // only 2 values, table claims 3
    try std.testing.expectError(error.InvalidHuffmanTable, HuffmanTable.buildFromDht(bits, &vals));
}

test "buildFromDht: standard luma AC table — long-code val_offset/max_code track gap-shifts" {
    // Standard luma AC table per T.81 Table K.5: bits =
    // [0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,125]. After L12 (4 codes max
    // 0xFF7), the canonical generator shifts left through L13 (0
    // codes), L14 (0 codes), then emits 1 code at L15. The L15 code
    // is therefore 0xFF8 << 3 = 0x7FC0, NOT 0x1FF0. Without the
    // gap-shift fix, slow-path decode of any L13-L16 code (which
    // includes most ZRL-ish AC values in real-world JPEGs) misses,
    // causing systematic ac_huffman_decode_failed across most files.
    const bits = [_]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125 };
    // Just need 162 values to satisfy buildFromDht. Use 0..161 — the
    // exact byte sequence doesn't matter for table-shape validation.
    var vals: [162]u8 = undefined;
    for (&vals, 0..) |*v, i| v.* = @intCast(i);
    const t = try HuffmanTable.buildFromDht(bits, &vals);

    // First L15 code is 0x7FC0 (the only code at that length).
    try std.testing.expectEqual(@as(i32, 0x7FC0), t.max_code[15]);
    // First L16 code = 0x7FC1 << 1 = 0xFF82; with 125 codes max =
    // 0xFFFE.
    try std.testing.expectEqual(@as(i32, 0xFFFE), t.max_code[16]);
}
