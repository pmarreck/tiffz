//! Compression 32766: NeXT 2-bit gray run-length encoding.
//!
//! No published specification exists. This reads the format as libtiff's
//! tif_next.c (Leffler and SGI, permissive license) does; the code here is
//! written from that description, not copied. Samples are 2 bits, four to a
//! byte, high bits first, and each row starts all white (every sample 3).
//! Each row opens with one code byte:
//!
//!   0x00  the whole row follows as literal bytes;
//!   0x40  a literal span: a big-endian 16-bit byte offset and byte count,
//!         then that many bytes, placed at the offset in an otherwise white
//!         row;
//!   else  run mode: this byte and those after it are <gray:2><count:6>,
//!         count pixels of that gray, until the row is full.
//!
//! Stricter than libtiff, which drops the excess silently: a run past the end
//! of the row is Malformed. Data that ends early is SourceTooShort.

const std = @import("std");
const errors = @import("tiffz-parser").errors;

const literal_row: u8 = 0x00;
const literal_span: u8 = 0x40;

/// Decode `rows` rows of `width` 2-bit samples into `dest`, one row per
/// `ceil(width / 4)` bytes. Returns the bytes written.
pub fn decode(src: []const u8, dest: []u8, width: u32, rows: u32) errors.Error!usize {
    const row_bytes: usize = (@as(usize, width) + 3) / 4;
    const total = std.math.mul(usize, row_bytes, rows) catch return error.Malformed;
    if (dest.len < total) return error.DestTooSmall;

    var pos: usize = 0;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const row = dest[r * row_bytes ..][0..row_bytes];
        @memset(row, 0xFF);
        if (pos >= src.len) return error.SourceTooShort;
        const code = src[pos];
        pos += 1;
        switch (code) {
            literal_row => {
                if (src.len - pos < row_bytes) return error.SourceTooShort;
                @memcpy(row, src[pos..][0..row_bytes]);
                pos += row_bytes;
            },
            literal_span => {
                if (src.len - pos < 4) return error.SourceTooShort;
                const off: usize = std.mem.readInt(u16, src[pos..][0..2], .big);
                const n: usize = std.mem.readInt(u16, src[pos + 2 ..][0..2], .big);
                pos += 4;
                if (off + n > row_bytes) return error.Malformed;
                if (src.len - pos < n) return error.SourceTooShort;
                @memcpy(row[off..][0..n], src[pos..][0..n]);
                pos += n;
            },
            else => {
                var x: usize = 0;
                var byte = code;
                while (true) {
                    const gray: u8 = byte >> 6;
                    const count: usize = byte & 0x3F;
                    if (x + count > width) return error.Malformed;
                    for (0..count) |_| {
                        const shift: u3 = @intCast(6 - 2 * (x % 4));
                        // As libtiff does: the first sample of a byte clears
                        // the rest of it, so pad bits after the last sample
                        // of a run-mode row are zero.
                        if (x % 4 == 0) row[x / 4] = 0;
                        row[x / 4] |= gray << shift;
                        x += 1;
                    }
                    if (x == width) break;
                    if (pos >= src.len) return error.SourceTooShort;
                    byte = src[pos];
                    pos += 1;
                }
            },
        }
    }
    return total;
}

test "NeXT: a literal row, a literal span and a run-mode row" {
    // Width 8: two bytes per row.
    const src = [_]u8{
        0x00, 0x1B, 0xE4, // literal row: samples 0 1 2 3, 3 2 1 0
        0x40, 0x00, 0x01, 0x00, 0x01, 0x00, // span: byte 1 is 0x00, byte 0 stays white
        0x44, 0x83, 0x01, // run mode: 4 of gray 1, 3 of gray 2, 1 of gray 0
    };
    var dest: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try decode(&src, &dest, 8, 3));
    try std.testing.expectEqualSlices(u8, &.{ 0x1B, 0xE4, 0xFF, 0x00, 0x55, 0xA8 }, &dest);
}

test "NeXT: a run past the row, a span past the row, and data that ends early fail" {
    var dest: [2]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&.{0x49}, &dest, 8, 1)); // 9 pixels in an 8-pixel row
    try std.testing.expectError(error.Malformed, decode(&.{ 0x40, 0x00, 0x01, 0x00, 0x02, 0, 0 }, &dest, 8, 1));
    try std.testing.expectError(error.SourceTooShort, decode(&.{ 0x00, 0x1B }, &dest, 8, 1));
    try std.testing.expectError(error.SourceTooShort, decode(&.{0x44}, &dest, 8, 1)); // run stops at 4 of 8
}
