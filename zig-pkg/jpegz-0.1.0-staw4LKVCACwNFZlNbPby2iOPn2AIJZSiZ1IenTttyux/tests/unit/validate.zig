//! M1.5 — `jpegz.validate` tests. Walks the bitstream, accumulates
//! Findings, returns a structured ValidationReport. Never fails-fast
//! on structural errors (per the design doc — validate-mode wants the
//! complete picture, not the first failure).

const std = @import("std");
const jpegz = @import("jpegz");

const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");
const fixture_progressive_8x8 = @embedFile("fixtures/progressive_8x8_rgb.jpg");
const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");

test "validate clean baseline JPEG → valid, baseline_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
    defer report.deinit(allocator);

    // .info is fine — cjpeg-emitted JFIF marker triggers an INFO finding.
    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.baseline_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 2), report.width);
    try std.testing.expectEqual(@as(?u32, 2), report.height);
    // No fail findings.
    for (report.findings.items) |f| {
        try std.testing.expect(f.severity != .fail);
    }
}

test "validate clean progressive JPEG → valid, progressive_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_progressive_8x8);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.progressive_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 8), report.width);
    try std.testing.expectEqual(@as(?u32, 8), report.height);
}

test "validate clean lossless JPEG → valid, lossless_huffman" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_lossless_4x4_gray8);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    try std.testing.expect(report.overall != .fail);
    try std.testing.expectEqual(jpegz.Variant.lossless_huffman, report.variant);
    try std.testing.expectEqual(@as(?u32, 4), report.width);
    try std.testing.expectEqual(@as(?u32, 4), report.height);
}

test "validate truncated JPEG → FAIL, truncated_stream finding" {
    const allocator = std.testing.allocator;

    // Slice off the trailing 30 bytes (drops EOI + tail of entropy data).
    const truncated = fixture_baseline_2x2_rgb[0 .. fixture_baseline_2x2_rgb.len - 30];

    var report = try jpegz.validate(allocator, truncated);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    // At least one finding must indicate truncation.
    var found_truncation = false;
    for (report.findings.items) |f| {
        if (f.code == .truncated_stream and f.severity == .fail) {
            found_truncation = true;
        }
    }
    try std.testing.expect(found_truncation);
}

test "validate empty input → FAIL, missing_soi finding" {
    const allocator = std.testing.allocator;
    const empty: []const u8 = &[_]u8{};

    var report = try jpegz.validate(allocator, empty);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    try std.testing.expectEqual(jpegz.Variant.unknown, report.variant);

    var found_missing_soi = false;
    for (report.findings.items) |f| {
        if (f.code == .missing_soi and f.severity == .fail) {
            found_missing_soi = true;
        }
    }
    try std.testing.expect(found_missing_soi);
}

/// 4×4 baseline RGB JPEG whose DHT (Huffman table definition) was
/// corrupted by setting all 16 code-length counts to 0xFF — an
/// impossible declaration that fails libjpeg's Huffman validation
/// with "Bogus Huffman table definition". The structural marker walker
/// passes (DHT length and bracket are intact); only codec-level
/// integrity catches it.
const fixture_baseline_4x4_bogus_dht = @embedFile("fixtures/baseline_4x4_bogus_dht.jpg");

test "validate corrupted DHT → FAIL with codec-level finding" {
    const allocator = std.testing.allocator;

    var report = try jpegz.validate(allocator, fixture_baseline_4x4_bogus_dht);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    // Marker walker still classifies the variant from the SOF marker.
    try std.testing.expectEqual(jpegz.Variant.baseline_huffman, report.variant);

    // At least one finding must be the codec-level Huffman fail.
    var found_codec_fail = false;
    for (report.findings.items) |f| {
        if (f.severity == .fail and f.code == .huffman_table_corrupt) {
            found_codec_fail = true;
        }
    }
    try std.testing.expect(found_codec_fail);
}

// ── M1.5c (per validate handoff 2026-05-06) — APPn presence + trailing data ──

