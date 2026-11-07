//! Compressions 34676 (SGILog) and 34677 (SGILog24), Greg Ward Larson's
//! LogLuv, as 16-bit samples.
//!
//! The scheme's description is Larson's, in libtiff's tif_luv.c (Larson and
//! SGI, permissive license); this code is written from it, not copied.
//! Each row is coded on its own, as byte planes, most significant first:
//! two planes for LogL (Photometric 32844, a sign bit and a 15-bit log
//! luminance) and four for LogLuv (Photometric 32845, that 16-bit value then
//! 8-bit u and v). Each plane is run-length coded: a byte b of 128 or more is
//! a run, the next byte repeated b - 126 times; a byte below 128 is a literal
//! count, that many bytes follow (0 is allowed and adds nothing).
//!
//! The directory describes the decoded form, 16-bit signed samples
//! (SampleFormat 2): LogL is the stored value; LogLuv becomes L, u and v,
//! where u = (ue + 0.5) / 410, scaled by 32768 and truncated toward zero, and
//! likewise v. Samples are written in the file's byte order.
//!
//! SGILog24 (LogLuv only) has no run-length coding: each pixel is 3
//! big-endian bytes, a 10-bit log luminance Le over a 14-bit index Ce into
//! Larson's (u', v') table (sgilog_uv.zig). It decodes to the same three
//! samples: L = 4 * Le + 13314, the 16-bit log luminance at the center of
//! Le's bin, and u and v from the center of square Ce, scaled and truncated
//! as above. libtiff masks the shifted value with 0xffd rather than 0xffc,
//! so its L also carries bit 12 of Ce; that looks like a slip, and tiffz
//! follows the documented form instead, so its L can be 1 lower.
//!
//! Stricter than libtiff, which stops filling a plane at the row's end and
//! reads what is left of a literal as codes: a run or literal past the end
//! of its plane is Malformed. An SGILog24 index past the table is Malformed
//! too (libtiff substitutes neutral gray; its encoder never writes one).
//! Data that ends early is SourceTooShort.

const std = @import("std");
const errors = @import("tiffz-parser").errors;
const Endian = @import("tiffz-parser").header.Endian;
const uv_table = @import("sgilog_uv.zig");

/// `log_l` and `log_luv` are Compression 34676; `log_luv24` is 34677.
pub const Kind = enum { log_l, log_luv, log_luv24 };

const uv_scale: f64 = 410.0;

/// Decode `rows` rows of `width` pixels into `dest`. Returns the bytes
/// written: 2 per pixel for LogL, 6 for LogLuv.
pub fn decode(src: []const u8, dest: []u8, width: u32, rows: u32, kind: Kind, endian: Endian) errors.Error!usize {
    if (kind == .log_luv24) return decode24(src, dest, width, rows, endian);
    const planes: usize = if (kind == .log_l) 2 else 4;
    const out_per_pixel: usize = if (kind == .log_l) 2 else 6;
    const row_out = std.math.mul(usize, width, out_per_pixel) catch return error.Malformed;
    const total = std.math.mul(usize, row_out, rows) catch return error.Malformed;
    if (dest.len < total) return error.DestTooSmall;
    const order: std.builtin.Endian = if (endian == .little) .little else .big;

    var pos: usize = 0;
    for (0..rows) |r| {
        const row = dest[r * row_out ..][0..row_out];
        // Assemble each pixel's stored bits across the planes, most
        // significant plane first, in a row-sized scratch kept in `row`
        // itself: a pixel's stored value fits its output slot.
        var p: usize = 0;
        while (p < planes) : (p += 1) {
            var x: usize = 0;
            while (x < width) {
                if (pos >= src.len) return error.SourceTooShort;
                const b = src[pos];
                pos += 1;
                if (b >= 128) {
                    const count: usize = @as(usize, b) - 126;
                    if (pos >= src.len) return error.SourceTooShort;
                    const value = src[pos];
                    pos += 1;
                    if (x + count > width) return error.Malformed;
                    for (0..count) |_| {
                        setPlane(row, x, p, planes, value);
                        x += 1;
                    }
                } else {
                    const count: usize = b;
                    if (x + count > width) return error.Malformed;
                    if (src.len - pos < count) return error.SourceTooShort;
                    for (src[pos..][0..count]) |value| {
                        setPlane(row, x, p, planes, value);
                        x += 1;
                    }
                    pos += count;
                }
            }
        }
        // Expand stored values to the decoded samples, back to front so a
        // LogLuv pixel's 4 stored bytes are read before its 6 output bytes
        // overwrite them.
        var i: usize = width;
        while (i > 0) {
            i -= 1;
            if (kind == .log_l) {
                const v = std.mem.readInt(u16, row[i * 2 ..][0..2], .big);
                std.mem.writeInt(u16, row[i * 2 ..][0..2], v, order);
            } else {
                const stored = std.mem.readInt(u32, row[i * 4 ..][0..4], .big);
                const l: u16 = @intCast(stored >> 16);
                const u: i16 = uvSample(@intCast((stored >> 8) & 0xFF));
                const v: i16 = uvSample(@intCast(stored & 0xFF));
                std.mem.writeInt(u16, row[i * 6 ..][0..2], l, order);
                std.mem.writeInt(i16, row[i * 6 + 2 ..][0..2], u, order);
                std.mem.writeInt(i16, row[i * 6 + 4 ..][0..2], v, order);
            }
        }
    }
    return total;
}

