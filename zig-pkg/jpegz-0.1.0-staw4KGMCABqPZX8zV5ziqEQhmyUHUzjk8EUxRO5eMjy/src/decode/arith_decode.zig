//! Arithmetic-coded JPEG decoder entry points (SOF9 / SOF10).
//!
//! SOF9 — extended sequential with arithmetic coding (T.81 §F.1.4).
//! SOF10 — progressive with arithmetic coding (T.81 §G.1) — Session 2.
//! SOF11 (lossless, arithmetic) is deferred — same A2 rationale:
//! `cjpeg -arithmetic -lossless` errors with "arithmetic coding is
//! not implemented", so the variant has no ground-truth encoder.
//!
//! This module is the SOF dispatcher + per-MCU orchestrator. Entropy
//! kernel (Q-coder + DC/AC binarization) lives in `arith_coder.zig`.
//! IDCT + assemble are reused from `baseline.zig` via newly-public
//! `transformBlockToPlane` and `assembleOutput` — the A3 refactor's
//! Phase-2 seam pays off here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const arith_coder = @import("arith_coder.zig");
const baseline = @import("baseline.zig");
const progressive = @import("progressive.zig");

const Error = errors.DecodeError;

// Force-import the Q-coder so its inline tests are discovered.
comptime {
    _ = arith_coder;
}

/// Public entry. Walks markers, classifies SOF9/SOF10/SOF11, dispatches.
/// Returns `error.NotImplemented` for variants we don't yet cleanroom
/// (currently SOF10 + SOF11) so the caller falls back to the wrapper.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    // Peek SOF: scan markers until we hit a SOFn byte to classify.
    var pos: usize = 2;
    while (pos + 1 < data.len) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        if (marker == 0x00) {
            pos += 1;
            continue;
        }
        switch (marker) {
            0xC9 => return decodeArithBaseline(allocator, data),
            0xCA => return decodeArithProgressive(allocator, data),
            0xCB => return error.NotImplemented, // SOF11 deferred (no encoder produces it).
            0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7 => return error.NotImplemented,
            else => {
                pos += 2;
                // Length-prefixed marker — skip its payload. Standalone
                // markers (RST, TEM, EOI) wouldn't appear before SOF in a
                // well-formed JPEG; treat any length read here as best-effort.
                if (marker >= 0xD0 and marker <= 0xD7) continue;
                if (marker == 0x01 or marker == 0xD8 or marker == 0xD9) continue;
                pos += baseline.parseSegmentLength(data, pos);
            },
        }
    }
    return error.TruncatedStream;
}

/// SOF9 sequential arithmetic baseline. Marker walk → SOS → MCU loop
/// (Q-coder entropy decode → dequant → IDCT) → assemble.
fn decodeArithBaseline(allocator: Allocator, data: []const u8) Error!types.Image {
    var pos: usize = 2;
    var frame: ?baseline.FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var restart_interval: u32 = 0;
    // DAC defaults — `arith_coder.ScanState.init` will reapply them
    // if no DAC segment is seen. We collect any DAC overrides here.
    var dac_dc_L: [4]u8 = .{ 0, 0, 0, 0 };
    var dac_dc_U: [4]u8 = .{ 1, 1, 1, 1 };
    var dac_ac_K: [4]u8 = .{ 5, 5, 5, 5 };

    // SOS-component table assignments (DC/AC table per component in
    // SOS order). Stored on the FrameInfo for the entropy loop to read.

    while (pos + 1 < data.len) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        if (marker == 0x00) {
            pos += 1;
            continue;
        }
        pos += 2;
        switch (marker) {
            0xD9 => return error.TruncatedStream,
            0xC9 => { // SOF9
                frame = try baseline.parseSof(data, pos);
                if (frame.?.precision != 8) return error.NotImplemented;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                pos += baseline.parseSegmentLength(data, pos);
            },
            0xC0...0xC3, 0xC5...0xC7, 0xCA, 0xCB => return error.NotImplemented,
            0xDB => { // DQT
                try baseline.parseDqt(data, pos, &quant_tables);
                pos += baseline.parseSegmentLength(data, pos);
            },
            0xCC => { // DAC — Define Arithmetic Conditioning (T.81 §B.2.4.3)
                try parseDac(data, pos, &dac_dc_L, &dac_dc_U, &dac_ac_K);
                pos += baseline.parseSegmentLength(data, pos);
            },
            0xDD => { // DRI
                const seg_len = baseline.parseSegmentLength(data, pos);
                if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => { // SOS
                if (frame == null) return error.InvalidMarker;
                try baseline.parseSos(data, pos, &frame.?);
                pos += baseline.parseSegmentLength(data, pos);
                return try decodeScanSof9(
                    allocator,
                    data[pos..],
                    &frame.?,
                    &quant_tables,
                    &dac_dc_L,
                    &dac_dc_U,
                    &dac_ac_K,
                    restart_interval,
                );
            },
            0x01, 0xD0...0xD7 => continue,
            else => pos += baseline.parseSegmentLength(data, pos),
        }
    }
    return error.TruncatedStream;
}

