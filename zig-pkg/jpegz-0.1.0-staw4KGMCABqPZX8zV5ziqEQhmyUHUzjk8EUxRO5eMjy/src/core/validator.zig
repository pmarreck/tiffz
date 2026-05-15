//! Hand-written JPEG marker-chain walker for `jpegz.validate`. Pure
//! Zig (no FFI). Designed to be the start of the Phase-2 cleanroom
//! parser: as the cleanroom decoder lands codec-by-codec, this module
//! will share its marker-parse machinery.
//!
//! Behavior contract (from the design doc):
//!   - Returns Zig error only on OOM; structural problems are findings.
//!   - Does NOT fail-fast — accumulates every finding it can detect
//!     before returning.
//!   - Sets `Variant` from SOF marker even when `overall == .fail` so
//!     consumers know what was being attempted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const types = @import("../jpegz.zig");

const Severity = errors.Severity;
const Variant = errors.Variant;
const FindingCode = errors.FindingCode;
const Finding = types.Finding;
const ValidationReport = types.ValidationReport;

/// Marker constants we care about (T.81 Table B.1 + JPEG-LS).
const Marker = struct {
    const SOI: u8 = 0xD8;
    const EOI: u8 = 0xD9;
    const SOS: u8 = 0xDA;
    const DHT: u8 = 0xC4;
    const DAC: u8 = 0xCC; // arithmetic conditioning
    // SOF markers — see classifyVariant.
    const RST0: u8 = 0xD0;
    const RST7: u8 = 0xD7;
    const TEM: u8 = 0x01;
};

/// Map a SOFn marker byte to the corresponding Variant.
/// Returns null for non-SOF markers.
fn classifyVariant(byte: u8) ?Variant {
    return switch (byte) {
        0xC0 => .baseline_huffman,        // SOF0
        0xC1 => .extended_huffman,        // SOF1
        0xC2 => .progressive_huffman,     // SOF2
        0xC3 => .lossless_huffman,        // SOF3
        0xC5, 0xC6, 0xC7 => .unknown,     // SOF5/6/7 — differential huffman, treat as unknown
        // SOF8 (0xC8) is JPG (reserved); skip.
        0xC9 => .baseline_arithmetic,     // SOF9
        0xCA => .progressive_arithmetic,  // SOF10
        0xCB => .lossless_arithmetic,     // SOF11
        0xCD, 0xCE, 0xCF => .unknown,     // SOF13/14/15 — differential arithmetic
        0xF7 => .jpegls,                  // SOF55 (T.87)
        else => null,
    };
}

/// True if a marker byte has NO length field (standalone). T.81 B.1.1.3.
fn isStandaloneMarker(byte: u8) bool {
    return byte == Marker.SOI
        or byte == Marker.EOI
        or byte == Marker.TEM
        or (byte >= Marker.RST0 and byte <= Marker.RST7);
}

/// Big-endian u16 read; assumes data has at least 2 bytes from `at`.
fn readU16BE(data: []const u8, at: usize) u16 {
    return (@as(u16, data[at]) << 8) | @as(u16, data[at + 1]);
}

/// Add a finding to the report, allocating the optional detail string
/// from the report's allocator. Detail lifetime is tied to the report.
fn addFinding(
    report: *ValidationReport,
    allocator: Allocator,
    severity: Severity,
    code: FindingCode,
    offset: ?u64,
    detail: ?[]const u8,
) Allocator.Error!void {
    const stored_detail: ?[]const u8 = if (detail) |d|
        try allocator.dupe(u8, d)
    else
        null;
    errdefer if (stored_detail) |s| allocator.free(s);

    try report.findings.append(allocator, .{
        .severity = severity,
        .code = code,
        .offset = offset,
        .detail = stored_detail,
    });

    // Promote `overall` if this finding is more severe.
    if (@intFromEnum(severity) > @intFromEnum(report.overall)) {
        report.overall = severity;
    }
}

