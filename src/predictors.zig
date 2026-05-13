//! TIFF Predictor (tag 317) inverse application.
//!
//! Predictors are encoded BEFORE compression and reversed AFTER
//! decompression. They make the post-codec bytes more
//! compressible by replacing absolute pixel values with deltas
//! against the previous-column value of the same sample channel.
//!
//! Per TIFF Technical Note 1 (Adobe, 1992):
//!
//!   1 = None — no transform applied; pass-through.
//!   2 = Horizontal differencing — for each row and each sample
//!       channel, `out[i] = in[i] - in[i-1] (mod 2^bits_per_sample)`,
//!       with the first sample of each row stored verbatim. Reverse
//!       on decode: `in[i] = in[i-1] + out[i]` (mod 2^bits).
//!   3 = Floating-point — TIFF Tech Note 3. Byte-interleaved
//!       per-byte-plane horizontal differencing. M8 (DNG) territory;
//!       deferred.
//!
//! Operates in-place on the decoded strip bytes. For chunky planar
//! config (TIFF default), the "previous sample in row" is at
//! `samples_per_pixel` byte positions back. For separate planar
//! config (less common), each strip is one plane and the stride is
//! always 1.

const std = @import("std");

const errors = @import("errors.zig");
const tags = @import("tags.zig");

pub const Predictor = enum(u16) {
    none = 1,
    horizontal = 2,
    floating_point = 3,
    _,

    pub fn fromU16(v: u16) Predictor {
        return @enumFromInt(v);
    }
};

pub const PlanarConfig = enum(u16) {
    chunky = 1,
    separate = 2,
    _,
};

/// Apply the inverse of `predictor` to `bytes` in-place. `bytes`
/// holds `rows` consecutive rows of `width` pixels with
/// `samples_per_pixel` samples per pixel at `bits_per_sample` bits
/// per sample, in either chunky or separate planar config.
///
/// 8-bit-per-sample is fully supported. 16-bit requires reading file
/// byte order and is not yet implemented — surfaces as
/// UnsupportedBitDepth.
pub fn applyInverse(
    bytes: []u8,
    predictor: Predictor,
    width: u32,
    rows: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    planar_config: PlanarConfig,
) errors.Error!void {
    switch (predictor) {
        .none => return,
        .horizontal => {},
        .floating_point => return error.UnsupportedPredictor,
        else => return error.UnsupportedPredictor,
    }

    if (bits_per_sample != 8) return error.UnsupportedBitDepth;

    // Stride between samples of the same channel within a row.
    // Chunky: samples_per_pixel (R[0] G[0] B[0] R[1] G[1] B[1] …, so
    //         R[1] is samples_per_pixel bytes past R[0]).
    // Separate: 1 (each strip is one plane; previous sample is the
    //           previous byte directly).
    const stride: usize = switch (planar_config) {
        .chunky => @intCast(samples_per_pixel),
        .separate => 1,
        else => return error.Malformed,
    };

    const row_samples: usize = @as(usize, width) * @as(usize, samples_per_pixel);
    const bytes_per_row: usize = row_samples; // 8-bit only for now
    if (bytes.len < bytes_per_row * rows) return error.SourceShortRead;

    var rows_done: u32 = 0;
    while (rows_done < rows) : (rows_done += 1) {
        const row = bytes[rows_done * bytes_per_row ..][0..bytes_per_row];
        // First `stride` samples are absolute (the "row prefix");
        // subsequent samples are deltas against the same-channel
        // sample `stride` bytes back. Reverse: in[i] = in[i-stride] + out[i].
        var i: usize = stride;
        while (i < row.len) : (i += 1) {
            row[i] = row[i] +% row[i - stride];
        }
    }
}

// ---- tests ----

test "predictors.applyInverse none = identity" {
    var bytes = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try applyInverse(&bytes, .none, 2, 1, 3, 8, .chunky);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &bytes);
}

test "predictors.applyInverse horizontal RGB chunky 8-bit" {
    // Original row 1 pixel at a time: (10,20,30) (40,50,60) (70,80,90)
    // Encoded deltas: (10,20,30) (30,30,30) (30,30,30)
    var bytes = [_]u8{ 10, 20, 30, 30, 30, 30, 30, 30, 30 };
    try applyInverse(&bytes, .horizontal, 3, 1, 3, 8, .chunky);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60, 70, 80, 90 }, &bytes);
}

test "predictors.applyInverse horizontal handles 8-bit wrap-around" {
    // Encoded: 200, 100. Sum = 300 → wraps to 44.
    var bytes = [_]u8{ 200, 100 };
    try applyInverse(&bytes, .horizontal, 2, 1, 1, 8, .chunky);
    try std.testing.expectEqualSlices(u8, &.{ 200, 44 }, &bytes);
}

test "predictors.applyInverse horizontal multi-row preserves row boundary" {
    // Two rows of 2 pixels × 1 sample. Encoded:
    //   row 0: 10, 5  → decoded: 10, 15
    //   row 1: 20, 5  → decoded: 20, 25
    // Critically: row 1's first sample is NOT incremented by row 0's last.
    var bytes = [_]u8{ 10, 5, 20, 5 };
    try applyInverse(&bytes, .horizontal, 2, 2, 1, 8, .chunky);
    try std.testing.expectEqualSlices(u8, &.{ 10, 15, 20, 25 }, &bytes);
}

test "predictors.applyInverse separate planar config uses stride=1" {
    // For separate planar, each strip holds ONE plane: the per-strip
    // samples-per-pixel is 1 regardless of the IFD's overall
    // SamplesPerPixel. previous-sample is 1 byte back.
    var bytes = [_]u8{ 5, 10, 5, 5 };
    try applyInverse(&bytes, .horizontal, 4, 1, 1, 8, .separate);
    try std.testing.expectEqualSlices(u8, &.{ 5, 15, 20, 25 }, &bytes);
}

test "predictors.applyInverse rejects 16-bit (M5 limitation)" {
    var bytes = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedBitDepth, applyInverse(&bytes, .horizontal, 2, 1, 1, 16, .chunky));
}

test "predictors.applyInverse rejects floating-point (M8 territory)" {
    var bytes = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedPredictor, applyInverse(&bytes, .floating_point, 4, 1, 1, 8, .chunky));
}
