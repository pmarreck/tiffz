//! LZW compression (TIFF compression=5).
//!
//! TIFF LZW per TIFF 6.0 §13:
//!   - 9..12-bit codes, MSB-first bit packing within bytes
//!   - clear code = 256, EOD = 257, first data code = 258
//!   - "early change" quirk: code width increments at next_code = 2^n - 1
//!     (rather than 2^n, which is what the original Welch 1984 paper
//!     used and what some "modern-style" TIFF writers emit instead).
//!     We follow the early-change path because that's what TIFF 6.0
//!     actually mandates; libtiff calls the alternative path
//!     "old-style" only because LZW writers in the wild are
//!     inconsistent and some emit the academically-correct timing.
//!
//! Algorithm/implementation adapted from validate's
//! `src/core/tiff_lzw_decoder.zig` (Peter's project, MIT). The
//! prefix-chain dictionary keeps each entry to (prefix, suffix,
//! length) — building output strings by walking back to a single-byte
//! root entry. O(L) per emit, O(N) memory for N entries.
//!
//! API differs from validate's: tiffz's caller supplies the output
//! buffer (no allocation), the function returns the number of bytes
//! written, and overflow/short-input/malformed cases map to tiffz's
//! shared error set.

const std = @import("std");

const errors = @import("../errors.zig");

const CLEAR_CODE: u16 = 256;
const EOD_CODE: u16 = 257;
const FIRST_DATA_CODE: u16 = 258;
const MAX_CODE: u16 = 4095;
const TABLE_CAPACITY: usize = 4096;

/// Dictionary entry — TIFF LZW strings are stored as prefix chains.
const Entry = struct {
    /// Index of prefix entry; null for single-byte (root) entries.
    prefix: ?u16,
    /// Last byte of the string this entry represents.
    suffix: u8,
    /// Total length of the represented string (cached for output sizing).
    length: u16,
};

/// Bit-packing direction. TIFF 6.0 mandates MSB-first; some 1990s
/// TIFF writers (Sun, early Adobe) used LSB-first which libtiff
/// calls "old-style" and warns about ("Old-style LSB-to-MSB
/// horizontal differencing" / "Old-style LZW codes").
const BitOrder = enum { msb_first, lsb_first };

/// Variable-width bit reader. Reads codes either MSB-first (TIFF 6.0
/// new-style) or LSB-first (old-style "compat" path).
const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3,
    order: BitOrder,

    fn init(data: []const u8, order: BitOrder) BitReader {
        return .{ .data = data, .byte_pos = 0, .bit_pos = 0, .order = order };
    }

    /// Read `bits` (9..12) bits as a code. Returns null on EOF.
    fn readCode(self: *BitReader, bits: u4) ?u16 {
        return switch (self.order) {
            .msb_first => self.readCodeMsb(bits),
            .lsb_first => self.readCodeLsb(bits),
        };
    }

    fn readCodeMsb(self: *BitReader, bits: u4) ?u16 {
        var result: u16 = 0;
        var bits_needed: u4 = bits;
        while (bits_needed > 0) {
            if (self.byte_pos >= self.data.len) return null;
            const current = self.data[self.byte_pos];
            const bits_in_byte: u4 = @intCast(8 - @as(u4, self.bit_pos));
            const take: u4 = @min(bits_in_byte, bits_needed);
            const shift: u3 = @intCast(bits_in_byte - take);
            const mask: u8 = @as(u8, @intCast((@as(u16, 1) << take) - 1)) << shift;
            const extracted: u8 = (current & mask) >> shift;
            result = (result << take) | extracted;
            bits_needed -= take;
            const new_bit_pos: u4 = @as(u4, self.bit_pos) + take;
            if (new_bit_pos >= 8) {
                self.byte_pos += 1;
                self.bit_pos = 0;
            } else {
                self.bit_pos = @intCast(new_bit_pos);
            }
        }
        return result;
    }

    /// LSB-first: bits accumulate from the LSB side of each byte,
    /// least-significant bit of the first byte first. The result's
    /// low bits come from the first byte's low bits, high bits from
    /// later bytes' low bits. libtiff's LZWDecodeCompat path.
    fn readCodeLsb(self: *BitReader, bits: u4) ?u16 {
        var result: u32 = 0;
        var bits_filled: u4 = 0;
        while (bits_filled < bits) {
            if (self.byte_pos >= self.data.len) return null;
            const current = self.data[self.byte_pos];
            const bits_in_byte: u4 = @intCast(8 - @as(u4, self.bit_pos));
            const take: u4 = @min(bits_in_byte, bits - bits_filled);
            const extracted: u8 = (current >> self.bit_pos) & (@as(u8, @intCast((@as(u16, 1) << take) - 1)));
            result |= @as(u32, extracted) << bits_filled;
            bits_filled += take;
            const new_bit_pos: u4 = @as(u4, self.bit_pos) + take;
            if (new_bit_pos >= 8) {
                self.byte_pos += 1;
                self.bit_pos = 0;
            } else {
                self.bit_pos = @intCast(new_bit_pos);
            }
        }
        return @intCast(result);
    }
};