pub fn validate(allocator: Allocator, data: []const u8) Allocator.Error!ValidationReport {
    var report = ValidationReport{
        .overall = .pass,
        .variant = .unknown,
        .width = null,
        .height = null,
        .findings = .empty,
    };
    errdefer report.deinit(allocator);

    // ── Step 1: SOI check ──────────────────────────────────────
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) {
        try addFinding(&report, allocator, .fail, .missing_soi, 0,
            "JPEG must start with SOI marker (0xFF 0xD8)");
        return report;
    }

    var pos: usize = 2;
    var seen_sof: bool = false;
    var sof_offset: ?u64 = null;
    var seen_sos: bool = false;
    var seen_eoi: bool = false;

    // ── Step 2: Walk markers ──────────────────────────────────
    while (pos < data.len) {
        // Each marker starts with one or more 0xFF fill bytes.
        if (data[pos] != 0xFF) {
            try addFinding(&report, allocator, .fail, .bad_marker_length, pos,
                "expected 0xFF at marker start");
            return report;
        }
        // Skip fill bytes (0xFF padding).
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) {
            try addFinding(&report, allocator, .fail, .truncated_stream, data.len,
                "stream ended at marker prefix");
            return report;
        }

        const marker_byte = data[pos];
        const marker_offset = pos - 1; // include the 0xFF
        pos += 1;

        // ── Standalone markers (no length) ─────────────────────
        if (isStandaloneMarker(marker_byte)) {
            if (marker_byte == Marker.EOI) {
                seen_eoi = true;
                // pos already moved past the 0xFF and marker byte;
                // anything beyond pos is "trailing" data.
                if (pos < data.len) {
                    try addFinding(&report, allocator, .info, .trailing_data_after_eoi,
                        pos, null);
                }
                break;
            }
            // SOI inside the stream (after position 0) is suspicious but
            // not required to fail — some embedded thumbnails carry one.
            // RST/TEM are no-op here.
            continue;
        }

        // ── Length-prefixed segment ────────────────────────────
        if (pos + 2 > data.len) {
            try addFinding(&report, allocator, .fail, .truncated_stream, pos,
                "stream ended before segment length");
            return report;
        }
        const seg_len = readU16BE(data, pos);
        if (seg_len < 2) {
            try addFinding(&report, allocator, .fail, .bad_marker_length, pos,
                "segment length must be >= 2");
            return report;
        }
        const seg_body_start = pos + 2;
        const seg_end = pos + seg_len; // length includes the 2 length bytes themselves
        if (seg_end > data.len) {
            try addFinding(&report, allocator, .fail, .truncated_stream, seg_end,
                "segment extends past end of stream");
            return report;
        }

        // ── APPn signature scan (M1.5c — validate handoff) ────
        // APPn markers (0xE0..0xEF) carry application-specific
        // payloads. The first few bytes of the body are a signature
        // that identifies the producer. Surface known producers as
        // INFO findings so validate / metadata pipelines don't have
        // to walk markers a second time. Body bounds are seg_body_start
        // to seg_end; the segment-length check above guarantees safety.
        if (marker_byte >= 0xE0 and marker_byte <= 0xEF) {
            if (classifyAppSignature(marker_byte, data[seg_body_start..seg_end])) |code| {
                try addFinding(&report, allocator, .info, code, marker_offset, null);
            }
        }

        // ── SOF: identify variant and record dimensions ───────
        if (classifyVariant(marker_byte)) |variant| {
            if (seen_sof) {
                try addFinding(&report, allocator, .warn, .duplicate_sof, marker_offset,
                    "more than one SOF marker (using first)");
            } else {
                report.variant = variant;
                sof_offset = marker_offset;
                seen_sof = true;

                // SOF body layout (T.81 §B.2.2):
                //   0: precision (u8)
                //   1-2: height (u16 BE)
                //   3-4: width (u16 BE)
                //   5: number of components (u8)
                //   6+: per-component data (3 bytes each)
                if (seg_len < 8) {
                    try addFinding(&report, allocator, .fail, .bad_marker_length,
                        seg_body_start, "SOF segment too short for header fields");
                } else {
                    const precision = data[seg_body_start];
                    const height = readU16BE(data, seg_body_start + 1);
                    const width = readU16BE(data, seg_body_start + 3);
                    report.width = @as(u32, width);
                    report.height = @as(u32, height);

                    if (precision != 8 and precision != 12 and precision != 16) {
                        try addFinding(&report, allocator, .fail, .invalid_sof_precision,
                            seg_body_start, "SOF precision must be 8, 12, or 16");
                    } else if (precision == 12) {
                        try addFinding(&report, allocator, .info, .twelve_bit_precision,
                            seg_body_start, null);
                    } else if (precision == 16 and (variant == .lossless_huffman or
                        variant == .lossless_arithmetic))
                    {
                        try addFinding(&report, allocator, .info, .sixteen_bit_lossless,
                            seg_body_start, null);
                    }

                    // Surface .info hint for arithmetic-coded variants.
                    switch (variant) {
                        .baseline_arithmetic, .progressive_arithmetic, .lossless_arithmetic =>
                            try addFinding(&report, allocator, .info,
                                .arithmetic_coding_used, marker_offset, null),
                        else => {},
                    }
                }
            }
        } else if (marker_byte == Marker.SOS) {
            seen_sos = true;
            // Entropy-coded data follows. Skip until we hit a non-RST,
            // non-padding marker (likely EOI, but could be another SOS
            // for progressive/multi-scan sequences).
            pos = seg_end;
            const new_pos = skipEntropyData(data, pos);
            // If skipEntropyData reaches end without finding any marker,
            // surface as truncation. We treat "ran off the end" as the
            // entropy stream not being terminated by EOI (or a follow-on
            // marker), which is `truncated_stream`.
            if (new_pos == null) {
                try addFinding(&report, allocator, .fail, .truncated_stream,
                    data.len, "SOS entropy data not terminated by a marker");
                return report;
            }
            pos = new_pos.?;
            continue;
        }

        pos = seg_end;
    }

    // ── Step 3: After-loop sanity ──────────────────────────────
    if (!seen_sof) {
        try addFinding(&report, allocator, .fail, .duplicate_sof, null,
            "no SOF marker found");
    }
    if (!seen_sos) {
        try addFinding(&report, allocator, .fail, .truncated_stream, null,
            "no SOS marker found before stream end");
    }
    if (!seen_eoi and report.overall != .fail) {
        try addFinding(&report, allocator, .warn, .missing_eoi, data.len,
            "stream lacks EOI marker (0xFF 0xD9)");
    }

    // ── Step 4: Codec-level integrity (M1.5b) ──────────────────
    // Run libjpeg-turbo's full decode through the file. The marker
    // walker catches structural problems (missing markers, bad
    // segment lengths, truncation) but is blind to coefficient-level
    // corruption — corrupt Huffman tables, bad DCT coefficients,
    // mismatched quantization tables. Decoding-through is the
    // ground truth.
    //
    // We skip when:
    //   - The walker already found a fail-rated structural problem
    //     (libjpeg would just rediscover it; saves cycles).
    //   - The variant isn't supported by libjpeg-turbo (jpegls,
    //     differential-lossless variants, JPEG 2000 — those are
    //     handled elsewhere or not yet routed).
    if (report.overall != .fail and shouldRunCodecCheck(report.variant)) {
        const wrapper = @import("../ffi/libjpeg_wrapper.zig");
        // Caller-owned bridge keeps message slices valid until we
        // finish copying them into Finding allocations.
        var bridge: wrapper.ValidationBridge = undefined;
        const codec_result = wrapper.validateCodecIntegrity(data, &bridge);

        // Every captured WARNMS becomes a Finding(.warn) — this is the
        // "validate-warns" surface. Architecture decision documented
        // in NEXT_STEPS.md §"Validation-strictness". The decoder still
        // returns pixels (libjpeg-style tolerance); validate just flags
        // the deviation so format-integrity consumers see it.
        for (codec_result.warnings) |warn| {
            const msg_len = std.mem.indexOfScalar(u8, &warn.message, 0) orelse warn.message.len;
            try addFinding(
                &report,
                allocator,
                .warn,
                wrapper.libjpegWarnToFindingCode(warn.msg_code),
                null,
                warn.message[0..msg_len],
            );
        }

        if (codec_result.failure) |failure| {
            try addFinding(&report, allocator, .fail, failure.code, null, failure.message);
        }
    }

    return report;
}