/// Parse a DAC segment (T.81 §B.2.4.3). Each conditioning entry: one
/// byte `Tc:Tb` (Tc = 0 DC / 1 AC, Tb = table index 0..3) followed by
/// one byte `Cs`. For DC: Cs is packed as `(U << 4) | L`. For AC: Cs
/// is Kx directly.
fn parseDac(
    data: []const u8,
    pos: usize,
    dc_L: *[4]u8,
    dc_U: *[4]u8,
    ac_K: *[4]u8,
) Error!void {
    const seg_len = baseline.parseSegmentLength(data, pos);
    if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
    var i: usize = 2;
    while (i + 1 < seg_len) : (i += 2) {
        const tc_tb = data[pos + i];
        const cs = data[pos + i + 1];
        const tc: u8 = tc_tb >> 4;
        const tb: u8 = tc_tb & 0x0F;
        if (tb >= 4) return error.InvalidMarker;
        if (tc == 0) {
            dc_L[tb] = cs & 0x0F;
            dc_U[tb] = cs >> 4;
        } else if (tc == 1) {
            ac_K[tb] = cs;
        } else return error.InvalidMarker;
    }
}

/// SOF9 entropy + Phase 2/3 assemble. Mirrors `baseline.decodeScan`'s
/// shape but with arithmetic entropy in place of Huffman.
fn decodeScanSof9(
    allocator: Allocator,
    data: []const u8,
    frame: *const baseline.FrameInfo,
    quant_tables: *const [4]?[64]u16,
    dac_dc_L: *const [4]u8,
    dac_dc_U: *const [4]u8,
    dac_ac_K: *const [4]u8,
    restart_interval: u32,
) Error!types.Image {
    const channels: u8 = frame.num_components;
    const width: u32 = frame.width;
    const height: u32 = frame.height;

    // MCU geometry: same rules as Huffman baseline (T.81 §A.2). For
    // non-interleaved scans (channels==1) the MCU is one block regardless
    // of declared sampling factors.
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    if (channels > 1) {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const c = &frame.components[i];
            if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
            if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
        }
    }
    const mcu_pixel_w: u32 = max_h * 8;
    const mcu_pixel_h: u32 = max_v * 8;
    const mcu_cols: u32 = (width + mcu_pixel_w - 1) / mcu_pixel_w;
    const mcu_rows: u32 = (height + mcu_pixel_h - 1) / mcu_pixel_h;

    var plane_w: [3]u32 = .{ 0, 0, 0 };
    var plane_h: [3]u32 = .{ 0, 0, 0 };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const eff_h: u32 = if (channels == 1) 1 else @as(u32, frame.components[i].h_factor);
            const eff_v: u32 = if (channels == 1) 1 else @as(u32, frame.components[i].v_factor);
            plane_w[i] = mcu_cols * eff_h * 8;
            plane_h[i] = mcu_rows * eff_v * 8;
            blocks_w[i] = mcu_cols * eff_h;
            blocks_h[i] = mcu_rows * eff_v;
        }
    }

    var planes: [3][]u8 = .{ &.{}, &.{}, &.{} };
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            planes[i] = try allocator.alloc(u8, plane_w[i] * plane_h[i]);
        }
    }
    errdefer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (planes[j].len > 0) allocator.free(planes[j]);
        }
    }

    var coef_buf: [3][]i32 = .{ &.{}, &.{}, &.{} };
    {
        var i: usize = 0;
        while (i < channels) : (i += 1) {
            const total_blocks: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]);
            coef_buf[i] = try allocator.alloc(i32, total_blocks * 64);
            @memset(coef_buf[i], 0);
        }
    }
    defer {
        var j: usize = 0;
        while (j < channels) : (j += 1) {
            if (coef_buf[j].len > 0) allocator.free(coef_buf[j]);
        }
    }

    // ── Phase 1: arithmetic entropy decode → coef_buf ─────────
    var state = arith_coder.ScanState.init(data);
    // Apply DAC conditioning (defaults already set inside ScanState.init).
    state.arith_dc_L = dac_dc_L.*;
    state.arith_dc_U = dac_dc_U.*;
    state.arith_ac_K = dac_ac_K.*;

    var mcus_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;
    var mcu_y: u32 = 0;
    while (mcu_y < mcu_rows) : (mcu_y += 1) {
        var mcu_x: u32 = 0;
        while (mcu_x < mcu_cols) : (mcu_x += 1) {
            // RST handling (T.81 §F.2.4.2). On RST boundary: reset stats
            // + DC predictors + Q-coder over remaining bytes; advance past
            // the marker byte (Q-coder already consumed the marker into
            // `marker_byte`, leaving pos *past* it).
            if (restart_interval > 0 and mcus_since_rst == restart_interval) {
                if (!state.qcoder.marker_seen) return error.InvalidMarker;
                if (state.qcoder.marker_byte != expected_rst) return error.InvalidMarker;
                const continue_at = state.qcoder.pos;
                state.resetForRestart(data[continue_at..]);
                mcus_since_rst = 0;
                expected_rst = 0xD0 + ((expected_rst - 0xD0 + 1) & 0x07);
            }

            var ci: usize = 0;
            while (ci < channels) : (ci += 1) {
                const comp = &frame.components[ci];
                const blocks_v_per_mcu: u32 = if (channels == 1) 1 else @intCast(comp.v_factor);
                const blocks_h_per_mcu: u32 = if (channels == 1) 1 else @intCast(comp.h_factor);
                var block_v: u32 = 0;
                while (block_v < blocks_v_per_mcu) : (block_v += 1) {
                    var block_h: u32 = 0;
                    while (block_h < blocks_h_per_mcu) : (block_h += 1) {
                        const block_idx_x: u32 = mcu_x * blocks_h_per_mcu + block_h;
                        const block_idx_y: u32 = mcu_y * blocks_v_per_mcu + block_v;
                        const linear: usize = (@as(usize, block_idx_y) * @as(usize, blocks_w[ci]) + @as(usize, block_idx_x)) * 64;
                        const out_slot: *[64]i32 = coef_buf[ci][linear..][0..64];
                        try decodeBlockSof9(&state, ci, comp, quant_tables, out_slot);
                    }
                }
            }
            mcus_since_rst += 1;
        }
    }

    // ── Phase 2: IDCT each block into its component plane ─────
    {
        var ci: usize = 0;
        while (ci < channels) : (ci += 1) {
            var by: u32 = 0;
            while (by < blocks_h[ci]) : (by += 1) {
                var bx: u32 = 0;
                while (bx < blocks_w[ci]) : (bx += 1) {
                    const linear: usize = (@as(usize, by) * @as(usize, blocks_w[ci]) + @as(usize, bx)) * 64;
                    const slot: *const [64]i32 = coef_buf[ci][linear..][0..64];
                    baseline.transformBlockToPlane(slot, planes[ci], plane_w[ci], bx * 8, by * 8);
                }
            }
        }
    }

    // ── Phase 3: chroma upsample + color convert via baseline ──
    return baseline.assembleOutput(allocator, frame, channels, width, height, max_h, max_v, plane_w, plane_h, &planes, null);
}

