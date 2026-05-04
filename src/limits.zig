//! Resource exhaustion / decompression-bomb defense.
//!
//! Adversarial TIFFs are a documented attack class: pixel flood
//! (declared dimensions × samples × bits = absurd buffer), strip/tile
//! flood, compression bomb (small compressed input claims huge
//! decompressed output), IFD chain loops, dimensional overflow.
//! Limits are defense-in-depth: the caller-supplied dest buffer is
//! the third bound, but limits stop the codec from even *trying* to
//! allocate scratch claiming a strip is 4 GB.

pub const Limits = struct {
    /// IFD chain bound (loop defense). DNGs/multi-page faxes use
    /// dozens to hundreds of IFDs; 1024 is generous.
    max_ifds: u32 = 1024,

    /// Per-IFD tag count. EXIF/DNG use hundreds; 4k is generous.
    max_tags_per_ifd: u32 = 4096,

    /// Bytes per tag value array. ICC profiles fit; pathological
    /// tag-count fields don't.
    max_tag_value_bytes: u64 = 64 << 20,

    /// Strips/tiles per IFD. 16M is well above any sane image.
    max_strips_or_tiles: u32 = 16 << 20,

    /// Width and height each. ~1B pixels per axis = gigapixel imagery.
    max_dim: u32 = 1 << 30,

    /// Width × height × samples. Overflow guard for u64 math.
    max_total_samples: u64 = 1 << 40,

    /// Codec scratch per single decodeStrip / decodeTile call.
    /// JPEG MCU buffers, LZW dictionary, CCITT context all fit.
    max_codec_scratch: u64 = 256 << 20,

    /// Single compressed-strip-on-disk size cap.
    max_compressed_strip_bytes: u64 = 1 << 30,

    /// Single decompressed-strip size cap (compression-bomb defense).
    max_decompressed_strip_bytes: u64 = 1 << 30,

    pub const default: Limits = .{};
};

test "Limits.default has sensible values" {
    const std = @import("std");
    const l = Limits.default;
    try std.testing.expect(l.max_ifds > 0);
    try std.testing.expect(l.max_dim > 0);
    try std.testing.expect(l.max_decompressed_strip_bytes > 0);
}