const fixture_baseline_4x4_with_exif     = @embedFile("fixtures/baseline_4x4_with_exif.jpg");
const fixture_baseline_4x4_with_trailing = @embedFile("fixtures/baseline_4x4_with_trailing.jpg");

test "validate surfaces JFIF presence as INFO finding" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_2x2_rgb);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    var found = false;
    for (report.findings.items) |f| {
        if (f.code == .jfif_metadata_present and f.severity == .info) found = true;
    }
    try std.testing.expect(found);
}

test "validate surfaces EXIF presence (APP1 'Exif\\0\\0') as INFO" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_4x4_with_exif);
    defer report.deinit(allocator);

    try std.testing.expect(report.isValid());
    var found_jfif = false;
    var found_exif = false;
    for (report.findings.items) |f| {
        if (f.code == .jfif_metadata_present) found_jfif = true;
        if (f.code == .exif_metadata_present) found_exif = true;
    }
    try std.testing.expect(found_jfif);
    try std.testing.expect(found_exif);
}

test "validate surfaces trailing-data-after-EOI as INFO" {
    const allocator = std.testing.allocator;
    var report = try jpegz.validate(allocator, fixture_baseline_4x4_with_trailing);
    defer report.deinit(allocator);

    // Trailing data is INFO (the file is decodable; this is just a
    // notable observation), so overall stays at .info or .pass-derived.
    try std.testing.expect(report.isValid());
    var found = false;
    var offset_seen: ?u64 = null;
    for (report.findings.items) |f| {
        if (f.code == .trailing_data_after_eoi) {
            found = true;
            offset_seen = f.offset;
        }
    }
    try std.testing.expect(found);
    // Offset should point at the byte immediately after EOI.
    try std.testing.expect(offset_seen != null);
}

test "validate surfaces libjpeg-style insufficient_data tolerance as Finding(warn)" {
    // Architecture decision (NEXT_STEPS.md §"Validation-strictness"):
    // when the decoder tolerates a spec deviation that libjpeg-turbo
    // would WARNMS about, validate(...) must surface a Finding(.warn).
    //
    // Setup: take a clean baseline JPEG, truncate bytes from the END
    // of its entropy stream, then re-attach the FFD9 EOI marker.
    // libjpeg sees a structurally-complete file (jpeg_read_header
    // succeeds), but `jpeg_read_scanlines` hits the EOI marker before
    // every block is decoded → emits JWRN_HIT_MARKER. The validator
    // surface should map that into Finding(.warn, .insufficient_data).
    const allocator = std.testing.allocator;
    const full = fixture_baseline_2x2_rgb;
    // Sanity: existing fixture ends with the EOI marker.
    try std.testing.expectEqual(@as(u8, 0xFF), full[full.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), full[full.len - 1]);

    // Strip the last 24 bytes of entropy (well inside the scan), then
    // re-attach the 2-byte EOI so the structural walker is satisfied.
    const cut: usize = 24;
    var corrupted = try allocator.alloc(u8, full.len - cut);
    defer allocator.free(corrupted);
    @memcpy(corrupted[0 .. full.len - cut - 2], full[0 .. full.len - cut - 2]);
    corrupted[full.len - cut - 2] = 0xFF;
    corrupted[full.len - cut - 1] = 0xD9;

    var report = try jpegz.validate(allocator, corrupted);
    defer report.deinit(allocator);

    // Must surface at least one .warn finding tagged insufficient_data.
    var found_warn = false;
    for (report.findings.items) |f| {
        if (f.severity == .warn and f.code == .insufficient_data) {
            found_warn = true;
        }
    }
    try std.testing.expect(found_warn);
    // Overall must not regress to .fail — libjpeg recovers, so should we.
    try std.testing.expect(report.overall != .fail);
}

test "validate non-JPEG bytes → FAIL, missing_soi finding" {
    const allocator = std.testing.allocator;
    const garbage = "this is not a JPEG file at all";

    var report = try jpegz.validate(allocator, garbage);
    defer report.deinit(allocator);

    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    var found_missing_soi = false;
    for (report.findings.items) |f| {
        if (f.code == .missing_soi) found_missing_soi = true;
    }
    try std.testing.expect(found_missing_soi);
}