/// LZW variant — combination of bit packing direction and code-width
/// change timing. TIFF 6.0 mandates new-style (MSB-first packing,
/// early change at `(1 << code_bits) - 1`). Various 1990s writers
/// used the legacy Sun/Adobe LSB-first path with late-change timing.
/// libtiff calls files using the legacy path "Old-style LZW codes"
/// and emits a warning when it detects them.
pub const Variant = enum {
    /// MSB-first bit packing, early code-width change. TIFF 6.0 spec.
    new_style,
    /// LSB-first bit packing, late code-width change. libtiff
    /// "old-style"/compat path.
    old_style,
};

/// Decode TIFF LZW from `src` into `dest` using the new-style
/// (TIFF 6.0) variant.
pub fn decode(src: []const u8, dest: []u8) errors.Error!usize {
    return decodeVariant(src, dest, .new_style);
}

/// Decode TIFF LZW from `src` into `dest` with explicit variant.
/// Errors:
///   error.Malformed       — invalid code (e.g. forward reference past next_code+0)
///   error.SourceTooShort  — code stream ends before EOD without reaching end naturally
///   error.DestTooSmall    — output exceeds dest.len
pub fn decodeVariant(src: []const u8, dest: []u8, variant: Variant) errors.Error!usize {
    var dict: [TABLE_CAPACITY]Entry = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        dict[i] = .{ .prefix = null, .suffix = @intCast(i), .length = 1 };
    }

    var next_code: u16 = FIRST_DATA_CODE;
    var code_bits: u4 = 9;
    const order: BitOrder = if (variant == .new_style) .msb_first else .lsb_first;
    var reader = BitReader.init(src, order);
    var prev_code: ?u16 = null;
    var di: usize = 0;

    while (true) {
        // TIFF LZW has a mandatory EOD code. Physical EOF is never a
        // successful terminator: accepting it turns a truncated strip into a
        // valid image and removes an integrity signal from deep validation.
        const code = reader.readCode(code_bits) orelse return error.SourceTooShort;

        if (code == EOD_CODE) break;

        if (code == CLEAR_CODE) {
            next_code = FIRST_DATA_CODE;
            code_bits = 9;
            prev_code = null;
            continue;
        }

        if (code < next_code) {
            // Code is in the dictionary — emit its string verbatim.
            di = try emitString(&dict, code, dest, di);

            if (prev_code) |pc| {
                if (next_code <= MAX_CODE) {
                    const first_byte = firstByte(&dict, code);
                    dict[next_code] = .{
                        .prefix = pc,
                        .suffix = first_byte,
                        .length = dict[pc].length + 1,
                    };
                    next_code += 1;
                    const boundary: u16 = if (variant == .new_style)
                        (@as(u16, 1) << code_bits) - 1
                    else
                        (@as(u16, 1) << code_bits);
                    if (next_code >= boundary and code_bits < 12) {
                        code_bits += 1;
                    }
                }
            }
        } else if (code == next_code) {
            // KwKwK case: code refers to the entry we're about to add.
            // The string is (string-of-prev-code) + first-byte-of-prev-code.
            const pc = prev_code orelse return error.Malformed;
            const first_byte = firstByte(&dict, pc);
            di = try emitString(&dict, pc, dest, di);
            if (di >= dest.len) return error.DestTooSmall;
            dest[di] = first_byte;
            di += 1;

            if (next_code <= MAX_CODE) {
                dict[next_code] = .{
                    .prefix = pc,
                    .suffix = first_byte,
                    .length = dict[pc].length + 1,
                };
                next_code += 1;
                if (next_code >= (@as(u16, 1) << code_bits) - 1 and code_bits < 12) {
                    code_bits += 1;
                }
            }
        } else {
            return error.Malformed;
        }

        prev_code = code;
    }

    return di;
}