fn decode24(src: []const u8, dest: []u8, width: u32, rows: u32, endian: Endian) errors.Error!usize {
    const pixels = std.math.mul(usize, width, rows) catch return error.Malformed;
    const total = std.math.mul(usize, pixels, 6) catch return error.Malformed;
    if (dest.len < total) return error.DestTooSmall;
    if (src.len / 3 < pixels) return error.SourceTooShort;
    const order: std.builtin.Endian = if (endian == .little) .little else .big;
    for (0..pixels) |i| {
        const stored = std.mem.readInt(u24, src[i * 3 ..][0..3], .big);
        const le: u16 = @intCast(stored >> 14);
        const uv = uvCenter(@intCast(stored & 0x3FFF)) orelse return error.Malformed;
        const out = dest[i * 6 ..][0..6];
        std.mem.writeInt(u16, out[0..2], le * 4 + 13314, order);
        std.mem.writeInt(i16, out[2..4], @intFromFloat(uv.u * 32768.0), order);
        std.mem.writeInt(i16, out[4..6], @intFromFloat(uv.v * 32768.0), order);
    }
    return total;
}

const Uv = struct { u: f64, v: f64 };

/// The center of square `c` in Larson's table, in the table's own float
/// constants widened to double, or null past the table.
fn uvCenter(c: u16) ?Uv {
    if (c >= uv_table.divisions) return null;
    // The last row whose squares start at or before c.
    var lower: usize = 0;
    var upper: usize = uv_table.rows.len;
    while (upper - lower > 1) {
        const mid = (lower + upper) / 2;
        if (uv_table.rows[mid].ncum <= c) lower = mid else upper = mid;
    }
    const row = uv_table.rows[lower];
    const ui: f64 = @floatFromInt(c - row.ncum);
    const vi: f64 = @floatFromInt(lower);
    const sq: f64 = uv_table.sq_size;
    return .{
        .u = @as(f64, row.ustart) + (ui + 0.5) * sq,
        .v = @as(f64, uv_table.v_start) + (vi + 0.5) * sq,
    };
}

/// Byte `plane` (0 most significant) of pixel `x`'s stored value, kept
/// big-endian at the start of the row while the planes are read.
fn setPlane(row: []u8, x: usize, plane: usize, planes: usize, value: u8) void {
    row[x * planes + plane] = value;
}

fn uvSample(e: u8) i16 {
    const real = 1.0 / uv_scale * (@as(f64, @floatFromInt(e)) + 0.5);
    return @intFromFloat(real * 32768.0);
}

test "SGILog LogL: runs and literals per byte plane, in the file's byte order" {
    // Width 3. High plane: a run of 3 of 0x12. Low plane: a literal of 3.
    const src = [_]u8{ 128 + 1, 0x12, 3, 0x01, 0x02, 0x03 };
    var dest: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try decode(&src, &dest, 3, 1, .log_l, .little));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x12, 0x02, 0x12, 0x03, 0x12 }, &dest);
    _ = try decode(&src, &dest, 3, 1, .log_l, .big);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x01, 0x12, 0x02, 0x12, 0x03 }, &dest);
}