/// Decode one 8×8 block worth of arithmetic-coded coefficients —
/// DC + 63 ACs — and write them into `out` in natural (un-zig-zagged)
/// row-major order, dequantized. Mirrors `baseline.decodeBlockCoefficients`'s
/// post-condition so the Phase 2 IDCT consumes both shapes identically.
fn decodeBlockSof9(
    state: *arith_coder.ScanState,
    ci: usize,
    comp: *const baseline.ComponentInfo,
    quant_tables: *const [4]?[64]u16,
    out: *[64]i32,
) Error!void {
    const qt = quant_tables[comp.qt_index] orelse return error.InvalidMarker;
    // zz: zig-zag indexed coefficient buffer. AC decoder writes to zz[k]
    // (k = zig-zag index). DC goes at zz[0].
    var zz: [64]i32 = .{0} ** 64;
    const dc_i16: i16 = arith_coder.decodeDcSof9(state, ci, comp.dc_table) catch |e| switch (e) {
        error.BackendError, error.TruncatedStream, error.InvalidMarker => return error.BackendError,
    };
    zz[0] = dc_i16;
    arith_coder.decodeAcSof9(state, comp.ac_table, &zz) catch |e| switch (e) {
        error.BackendError, error.TruncatedStream, error.InvalidMarker => return error.BackendError,
    };
    // Dequantize in zig-zag space, un-zig-zag into natural order.
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        out[baseline.ZIGZAG[n]] = zz[n] * @as(i32, qt[n]);
    }
}