fn emitString(dict: *const [TABLE_CAPACITY]Entry, code: u16, dest: []u8, write_pos: usize) errors.Error!usize {
    const len = dict[code].length;
    if (write_pos + len > dest.len) return error.DestTooSmall;
    // Walk the prefix chain backwards filling dest from the end.
    var pos: usize = write_pos + len;
    var current: u16 = code;
    while (true) {
        pos -= 1;
        dest[pos] = dict[current].suffix;
        if (dict[current].prefix) |p| {
            current = p;
        } else break;
    }
    return write_pos + len;
}

fn firstByte(dict: *const [TABLE_CAPACITY]Entry, code: u16) u8 {
    var current = code;
    while (dict[current].prefix) |p| current = p;
    return dict[current].suffix;
}

// ---- tests ----
//
// Synthetic codes packed MSB-first at 9 bits each. Helpers borrowed
// from validate's test pattern (same shape, smaller packCodes9 buffer).

fn packCodes9(comptime N: comptime_int, codes: [N]u16) [(N * 9 + 7) / 8]u8 {
    var out: [(N * 9 + 7) / 8]u8 = .{0} ** ((N * 9 + 7) / 8);
    var bit_pos: usize = 0;
    inline for (codes) |c| {
        var b: usize = 0;
        while (b < 9) : (b += 1) {
            const bit: u1 = @intCast((c >> @intCast(8 - b)) & 1);
            const byte_idx = bit_pos / 8;
            const bit_in_byte: u3 = @intCast(7 - (bit_pos % 8));
            out[byte_idx] |= @as(u8, bit) << bit_in_byte;
            bit_pos += 1;
        }
    }
    return out;
}

test "lzw.decode: single literal byte ('A') + EOD" {
    const codes = [_]u16{ 65, EOD_CODE };
    const encoded = packCodes9(2, codes);
    var dest: [16]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 'A'), dest[0]);
}

test "lzw.decode: ABC literals + EOD" {
    const codes = [_]u16{ 65, 66, 67, EOD_CODE };
    const encoded = packCodes9(4, codes);
    var dest: [16]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("ABC", dest[0..3]);
}

test "lzw.decode: clear code resets dictionary" {
    const codes = [_]u16{ 65, CLEAR_CODE, 66, EOD_CODE };
    const encoded = packCodes9(4, codes);
    var dest: [16]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("AB", dest[0..2]);
}

test "lzw.decode: empty (just EOD) yields zero output" {
    const codes = [_]u16{EOD_CODE};
    const encoded = packCodes9(1, codes);
    var dest: [16]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "lzw.decode: rejects physical EOF before mandatory EOD" {
    // TIFF 6.0 requires the EOD code. A complete literal code followed by
    // byte-alignment padding is still an incomplete compressed stream.
    const codes = [_]u16{65};
    const encoded = packCodes9(1, codes);
    var dest: [16]u8 = undefined;
    try std.testing.expectError(error.SourceTooShort, decode(&encoded, &dest));
}

test "lzw.decode: KwKwK pattern emits new-string from prev_code + first byte" {
    // After 65, 66 the dictionary has:
    //   258 = "AB"
    //   259 (yet-to-add) would be "BX" on next code
    // If we emit 258 next, that's "AB" (in-table). If we instead emit 259
    // before adding, we hit the KwKwK case. Easiest pattern: 65, 258, EOD.
    // After 65 alone, prev_code=65, next_code=258 (no new entry yet because
    // we needed prev to add). On the 258 read: 258 == next_code → KwKwK →
    // emit prev_string("A") + firstByte(prev_code='A') = "AA".
    const codes = [_]u16{ 65, FIRST_DATA_CODE, EOD_CODE };
    const encoded = packCodes9(3, codes);
    var dest: [16]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqualStrings("AAA", dest[0..n]);
}

test "lzw.decode: dest overflow surfaces DestTooSmall" {
    const codes = [_]u16{ 65, 66, 67, EOD_CODE };
    const encoded = packCodes9(4, codes);
    var dest: [2]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, decode(&encoded, &dest));
}

test "lzw.decode: forward-reference past next_code is Malformed" {
    // First non-clear code 999 doesn't exist (next_code starts at 258 and
    // KwKwK only allows == next_code, not >).
    const codes = [_]u16{ 999, EOD_CODE };
    const encoded = packCodes9(2, codes);
    var dest: [16]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&encoded, &dest));
}