/// libjpeg-turbo handles SOF0/1/2/3/9/10/11. JPEG-LS, differential
/// variants, and JPEG 2000 don't reach this validator (JP2 has its
/// own path); skip the decode-through if the marker walker thinks the
/// variant is something else, otherwise libjpeg would just emit
/// "Unsupported JPEG process" and we'd add a redundant finding.
fn shouldRunCodecCheck(variant: Variant) bool {
    return switch (variant) {
        .baseline_huffman,
        .extended_huffman,
        .progressive_huffman,
        .lossless_huffman,
        .baseline_arithmetic,
        .progressive_arithmetic,
        .lossless_arithmetic,
        => true,
        .unknown, .jpegls, .jpeg2000 => false,
    };
}

/// Walk past entropy-coded scan data to the next marker. Inside an SOS,
/// any literal 0xFF in the entropy stream is escaped as 0xFF 0x00; a
/// real marker is 0xFF followed by a non-zero, non-RST byte. RST markers
/// (0xFF D0..D7) are intra-scan resets and DO continue the scan.
///
/// Map an APPn marker (0xE0..0xEF) + its segment body to a known
/// producer signature, returning the corresponding INFO `FindingCode`
/// or null if the signature is unrecognized.
///
/// Signatures are NUL-terminated identifiers at the start of the body
/// (T.81 doesn't standardize this; it's de-facto industry convention).
/// We match prefix bytes only — values inside the segment are not
/// parsed. validate's metadata pipeline handles deeper inspection.
fn classifyAppSignature(marker: u8, body: []const u8) ?FindingCode {
    return switch (marker) {
        // APP0 — JFIF / JFXX
        0xE0 => if (startsWith(body, "JFIF\x00") or startsWith(body, "JFXX\x00"))
            FindingCode.jfif_metadata_present
        else
            null,

        // APP1 — Exif or XMP (most common; Adobe also uses APP1)
        0xE1 => blk: {
            if (startsWith(body, "Exif\x00\x00")) break :blk FindingCode.exif_metadata_present;
            if (startsWith(body, "http://ns.adobe.com/xap/1.0/\x00"))
                break :blk FindingCode.xmp_metadata_present;
            break :blk null;
        },

        // APP2 — ICC profile
        0xE2 => if (startsWith(body, "ICC_PROFILE\x00"))
            FindingCode.icc_profile_present
        else
            null,

        // APP13 — Photoshop IRB
        0xED => if (startsWith(body, "Photoshop 3.0\x00"))
            FindingCode.photoshop_irb_present
        else
            null,

        else => null,
    };
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

/// Returns the byte offset of the 0xFF that begins the next "real"
/// marker (so the outer parser can re-enter its 0xFF-handling loop).
/// Returns null if the stream ends without a terminating marker.
fn skipEntropyData(data: []const u8, start: usize) ?usize {
    var i = start;
    while (i < data.len) {
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }
        // 0xFF: peek next byte (skipping fill 0xFFs).
        var j = i + 1;
        while (j < data.len and data[j] == 0xFF) j += 1;
        if (j >= data.len) return null;
        const next = data[j];
        if (next == 0x00) {
            // 0xFF 0x00 = stuffed literal, continues entropy data.
            i = j + 1;
            continue;
        }
        if (next >= Marker.RST0 and next <= Marker.RST7) {
            // Restart marker, scan continues.
            i = j + 1;
            continue;
        }
        // Real marker — return position of the 0xFF (so outer loop
        // re-enters at the marker prefix).
        return i;
    }
    return null;
}