// ─────── SOF10 (progressive arithmetic) ─────────────────────────
//
// Mirrors progressive.zig's marker walk + per-scan dispatch, but
// (a) accepts SOF10 + DAC markers instead of SOF2 + DHT, and
// (b) invokes arith_coder's 4 scan-type handlers in place of the
// Huffman ones. Phase 2 (dequant + IDCT + chroma upsample + color
// convert) is reused verbatim via `progressive.assembleProgressiveGeneric`.

fn decodeArithProgressive(allocator: Allocator, data: []const u8) Error!types.Image {
    var pos: usize = 2;
    var frame: ?progressive.FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var restart_interval: u32 = 0;
    var dac_dc_L: [4]u8 = .{ 0, 0, 0, 0 };
    var dac_dc_U: [4]u8 = .{ 1, 1, 1, 1 };
    var dac_ac_K: [4]u8 = .{ 5, 5, 5, 5 };

    var coefs: [3][]i16 = .{ &.{}, &.{}, &.{} };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    var seen_sof = false;
    var saw_eoi = false;

    // ScanState persists DAC overrides across scans; the per-scan
    // resets happen inside each SOS branch via `state.startScan(...)`.
    var state: arith_coder.ScanState = arith_coder.ScanState.init(&.{});

    errdefer {
        var i: usize = 0;
        while (i < 3) : (i += 1) if (coefs[i].len > 0) allocator.free(coefs[i]);
    }

    while (pos + 1 < data.len and !saw_eoi) {
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;

        switch (marker) {
            0xD9 => { saw_eoi = true; break; },
            0xCA => { // SOF10
                frame = try progressive.parseSof(data, pos);
                if (frame.?.precision != 8) return error.NotImplemented;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                seen_sof = true;
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor < 1 or c.h_factor > 4 or c.v_factor < 1 or c.v_factor > 4)
                        return error.NotImplemented;
                    if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
                    if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
                }
                const mcu_pixel_w: u32 = max_h * 8;
                const mcu_pixel_h: u32 = max_v * 8;
                const mcu_cols: u32 = (frame.?.width + mcu_pixel_w - 1) / mcu_pixel_w;
                const mcu_rows: u32 = (frame.?.height + mcu_pixel_h - 1) / mcu_pixel_h;
                i = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    blocks_w[i] = mcu_cols * @as(u32, c.h_factor);
                    blocks_h[i] = mcu_rows * @as(u32, c.v_factor);
                    const total: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]) * 64;
                    coefs[i] = try allocator.alloc(i16, total);
                    @memset(coefs[i], 0);
                }
                pos += progressive.parseSegmentLength(data, pos);
            },
            0xC0...0xC3, 0xC5...0xC7, 0xC9, 0xCB => return error.NotImplemented,
            0xDB => { // DQT
                try progressive.parseDqt(data, pos, &quant_tables);
                pos += progressive.parseSegmentLength(data, pos);
            },
            0xCC => { // DAC
                try parseDac(data, pos, &dac_dc_L, &dac_dc_U, &dac_ac_K);
                pos += progressive.parseSegmentLength(data, pos);
            },
            0xDD => { // DRI
                const seg_len = progressive.parseSegmentLength(data, pos);
                if (seg_len < 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => { // SOS
                if (!seen_sof) return error.InvalidMarker;
                const scan = try progressive.parseSos(data, pos, &frame.?);
                pos += progressive.parseSegmentLength(data, pos);
                // DAC overrides apply scan-wide; copy them onto the
                // ScanState before the per-scan reset (init zeros all
                // stats but preserves the DAC fields we just wrote).
                state.arith_dc_L = dac_dc_L;
                state.arith_dc_U = dac_dc_U;
                state.arith_ac_K = dac_ac_K;
                // Per jdarith.c start_pass: DC tables zeroed on Ss==0 &&
                // Ah==0; AC tables zeroed on Ss > 0.
                const reset_dc = (scan.ss == 0 and scan.ah == 0);
                const reset_ac = (scan.ss != 0);
                state.startScan(data[pos..], reset_dc, reset_ac);
                pos = try decodeArithProgressiveScan(
                    data,
                    pos,
                    &state,
                    &frame.?,
                    &coefs,
                    &blocks_w,
                    &blocks_h,
                    max_h,
                    max_v,
                    &scan,
                    restart_interval,
                );
            },
            0x01, 0xD0...0xD7 => continue,
            else => pos += progressive.parseSegmentLength(data, pos),
        }
    }

    if (!seen_sof) return error.InvalidMarker;
    return switch (frame.?.precision) {
        8 => try progressive.assembleProgressiveGeneric(
            8, allocator, &frame.?, &quant_tables, &coefs, &blocks_w, &blocks_h, max_h, max_v,
        ),
        else => return error.NotImplemented, // 12-bit progressive arithmetic — corpus has none yet.
    };
}

