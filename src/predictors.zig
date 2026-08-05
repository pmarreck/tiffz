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

const parser = @import("tiffz-parser");
const errors = parser.errors;
const tags = parser.tags;
const header_mod = parser.header;
const Endian = header_mod.Endian;

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
/// 8-bit horizontal (Predictor=2) is fully supported; 16-bit
/// horizontal is deferred (needs endian-aware u16 reads) and lands
/// alongside DNG raw at M8. Floating-point (Predictor=3) follows
/// TIFF Tech Note 3: byte-plane interleaved horizontal byte
/// differencing with bps ∈ {16, 24, 32, 64}. The de-interleave step
/// needs a per-row scratch buffer of size `bytes_per_row` — allocated
/// from the caller's allocator only when Predictor=3 is active.
pub fn applyInverse(
    bytes: []u8,
    predictor: Predictor,
    width: u32,
    rows: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    planar_config: PlanarConfig,
    endian: Endian,
    allocator: std.mem.Allocator,
) errors.Error!void {
    switch (predictor) {
        .none => return,
        .horizontal => return applyHorizontal(bytes, width, rows, samples_per_pixel, bits_per_sample, planar_config, endian),
        .floating_point => return applyFloatingPoint(bytes, width, rows, samples_per_pixel, bits_per_sample, planar_config, endian, allocator),
        else => return error.UnsupportedPredictor,
    }
}

fn applyHorizontal(
    bytes: []u8,
    width: u32,
    rows: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    planar_config: PlanarConfig,
    endian: Endian,
) errors.Error!void {
    // Stride between samples of the same channel within a row, in
    // SAMPLES (not bytes). Chunky: samples_per_pixel. Separate: 1.
    const stride_samples: usize = switch (planar_config) {
        .chunky => @intCast(samples_per_pixel),
        .separate => 1,
        else => return error.Malformed,
    };
    const row_samples: usize = @as(usize, width) * (if (planar_config == .chunky) @as(usize, samples_per_pixel) else 1);

    switch (bits_per_sample) {
        8 => {
            const bytes_per_row: usize = row_samples;
            if (bytes.len < bytes_per_row * rows) return error.SourceShortRead;
            var rows_done: u32 = 0;
            while (rows_done < rows) : (rows_done += 1) {
                const row = bytes[rows_done * bytes_per_row ..][0..bytes_per_row];
                var i: usize = stride_samples;
                while (i < row.len) : (i += 1) {
                    row[i] = row[i] +% row[i - stride_samples];
                }
            }
        },
        16 => {
            const bytes_per_row: usize = row_samples * 2;
            if (bytes.len < bytes_per_row * rows) return error.SourceShortRead;
            const std_endian: std.builtin.Endian = if (endian == .little) .little else .big;
            var rows_done: u32 = 0;
            while (rows_done < rows) : (rows_done += 1) {
                const row = bytes[rows_done * bytes_per_row ..][0..bytes_per_row];
                // Operate per-u16 with endian-aware read/write. Wrap
                // mod 2^16 via Zig's `+%` on the u16 values.
                var sample_idx: usize = stride_samples;
                while (sample_idx < row_samples) : (sample_idx += 1) {
                    const prev = std.mem.readInt(u16, row[(sample_idx - stride_samples) * 2 ..][0..2], std_endian);
                    const here = std.mem.readInt(u16, row[sample_idx * 2 ..][0..2], std_endian);
                    std.mem.writeInt(u16, row[sample_idx * 2 ..][0..2], here +% prev, std_endian);
                }
            }
        },
        else => return error.UnsupportedBitDepth,
    }
}

