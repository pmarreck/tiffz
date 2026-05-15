//! Centralized fixture embeds for fuzz harnesses.
//!
//! Zig 0.16's `@embedFile` is package-scoped: it can only reach files
//! under the importing module's `root_source_file` directory. The
//! fuzz harnesses live at `tests/fuzz/`, which can't reach
//! `tests/unit/fixtures/` directly. This module lives next to
//! `fixtures/` and re-exports the seed set; the fuzz harnesses pull
//! it in via `@import("seed")` (wired in build.zig).

pub const baseline_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");
pub const baseline_gray = @embedFile("fixtures/baseline_4x4_grayscale.jpg");
pub const baseline_yuv420 = @embedFile("fixtures/baseline_8x8_yuv420.jpg");
pub const baseline_dri = @embedFile("fixtures/baseline_16x16_restart.jpg");
pub const baseline_cmyk = @embedFile("fixtures/baseline_4x4_cmyk.jpg");
pub const baseline_bogus_dht = @embedFile("fixtures/baseline_4x4_bogus_dht.jpg");
pub const baseline_trailing = @embedFile("fixtures/baseline_4x4_with_trailing.jpg");
pub const ext_sof1 = @embedFile("fixtures/extended_2x2_rgb_sof1.jpg");
pub const progressive_rgb = @embedFile("fixtures/progressive_8x8_rgb.jpg");
pub const progressive_gray = @embedFile("fixtures/progressive_8x8_gray.jpg");
pub const progressive_gray12 = @embedFile("fixtures/progressive_8x8_gray12.jpg");
pub const lossless_gray = @embedFile("fixtures/lossless_4x4_gray8.jpg");
pub const lossless_gradient = @embedFile("fixtures/lossless_4x4_gradient_pred1.jpg");
pub const lossless_rgb = @embedFile("fixtures/lossless_4x4_rgb_pred1.jpg");
pub const lossless_gray12 = @embedFile("fixtures/lossless_4x4_gray12.jpg");
pub const arith_baseline_gray = @embedFile("fixtures/arith_baseline_8x8_gray.jpg");
pub const arith_baseline_rgb = @embedFile("fixtures/arith_baseline_16x16_rgb_420.jpg");
pub const arith_progressive_gray = @embedFile("fixtures/arith_progressive_8x8_gray.jpg");