/// Walk one scan's blocks and dispatch to the matching arith handler.
/// Mirrors `progressive.decodeOneScan`'s iteration shape (multi-comp
/// MCU vs single-comp x_i/y_i grid). On RST: re-init ScanState's
/// Q-coder + selectively zero stats, but DON'T re-zero DAC state.
fn decodeArithProgressiveScan(
    data: []const u8,
    entropy_start: usize,
    state: *arith_coder.ScanState,
    frame: *const progressive.FrameInfo,
    coefs: *[3][]i16,
    blocks_w: *const [3]u32,
    blocks_h: *const [3]u32,
    max_h: u32,
    max_v: u32,
    scan: *const progressive.ScanInfo,
    restart_interval: u32,
) Error!usize {
    var units_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;
    const reset_dc = (scan.ss == 0 and scan.ah == 0);
    const reset_ac = (scan.ss != 0);

    const handleArithRst = struct {
        fn run(
            s: *arith_coder.ScanState,
            buf: []const u8,
            expected: *u8,
            re_dc: bool,
            re_ac: bool,
        ) Error!void {
            if (!s.qcoder.marker_seen) return error.InvalidMarker;
            if (s.qcoder.marker_byte != expected.*) return error.InvalidMarker;
            const pos_after = s.qcoder.pos;
            // startScan re-inits Q-coder over remaining bytes with the
            // same scan-type reset policy used at scan start.
            s.startScan(buf[pos_after..], re_dc, re_ac);
            expected.* = 0xD0 + ((expected.* - 0xD0 + 1) & 0x07);
        }
    }.run;

    if (scan.num_components > 1) {
        const mcu_cols: u32 = blocks_w[0] / @as(u32, frame.components[0].h_factor);
        const mcu_rows: u32 = blocks_h[0] / @as(u32, frame.components[0].v_factor);
        var my: u32 = 0;
        while (my < mcu_rows) : (my += 1) {
            var mx: u32 = 0;
            while (mx < mcu_cols) : (mx += 1) {
                if (restart_interval > 0 and units_since_rst == restart_interval) {
                    try handleArithRst(state, data[entropy_start..], &expected_rst, reset_dc, reset_ac);
                    units_since_rst = 0;
                }
                var ci: usize = 0;
                while (ci < scan.num_components) : (ci += 1) {
                    const comp_idx = scan.comp_indices[ci];
                    const comp = &frame.components[comp_idx];
                    const bh: u32 = @intCast(comp.h_factor);
                    const bv: u32 = @intCast(comp.v_factor);
                    var bv_i: u32 = 0;
                    while (bv_i < bv) : (bv_i += 1) {
                        var bh_i: u32 = 0;
                        while (bh_i < bh) : (bh_i += 1) {
                            const bx: u32 = mx * bh + bh_i;
                            const by: u32 = my * bv + bv_i;
                            const off: usize = (@as(usize, by) *
                                @as(usize, blocks_w[comp_idx]) +
                                @as(usize, bx)) * 64;
                            const block = coefs[comp_idx][off .. off + 64];
                            try decodeArithProgressiveBlock(state, comp_idx, comp, block, scan);
                        }
                    }
                }
                units_since_rst += 1;
            }
        }
    } else {
        const comp_idx = scan.comp_indices[0];
        const comp = &frame.components[comp_idx];
        const W: u32 = frame.width;
        const H_full: u32 = frame.height;
        const xi: u32 = (W * @as(u32, comp.h_factor) + (8 * max_h) - 1) / (8 * max_h);
        const yi: u32 = (H_full * @as(u32, comp.v_factor) + (8 * max_v) - 1) / (8 * max_v);
        const stride: u32 = blocks_w[comp_idx];
        var by: u32 = 0;
        while (by < yi) : (by += 1) {
            var bx: u32 = 0;
            while (bx < xi) : (bx += 1) {
                if (restart_interval > 0 and units_since_rst == restart_interval) {
                    try handleArithRst(state, data[entropy_start..], &expected_rst, reset_dc, reset_ac);
                    units_since_rst = 0;
                }
                const off: usize = (@as(usize, by) * @as(usize, stride) +
                    @as(usize, bx)) * 64;
                const block = coefs[comp_idx][off .. off + 64];
                try decodeArithProgressiveBlock(state, comp_idx, comp, block, scan);
                units_since_rst += 1;
            }
        }
    }

    // After scan's blocks are decoded, the Q-coder may already have
    // consumed bytes past the marker boundary (it pre-fetches via
    // getByte). `qcoder.pos` points just past the last byte we
    // actually read OR just past a marker we observed. If a marker
    // was seen mid-scan and processed (RST), we'd have already
    // advanced past it; in either case, walk forward to the NEXT
    // marker boundary so the caller's outer marker loop re-enters
    // correctly.
    var p: usize = entropy_start + state.qcoder.pos;
    if (state.qcoder.marker_seen) {
        // Q-coder has already consumed the marker byte — rewind to
        // point at its 0xFF prefix so the outer walker sees it.
        // marker_byte was at pos-1 (after stuff-byte skip we might
        // have over-walked; simplest correct path is to scan back
        // for FF NN where NN == marker_byte).
        if (p >= 2 and data[p - 2] == 0xFF and data[p - 1] == state.qcoder.marker_byte) {
            p -= 2;
        }
        return p;
    }
    // No marker seen yet — search forward for the next 0xFF NN.
    while (p + 1 < data.len) : (p += 1) {
        if (data[p] == 0xFF and data[p + 1] != 0x00) break;
    }
    return p;
}