/// Predictor=3 inverse per TIFF Tech Note 3 (Adobe, 2005).
///
/// Encoder side: each row's floating-point samples are reshuffled by
/// byte position before any compression. Per TN3 the byte planes are
/// stored MSB-first regardless of the file's TIFF byte-order header —
/// plane 0 holds the most-significant byte of every sample, plane 1
/// the next byte, and so on down to plane (bps-1) = LSB. Then
/// horizontal byte differencing with stride = samples_per_pixel is
/// applied across the entire reshuffled row, deliberately straddling
/// plane boundaries (libtiff `fpAcc` matches this).
///
/// Decoder side reverses both steps per row:
///   1. Inverse horizontal byte-diff: row[i] += row[i - stride] (mod 256)
///      for i in [stride, row_bytes).
///   2. De-interleave byte planes back into per-sample bytes, taking
///      file endian into account: for a big-endian file, byte offset
///      k of sample n in memory corresponds to byte plane k; for a
///      little-endian file, byte offset k corresponds to byte plane
///      (bps - 1 - k) because the LSB lives at offset 0 of the sample.
///      Requires a scratch buffer of size = bytes_per_row.
fn applyFloatingPoint(
    bytes: []u8,
    width: u32,
    rows: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    planar_config: PlanarConfig,
    endian: Endian,
    allocator: std.mem.Allocator,
) errors.Error!void {
    // FP predictor needs at least 16 bits per sample (FP16). 8-bit
    // doesn't make sense as a "floating point" sample width.
    if (bits_per_sample == 0 or bits_per_sample % 8 != 0 or bits_per_sample < 16) {
        return error.UnsupportedBitDepth;
    }
    const bps_bytes: usize = bits_per_sample / 8;

    const samples_per_row: usize = switch (planar_config) {
        .chunky => @as(usize, width) * @as(usize, samples_per_pixel),
        .separate => @as(usize, width),
        else => return error.Malformed,
    };
    const stride: usize = switch (planar_config) {
        .chunky => @intCast(samples_per_pixel),
        .separate => 1,
        else => unreachable,
    };
    const bytes_per_row: usize = samples_per_row * bps_bytes;
    if (bytes.len < bytes_per_row * rows) return error.SourceShortRead;

    const scratch = allocator.alloc(u8, bytes_per_row) catch return error.OutOfMemory;
    defer allocator.free(scratch);

    var rows_done: u32 = 0;
    while (rows_done < rows) : (rows_done += 1) {
        const row = bytes[rows_done * bytes_per_row ..][0..bytes_per_row];

        // Step 1: inverse horizontal byte-differencing with stride.
        var i: usize = stride;
        while (i < row.len) : (i += 1) {
            row[i] = row[i] +% row[i - stride];
        }

        // Step 2: de-interleave byte planes back into per-sample bytes
        // with endian-aware plane→byte mapping.
        @memcpy(scratch, row);
        const wc: usize = samples_per_row;
        var n: usize = 0;
        while (n < wc) : (n += 1) {
            var k: usize = 0;
            while (k < bps_bytes) : (k += 1) {
                const plane: usize = if (endian == .little) bps_bytes - 1 - k else k;
                row[n * bps_bytes + k] = scratch[plane * wc + n];
            }
        }
    }
}

// ---- tests ----

test "predictors.applyInverse none = identity" {
    var bytes = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try applyInverse(&bytes, .none, 2, 1, 3, 8, .chunky, .little, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &bytes);
}

test "predictors.applyInverse horizontal RGB chunky 8-bit" {
    // Original row 1 pixel at a time: (10,20,30) (40,50,60) (70,80,90)
    // Encoded deltas: (10,20,30) (30,30,30) (30,30,30)
    var bytes = [_]u8{ 10, 20, 30, 30, 30, 30, 30, 30, 30 };
    try applyInverse(&bytes, .horizontal, 3, 1, 3, 8, .chunky, .little, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60, 70, 80, 90 }, &bytes);
}

test "predictors.applyInverse horizontal handles 8-bit wrap-around" {
    // Encoded: 200, 100. Sum = 300 → wraps to 44.
    var bytes = [_]u8{ 200, 100 };
    try applyInverse(&bytes, .horizontal, 2, 1, 1, 8, .chunky, .little, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 200, 44 }, &bytes);
}

test "predictors.applyInverse horizontal multi-row preserves row boundary" {
    // Two rows of 2 pixels × 1 sample. Encoded:
    //   row 0: 10, 5  → decoded: 10, 15
    //   row 1: 20, 5  → decoded: 20, 25
    // Critically: row 1's first sample is NOT incremented by row 0's last.
    var bytes = [_]u8{ 10, 5, 20, 5 };
    try applyInverse(&bytes, .horizontal, 2, 2, 1, 8, .chunky, .little, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 10, 15, 20, 25 }, &bytes);
}

test "predictors.applyInverse separate planar config uses stride=1" {
    // For separate planar, each strip holds ONE plane: the per-strip
    // samples-per-pixel is 1 regardless of the IFD's overall
    // SamplesPerPixel. previous-sample is 1 byte back.
    var bytes = [_]u8{ 5, 10, 5, 5 };
    try applyInverse(&bytes, .horizontal, 4, 1, 1, 8, .separate, .little, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 5, 15, 20, 25 }, &bytes);
}

test "predictors.applyInverse horizontal 16-bit big-endian" {
    // F0=0x1234, F1=0x1300. Encoded delta: F1-F0=0x1300-0x1234=0x00CC.
    // Big-endian byte order: F0 [0x12,0x34], delta [0x00,0xCC].
    var bytes = [_]u8{ 0x12, 0x34, 0x00, 0xCC };
    try applyInverse(&bytes, .horizontal, 2, 1, 1, 16, .chunky, .big, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x13, 0x00 }, &bytes);
}

