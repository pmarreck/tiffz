//! Compression 32809: ThunderScan 4-bit encoding.
//!
//! No published specification exists. This reads the format as libtiff's
//! tif_thunder.c (Leffler and SGI, permissive license) does; the code here is
//! written from that description, not copied. Samples are 4 bits, two to a
//! byte, high nibble first. Each row is coded on its own, starting from a
//! previous pixel of 0, and ends when it holds `width` pixels. Every byte is
//! a 2-bit code and 6 bits of data:
//!
//!   00  a run: repeat the previous pixel `data` times (0 repeats nothing);
//!   01  three 2-bit deltas from the previous pixel: 0, +1, skip, -1;
//!   10  two 3-bit deltas: 0, +1, +2, +3, skip, -3, -2, -1;
//!   11  a raw pixel, the low 4 bits of `data`.
//!
//! Pixel arithmetic wraps modulo 16, as in libtiff. Stricter than libtiff,
//! which drops delta pixels past the row's end silently: any pixel past the
//! end is Malformed, and so is a run past it (libtiff reports that one too).
//! Data that ends early is SourceTooShort.

const std = @import("std");
const errors = @import("tiffz-parser").errors;

const two_bit_deltas = [4]i8{ 0, 1, 0, -1 };
const two_bit_skip: u8 = 2;
const three_bit_deltas = [8]i8{ 0, 1, 2, 3, 0, -3, -2, -1 };
const three_bit_skip: u8 = 4;

const Row = struct {
    out: []u8,
    width: usize,
    x: usize = 0,
    last: u8 = 0,

    fn put(self: *Row, value: u8) errors.Error!void {
        if (self.x >= self.width) return error.Malformed;
        const v = value & 0xF;
        if (self.x % 2 == 0) self.out[self.x / 2] = v << 4 else self.out[self.x / 2] |= v;
        self.x += 1;
        self.last = v;
    }

    fn delta(self: *Row, d: i8) errors.Error!void {
        const next: u8 = @intCast((@as(i16, self.last) + d) & 0xF);
        try self.put(next);
    }
};

/// Decode `rows` rows of `width` 4-bit samples into `dest`, one row per
/// `ceil(width / 2)` bytes. Returns the bytes written.
pub fn decode(src: []const u8, dest: []u8, width: u32, rows: u32) errors.Error!usize {
    const row_bytes: usize = (@as(usize, width) + 1) / 2;
    const total = std.math.mul(usize, row_bytes, rows) catch return error.Malformed;
    if (dest.len < total) return error.DestTooSmall;
    @memset(dest[0..total], 0);

    var pos: usize = 0;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        var row: Row = .{ .out = dest[r * row_bytes ..][0..row_bytes], .width = width };
        while (row.x < row.width) {
            if (pos >= src.len) return error.SourceTooShort;
            const b = src[pos];
            pos += 1;
            const data = b & 0x3F;
            switch (b >> 6) {
                0 => {
                    if (row.x + data > row.width) return error.Malformed;
                    for (0..data) |_| try row.put(row.last);
                },
                1 => for ([_]u3{ 4, 2, 0 }) |shift| {
                    const d = (data >> shift) & 3;
                    if (d != two_bit_skip) try row.delta(two_bit_deltas[d]);
                },
                2 => for ([_]u3{ 3, 0 }) |shift| {
                    const d = (data >> shift) & 7;
                    if (d != three_bit_skip) try row.delta(three_bit_deltas[d]);
                },
                3 => try row.put(data),
                else => unreachable,
            }
        }
    }
    return total;
}

test "ThunderScan: raw pixels, a run, 2-bit and 3-bit deltas, and skips" {
    // Width 8, one row: raw 5; run of 2 (5 5); 2-bit deltas +1, -1, skip
    // (6 5); 3-bit deltas +3, -2 (8 6); raw 15.
    const src = [_]u8{ 0xC5, 0x02, 0x40 | (1 << 4) | (3 << 2) | 2, 0x80 | (3 << 3) | 6, 0xCF };
    var dest: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try decode(&src, &dest, 8, 1));
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0x56, 0x58, 0x6F }, &dest);
}

test "ThunderScan: rows start from pixel 0, deltas wrap modulo 16" {
    // Row 0: 2-bit delta -1 from 0 is 15; skip; skip. Row 1: delta +1 is 1.
    const src = [_]u8{ 0x40 | (3 << 4) | (2 << 2) | 2, 0x40 | (1 << 4) | (2 << 2) | 2 };
    var dest: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try decode(&src, &dest, 1, 2));
    try std.testing.expectEqualSlices(u8, &.{ 0xF0, 0x10 }, &dest);
}

test "ThunderScan: a pixel past the row and data that ends early fail" {
    var dest: [1]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&.{ 0xC1, 0x02 }, &dest, 2, 1)); // run of 2 after 1 pixel
    try std.testing.expectError(error.Malformed, decode(&.{0x40 | (1 << 4) | (1 << 2) | 1}, &dest, 2, 1)); // 3 deltas, 2 pixels
    try std.testing.expectError(error.SourceTooShort, decode(&.{0xC1}, &dest, 2, 1));
}
