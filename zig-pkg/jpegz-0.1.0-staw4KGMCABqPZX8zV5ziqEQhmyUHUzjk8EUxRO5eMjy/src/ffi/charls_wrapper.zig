//! Phase 1 wrapper around charls (BSD-3) for JPEG-LS (T.87).
//!
//! libjpeg-turbo does not implement JPEG-LS; charls is the canonical
//! reference. We expose just enough of its C ABI to decode a SOF55
//! bitstream into a fully-realized `Image`. Cleanroom comes later (B2)
//! and uses this wrapper as its oracle.
//!
//! charls is a C++ library, but its public ABI is C-only — no exception
//! propagation, no name-mangling. We pull in libc++ at the link level
//! (see build.zig); from Zig's perspective it's just another C lib.
//!
//! Detection: a JPEG-LS byte stream starts with `FF D8` (SOI) like any
//! JPEG, then `FF F7` (SOF55 / JPG7) appears somewhere in the marker
//! chain before SOS. Public `decode` peeks the marker walk to classify
//! the variant before involving charls; non-JPEG-LS inputs return
//! `error.NotImplemented` so the dispatcher can fall through.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../jpegz.zig");

const c = @cImport({
    @cInclude("charls/charls.h");
});

/// charls' I8 enum cast — interleave mode tells us pixel layout.
/// 0 = none (planar), 1 = line-interleaved, 2 = sample-interleaved (RGB).
const Interleave = enum(c_int) {
    none = 0,
    line = 1,
    sample = 2,
    _,
};

/// Peek the JPEG byte stream for the SOF55 marker (FF F7). Cheap
/// pre-flight to avoid spinning up charls for inputs that aren't
/// JPEG-LS — same pattern as `looksLikeJpeg` in libjpeg_wrapper.zig.
/// Returns true iff a SOF55 marker appears before any other SOF.
fn looksLikeJpegLs(data: []const u8) bool {
    if (data.len < 4) return false;
    if (data[0] != 0xFF or data[1] != 0xD8) return false;
    var pos: usize = 2;
    while (pos + 1 < data.len) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos + 1 >= data.len) return false;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return false;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0xF7 => return true, // SOF55 — JPEG-LS frame
            // Any other SOFn means it's a regular JPEG, not JPEG-LS.
            0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
            0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => return false,
            0xDA, 0xD9 => return false, // SOS or EOI before SOF55 — not JPEG-LS
            // Skip length-prefixed segments.
            0xD0...0xD7, 0xD8, 0x01 => {},
            else => {
                if (pos + 1 >= data.len) return false;
                const seg_len: usize = (@as(usize, data[pos]) << 8) | data[pos + 1];
                if (seg_len < 2) return false;
                if (pos + seg_len > data.len) return false;
                pos += seg_len;
            },
        }
    }
    return false;
}

/// Decode a JPEG-LS byte stream into a fully-realized Image. Returns
/// `error.NotImplemented` for non-JPEG-LS inputs (so the dispatcher
/// falls through) and `error.BackendError` for charls failures.
pub fn decode(allocator: Allocator, data: []const u8) errors.DecodeError!types.Image {
    if (!looksLikeJpegLs(data)) return error.NotImplemented;

    const decoder = c.charls_jpegls_decoder_create() orelse return error.OutOfMemory;
    defer c.charls_jpegls_decoder_destroy(decoder);

    if (c.charls_jpegls_decoder_set_source_buffer(decoder, data.ptr, data.len) != 0)
        return error.BackendError;
    if (c.charls_jpegls_decoder_read_header(decoder) != 0)
        return error.BackendError;

    var fi: c.charls_frame_info = undefined;
    if (c.charls_jpegls_decoder_get_frame_info(decoder, &fi) != 0)
        return error.BackendError;

    if (fi.bits_per_sample < 1 or fi.bits_per_sample > 16)
        return error.UnsupportedPrecision;
    if (fi.component_count != 1 and fi.component_count != 3)
        return error.NotImplemented; // 2/4-comp T.87 is rare; not needed for v1.

    const channels: u8 = @intCast(fi.component_count);
    const bps: u8 = @intCast(fi.bits_per_sample);
    const bytes_per_sample: usize = if (bps <= 8) 1 else 2;
    const stride: u32 = @as(u32, @intCast(fi.width)) *
        @as(u32, @intCast(channels)) * @as(u32, @intCast(bytes_per_sample));

    var dest_size: usize = 0;
    if (c.charls_jpegls_decoder_get_destination_size(decoder, stride, &dest_size) != 0)
        return error.BackendError;

    const pixels = try allocator.alloc(u8, dest_size);
    errdefer allocator.free(pixels);

    if (c.charls_jpegls_decoder_decode_to_buffer(decoder, pixels.ptr, dest_size, stride) != 0)
        return error.BackendError;

    return types.Image{
        .pixels = pixels,
        .width = @intCast(fi.width),
        .height = @intCast(fi.height),
        .channels = channels,
        .bits_per_sample = bps,
        .source_color_space = if (channels == 1) .grayscale else .rgb,
        .layout = if (channels == 1) .grayscale else .rgb,
    };
}