test "predictors.applyInverse horizontal 16-bit little-endian" {
    // Same F0=0x1234, F1=0x1300 but stored little-endian:
    //   F0 [0x34,0x12], delta=0x00CC stored as [0xCC,0x00].
    var bytes = [_]u8{ 0x34, 0x12, 0xCC, 0x00 };
    try applyInverse(&bytes, .horizontal, 2, 1, 1, 16, .chunky, .little, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0x00, 0x13 }, &bytes);
}

test "predictors.applyInverse horizontal 16-bit wraps mod 2^16" {
    // F0=0xFF00, delta=0x0200 → F1=0xFF00+0x0200=0x10100 → wraps to 0x0100.
    var bytes = [_]u8{ 0xFF, 0x00, 0x02, 0x00 };
    try applyInverse(&bytes, .horizontal, 2, 1, 1, 16, .chunky, .big, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x01, 0x00 }, &bytes);
}

test "predictors.applyInverse horizontal 16-bit RGB chunky preserves row boundary" {
    // 2 rows × 2 pixels × 3 channels × 2 bytes = 24 bytes per row × 2 rows = 48 bytes
    // For simplicity: 2 rows × 2 pixels × 1 channel × 2 bytes (16 bytes).
    // Row 0: F0=0x0100, F1=0x0200 → deltas [0x0100, 0x0100]; bytes BE = [0x01,0x00, 0x01,0x00]
    // Row 1: F0=0x0300, F1=0x0500 → deltas [0x0300, 0x0200]; bytes BE = [0x03,0x00, 0x02,0x00]
    // Row 1's first u16 must NOT be incremented by row 0's last.
    var bytes = [_]u8{ 0x01, 0x00, 0x01, 0x00, 0x03, 0x00, 0x02, 0x00 };
    try applyInverse(&bytes, .horizontal, 2, 2, 1, 16, .chunky, .big, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x05, 0x00 }, &bytes);
}

test "predictors.applyInverse rejects 32-bit horizontal (FP-only at >8bit)" {
    var bytes = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedBitDepth, applyInverse(&bytes, .horizontal, 1, 1, 1, 32, .chunky, .little, std.testing.allocator));
}

test "predictors.applyInverse rejects floating-point at 8-bit (FP needs bps >= 16)" {
    var bytes = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedBitDepth, applyInverse(&bytes, .floating_point, 4, 1, 1, 8, .chunky, .little, std.testing.allocator));
}