fn decodeArithProgressiveBlock(
    state: *arith_coder.ScanState,
    ci: usize,
    comp: *const progressive.ComponentInfo,
    block: []i16,
    scan: *const progressive.ScanInfo,
) Error!void {
    // NOTE: do NOT early-return on `marker_seen`. Unlike the Huffman
    // progressive path (which checks `br.markerHit()` because its
    // bit-reader exhausts on marker), the arithmetic Q-coder supplies
    // zero bits past a marker (T.81 §F.1.4 — "supply zero data until
    // decoding is complete"). libjpeg's per-scan loop calls
    // `arith_decode` for every block regardless of marker state, and
    // we must mirror that to keep the per-block decode count right.

    const sof9_to_decode = struct {
        fn map(e: arith_coder.ArithError) Error {
            return switch (e) {
                error.BackendError, error.TruncatedStream, error.InvalidMarker => error.BackendError,
            };
        }
    }.map;

    if (scan.ss == 0) {
        if (scan.ah == 0) {
            arith_coder.decodeDcFirstArith(
                state, ci, comp.dc_table, scan.al, block,
            ) catch |e| return sof9_to_decode(e);
        } else {
            arith_coder.decodeDcRefineArith(state, scan.al, block);
        }
    } else {
        if (scan.ah == 0) {
            arith_coder.decodeAcFirstArith(
                state, comp.ac_table, scan.ss, scan.se, scan.al, block,
            ) catch |e| return sof9_to_decode(e);
        } else {
            arith_coder.decodeAcRefineArith(
                state, comp.ac_table, scan.ss, scan.se, scan.al, block,
            ) catch |e| return sof9_to_decode(e);
        }
    }
}