test "SGILog LogLuv: four planes become L, u and v" {
    // Width 1: L = 0x3456, ue = 100, ve = 200, each plane a literal of 1.
    const src = [_]u8{ 1, 0x34, 1, 0x56, 1, 100, 1, 200 };
    var dest: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try decode(&src, &dest, 1, 1, .log_luv, .little));
    try std.testing.expectEqual(@as(u16, 0x3456), std.mem.readInt(u16, dest[0..2], .little));
    // (100.5 / 410) * 32768 = 8032.0..., (200.5 / 410) * 32768 = 16024.3...
    try std.testing.expectEqual(@as(i16, 8032), std.mem.readInt(i16, dest[2..4], .little));
    try std.testing.expectEqual(@as(i16, 16024), std.mem.readInt(i16, dest[4..6], .little));
}

test "SGILog: a run or literal past its plane, and data that ends early, fail" {
    var dest: [6]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&.{ 128 + 2, 0x12 }, &dest, 3, 1, .log_l, .little)); // run of 4
    try std.testing.expectError(error.Malformed, decode(&.{ 4, 1, 2, 3, 4 }, &dest, 3, 1, .log_l, .little)); // literal of 4
    try std.testing.expectError(error.SourceTooShort, decode(&.{ 128 + 1, 0x12 }, &dest, 3, 1, .log_l, .little)); // no low plane
}

test "SGILog24: 10-bit luminance and a table index become L, u and v" {
    // Le = 512 with Ce = 0 (row 0, first square); Le = 1 with Ce = 16288
    // (row 162, square 20, the last). Expected u and v were computed apart
    // from this code: the C header's float constants, widened, times 32768.
    const src = [_]u8{ 0x80, 0x00, 0x00, 0x00, 0x7F, 0xA0 };
    var dest: [12]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 12), try decode(&src, &dest, 2, 1, .log_luv24, .little));
    try std.testing.expectEqual(@as(u16, 512 * 4 + 13314), std.mem.readInt(u16, dest[0..2], .little));
    try std.testing.expectEqual(@as(i16, 8172), std.mem.readInt(i16, dest[2..4], .little));
    try std.testing.expectEqual(@as(i16, 612), std.mem.readInt(i16, dest[4..6], .little));
    try std.testing.expectEqual(@as(u16, 4 + 13314), std.mem.readInt(u16, dest[6..8], .little));
    try std.testing.expectEqual(@as(i16, 3126), std.mem.readInt(i16, dest[8..10], .little));
    try std.testing.expectEqual(@as(i16, 19191), std.mem.readInt(i16, dest[10..12], .little));
    _ = try decode(&src, &dest, 2, 1, .log_luv24, .big);
    try std.testing.expectEqual(@as(i16, 19191), std.mem.readInt(i16, dest[10..12], .big));
}

test "SGILog24: the first square of every row, and an index past the table" {
    for (uv_table.rows, 0..) |row, vi| {
        const uv = uvCenter(row.ncum).?;
        try std.testing.expectEqual(@as(f64, row.ustart) + 0.5 * @as(f64, uv_table.sq_size), uv.u);
        try std.testing.expectEqual(@as(f64, uv_table.v_start) + (@as(f64, @floatFromInt(vi)) + 0.5) * @as(f64, uv_table.sq_size), uv.v);
        if (row.nus > 1) try std.testing.expectEqual(uv.v, uvCenter(row.ncum + row.nus - 1).?.v);
    }
    try std.testing.expect(uvCenter(uv_table.divisions) == null);
    var dest: [6]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&.{ 0x00, 0x3F, 0xA1 }, &dest, 1, 1, .log_luv24, .big)); // Ce 16289
    try std.testing.expectError(error.SourceTooShort, decode(&.{ 0x00, 0x00 }, &dest, 1, 1, .log_luv24, .big));
}

test {
    _ = uv_table;
}