test "predictors.applyInverse floating-point FP32 spp=1 two rows, big-endian" {
    // M8 — Predictor=3 (TIFF Tech Note 3), byte-plane interleaved
    // horizontal differencing inverse on FP32 (bps=32, 4 bytes/sample).
    //
    // Spec recipe (decoder side):
    //   1. Inverse horizontal byte-differencing across the full row at
    //      stride = samples_per_pixel (1 here).
    //   2. De-interleave byte planes back into per-sample bytes. Per
    //      TN3 plane 0 = MSB of every sample regardless of file endian.
    //      Big-endian file: byte offset k of sample n in memory comes
    //      from plane k (this test). Little-endian file would invert
    //      that mapping.
    //
    // Layout for spp=1, width=2, bps=32, big-endian:
    //   floats in file byte order: F0=[A,B,C,D] (A=MSB), F1=[E,F,G,H]
    //   byte-plane interleave: [A, E, B, F, C, G, D, H]
    //   byte-diff with stride=1: [A, E-A, B-E, F-B, C-F, G-C, D-G, H-D]
    //   (each wrap mod 256)
    //
    // Hand-derived row 0: F0=[0x01,0x02,0x03,0x04], F1=[0x10,0x20,0x30,0x40]
    //   interleaved: [0x01, 0x10, 0x02, 0x20, 0x03, 0x30, 0x04, 0x40]
    //   diffed:      [0x01, 0x0F, 0xF2, 0x1E, 0xE3, 0x2D, 0xD4, 0x3C]
    //
    // Hand-derived row 1: F0=[0xAA,0xBB,0xCC,0xDD], F1=[0xEE,0xFF,0x11,0x22]
    //   interleaved: [0xAA, 0xEE, 0xBB, 0xFF, 0xCC, 0x11, 0xDD, 0x22]
    //   diffed:      [0xAA, 0x44, 0xCD, 0x44, 0xCD, 0x45, 0xCC, 0x45]
    //
    // Row 1's first byte (0xAA) must be left alone — row boundary
    // resets the byte-diff chain.
    var bytes = [_]u8{
        // Row 0 encoded
        0x01, 0x0F, 0xF2, 0x1E, 0xE3, 0x2D, 0xD4, 0x3C,
        // Row 1 encoded
        0xAA, 0x44, 0xCD, 0x44, 0xCD, 0x45, 0xCC, 0x45,
    };
    const expected = [_]u8{
        // Row 0 decoded
        0x01, 0x02, 0x03, 0x04, 0x10, 0x20, 0x30, 0x40,
        // Row 1 decoded
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22,
    };
    try applyInverse(&bytes, .floating_point, 2, 2, 1, 32, .chunky, .big, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}

test "predictors.applyInverse floating-point FP32 little-endian inverts plane mapping" {
    // Same encoded bytes as the big-endian test (the on-wire format
    // is identical — byte planes are MSB-first regardless). Only the
    // de-interleave's plane→byte mapping flips: in LE memory, byte 0
    // of each float is the LSB (= plane bps-1 = plane 3 for FP32).
    var bytes = [_]u8{ 0x01, 0x0F, 0xF2, 0x1E, 0xE3, 0x2D, 0xD4, 0x3C };
    // After byte-diff inverse: [0x01, 0x10, 0x02, 0x20, 0x03, 0x30, 0x04, 0x40]
    // De-interleave to LE memory: sample F0 byte 0 = plane 3 = 0x04;
    // byte 1 = plane 2 = 0x03; byte 2 = plane 1 = 0x02; byte 3 = plane 0 = 0x01.
    const expected = [_]u8{ 0x04, 0x03, 0x02, 0x01, 0x40, 0x30, 0x20, 0x10 };
    try applyInverse(&bytes, .floating_point, 2, 1, 1, 32, .chunky, .little, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}

test "predictors.applyInverse floating-point FP32 RGB chunky" {
    // RGB FP32, width=2, rows=1, spp=3 — verifies stride=3 byte-diff
    // and the de-interleave with cross-channel byte planes.
    //
    // F0R=[0x01,0x02,0x03,0x04] F0G=[0x05,0x06,0x07,0x08] F0B=[0x09,0x0A,0x0B,0x0C]
    // F1R=[0x10,0x20,0x30,0x40] F1G=[0x50,0x60,0x70,0x80] F1B=[0x90,0xA0,0xB0,0xC0]
    //
    // Byte-plane interleave (wc=6, 4 planes):
    //   P0=[0x01,0x05,0x09,0x10,0x50,0x90]
    //   P1=[0x02,0x06,0x0A,0x20,0x60,0xA0]
    //   P2=[0x03,0x07,0x0B,0x30,0x70,0xB0]
    //   P3=[0x04,0x08,0x0C,0x40,0x80,0xC0]
    //
    // After byte-diff stride=3 (verify by hand: each byte minus the
    // byte 3 positions back, mod 256).
    var bytes = [_]u8{
        0x01, 0x05, 0x09, 0x0F, 0x4B, 0x87,
        0xF2, 0xB6, 0x7A, 0x1E, 0x5A, 0x96,
        0xE3, 0xA7, 0x6B, 0x2D, 0x69, 0xA5,
        0xD4, 0x98, 0x5C, 0x3C, 0x78, 0xB4,
    };
    const expected = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0,
    };
    try applyInverse(&bytes, .floating_point, 2, 1, 3, 32, .chunky, .big, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}

test "predictors.applyInverse floating-point FP32 separate planar uses stride=1" {
    // Separate planar — each strip is one plane, stride=1, wc=width.
    // width=4, rows=1, bps=32. The fixture is constructed so the diff
    // chain visibly steps across the plane boundaries.
    var bytes = [_]u8{
        0x10, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x01,
        0x0D, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x01,
    };
    const expected = [_]u8{
        0x10, 0x20, 0x30, 0x40,
        0x11, 0x21, 0x31, 0x41,
        0x12, 0x22, 0x32, 0x42,
        0x13, 0x23, 0x33, 0x43,
    };
    try applyInverse(&bytes, .floating_point, 4, 1, 1, 32, .separate, .big, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}

test "predictors.applyInverse floating-point FP16 chunky" {
    // FP16 (bps=16, 2 bytes/sample) — the minimum FP precision the
    // predictor supports. width=2, rows=1, spp=1.
    //   F0=[0xAB,0xCD], F1=[0xEF,0x12]
    //   interleaved: [0xAB, 0xEF, 0xCD, 0x12]
    //   diffed:      [0xAB, 0x44, 0xDE, 0x45]
    var bytes = [_]u8{ 0xAB, 0x44, 0xDE, 0x45 };
    const expected = [_]u8{ 0xAB, 0xCD, 0xEF, 0x12 };
    try applyInverse(&bytes, .floating_point, 2, 1, 1, 16, .chunky, .big, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &expected, &bytes);
}
