//! LOCO-I codec helpers for JPEG-LS (T.87 Annex A).
//!
//! Pure functions over a `ScanState` — no I/O, no allocation. The
//! integration loop lives in `jpegls.zig`; this file owns the
//! per-sample math:
//!
//!   - MED predictor (`predictMed`)
//!   - Gradient quantization + sign-canonicalized context index
//!     (`quantize`, `computeContextIndex`)
//!   - Golomb-Rice parameter selection + decode
//!     (`computeK`, `decodeGolombRice`, `mapMErrvalToErrval`)
//!   - Per-context state update (`updateState`, `updateBiasCorrection`)
//!
//! v1 scope: NEAR = 0 (lossless), 8 and 16-bit precision, 1- and
//! 3-component. NEAR > 0 paths are stubbed in the appropriate
//! functions and would be the natural follow-on for B2.2-v2.

const std = @import("std");
const bitstream = @import("jpegls_bitstream");

/// Number of regular-mode contexts (T.87 §A.3.5). 9 × 9 × 9 = 729
/// raw tuples, sign-canonicalized down to (729 - 1) / 2 + 1 = 365.
/// Indices 0..364. Plus two run-interruption contexts at 365/366.
pub const NUM_CONTEXTS: usize = 367;

/// Per-context state — T.87 §A.3.4. One row per context.
pub const ContextState = struct {
    /// Accumulated absolute prediction errors (Σ |Errval|).
    /// 32-bit headroom against 16-bit MAXVAL × RESET sums.
    A: u32 = 4,
    /// Signed running bias (Σ Errval). Capped via the decimation
    /// rule when N halves.
    B: i32 = 0,
    /// Bias correction (integer added to predicted value before
    /// the error is decoded). Clamped to [-128, 127] per §A.6.
    C: i8 = 0,
    /// Occurrence count. Starts at 1 so the initial `computeK`
    /// doesn't divide by zero.
    N: u32 = 1,
};

/// Frame-scope scan state. One instance per scan; reset on RST in
/// the rare cases JPEG-LS uses them.
pub const ScanState = struct {
    /// Per-component context tables. JPEG-LS replicates state per
    /// component for multi-component scans (T.87 §A.3.5).
    contexts: [4][NUM_CONTEXTS]ContextState,
    /// Run-mode J index per RItype slot (T.87 §A.7.1 Table A.16).
    /// 0..31. Caps at 31; advances on each run continuation.
    run_index: [4][2]u8,
    /// Frame parameters.
    MAXVAL: u32,
    NEAR: u32,
    T1: u32,
    T2: u32,
    T3: u32,
    RESET: u32,
    /// Bits per pixel (e.g. 8 or 16). Drives RANGE and LIMIT.
    bpp: u8,
    /// Quantized bpp: ceil(log2(RANGE / (2*NEAR + 1))) per T.87
    /// §A.2.1. For NEAR=0 this equals bpp.
    qbpp: u8,
    /// LIMIT for unary Golomb-Rice (T.87 §A.5.3, Eq. A.18):
    /// `2 * (bpp + max(8, bpp)) - qbpp - 1`. At bpp=8: 23.
    LIMIT: u8,

    /// Initialize all contexts to (A=max(2, (RANGE+32) >> 6), B=0,
    /// C=0, N=1) per T.87 §A.8. T1/T2/T3 default to spec values
    /// when MAXVAL/NEAR are at the standard 8-bit defaults; for
    /// other configurations they're recomputed per Eq. A.8.
    pub fn reset(self: *ScanState, bpp: u8, near: u32) void {
        const MAXVAL: u32 = (@as(u32, 1) << @intCast(bpp)) - 1;
        const RANGE: u32 = (MAXVAL + 2 * near) / (2 * near + 1) + 1;
        const initial_A: u32 = @max(2, (RANGE + 32) >> 6);
        const qbpp: u8 = @intCast(@max(2, std.math.log2_int_ceil(u32, RANGE)));
        self.MAXVAL = MAXVAL;
        self.NEAR = near;
        self.RESET = 64; // T.87 default
        self.bpp = bpp;
        self.qbpp = qbpp;
        self.LIMIT = computeLimit(bpp, qbpp);
        self.run_index = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
        // Per-context init — direct fill to keep Zig's type inference
        // simple (nested struct literals through 3 array dimensions
        // confuse it as of 0.16).
        var ci: usize = 0;
        while (ci < 4) : (ci += 1) {
            var q: usize = 0;
            while (q < NUM_CONTEXTS) : (q += 1) {
                self.contexts[ci][q] = .{ .A = initial_A, .B = 0, .C = 0, .N = 1 };
            }
        }
        self.setDefaultThresholds();
    }

    /// Compute default T1/T2/T3 per T.87 §C.2.4.1.1. The spec splits
    /// on MAXVAL ≥ 128 vs < 128; both branches reduce to T1=3, T2=7,
    /// T3=21 for the 8-bit NEAR=0 case (worked example).
    pub fn setDefaultThresholds(self: *ScanState) void {
        const near_i: i32 = @intCast(self.NEAR);
        const maxv_i: i32 = @intCast(self.MAXVAL);
        if (self.MAXVAL >= 128) {
            // FACTOR ∈ [1, 16] for MAXVAL ∈ [128, 4095].
            const factor: i32 = @intCast(((@min(self.MAXVAL, 4095)) + 128) >> 8);
            const t1_basic: i32 = factor * (3 - 2) + 2 + 3 * near_i;
            const t2_basic: i32 = factor * (7 - 2) + 2 + 5 * near_i;
            const t3_basic: i32 = factor * (21 - 2) + 2 + 7 * near_i;
            self.T1 = @intCast(clampI32(t1_basic, near_i + 1, maxv_i));
            self.T2 = @intCast(clampI32(t2_basic, @as(i32, @intCast(self.T1)), maxv_i));
            self.T3 = @intCast(clampI32(t3_basic, @as(i32, @intCast(self.T2)), maxv_i));
        } else {
            // MAXVAL < 128. Inverse FACTOR rescales the canonical
            // {3, 7, 21} downward for narrow-range images.
            const factor_in: i32 = @divFloor(256, maxv_i + 1);
            const t1_basic: i32 = @max(2, @divFloor(3, factor_in)) + 3 * near_i;
            const t2_basic: i32 = @max(3, @divFloor(7, factor_in)) + 5 * near_i;
            const t3_basic: i32 = @max(4, @divFloor(21, factor_in)) + 7 * near_i;
            self.T1 = @intCast(clampI32(t1_basic, near_i + 1, maxv_i));
            self.T2 = @intCast(clampI32(t2_basic, @as(i32, @intCast(self.T1)), maxv_i));
            self.T3 = @intCast(clampI32(t3_basic, @as(i32, @intCast(self.T2)), maxv_i));
        }
    }
};

inline fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

/// `LIMIT = 2 * (bpp + max(8, bpp)) - qbpp - 1` (T.87 Eq. A.18).
/// Caps the unary part of Golomb-Rice; above this we escape into a
/// full qbpp-bit value.
fn computeLimit(bpp: u8, qbpp: u8) u8 {
    const high: u32 = @as(u32, bpp) + @max(@as(u32, 8), @as(u32, bpp));
    const lim: u32 = 2 * high - @as(u32, qbpp) - 1;
    return @intCast(lim);
}

// ─────────────────────────────────────────────────────────────────
// Predictor (T.87 §A.4.1 — Median Edge Detection)
// ─────────────────────────────────────────────────────────────────

/// `Px = MED(Ra, Rb, Rc)`:
///   if Rc ≥ max(Ra, Rb) → min(Ra, Rb)  (likely vertical edge)
///   else if Rc ≤ min(Ra, Rb) → max(Ra, Rb)  (likely horizontal edge)
///   else → Ra + Rb - Rc  (smooth region; planar interpolation)
pub inline fn predictMed(ra: i32, rb: i32, rc: i32) i32 {
    const mn = @min(ra, rb);
    const mx = @max(ra, rb);
    if (rc >= mx) return mn;
    if (rc <= mn) return mx;
    return ra + rb - rc;
}

// ─────────────────────────────────────────────────────────────────
// Context quantization (T.87 §A.3.3 — Eq. A.10)
// ─────────────────────────────────────────────────────────────────

/// Quantize a signed gradient `d` into one of {-4..4} via thresholds
/// T1/T2/T3 and the near-lossless tolerance NEAR.
pub inline fn quantize(d: i32, t1: i32, t2: i32, t3: i32, near: i32) i32 {
    if (d <= -t3) return -4;
    if (d <= -t2) return -3;
    if (d <= -t1) return -2;
    if (d <  -near) return -1;
    if (d <=  near) return 0;
    if (d <   t1) return 1;
    if (d <   t2) return 2;
    if (d <   t3) return 3;
    return 4;
}

/// Result of context lookup: the canonical index and the sign that
/// must be applied to the prediction error to fold the negative
/// twin onto the same context.
pub const ContextLookup = struct {
    /// Canonical context index in [0, 364].
    q: usize,
    /// +1 or -1. Multiply the predicted/decoded error by `sign` to
    /// undo the canonicalization.
    sign: i8,
};

/// Map (Q1, Q2, Q3) → canonical context index 0..364, with sign
/// canonicalization (T.87 §A.3.6): if the first non-zero gradient
/// is negative, negate all three and flip the sign output.
pub inline fn computeContextIndex(q1: i32, q2: i32, q3: i32) ContextLookup {
    var s1 = q1;
    var s2 = q2;
    var s3 = q3;
    var sign: i8 = 1;
    // Sign canonicalization rule from T.87 §A.3.6: find the first
    // non-zero gradient; if it's negative, negate all three.
    if (s1 < 0 or (s1 == 0 and s2 < 0) or (s1 == 0 and s2 == 0 and s3 < 0)) {
        s1 = -s1;
        s2 = -s2;
        s3 = -s3;
        sign = -1;
    }
    // 9 values per gradient (-4..4 → offset by +4); pack as
    // base-9 digits. Range [0, 728]. The canonicalization above
    // halves this — every reachable index is in [0, 364] inclusive,
    // with 0 reserved for (0,0,0) which triggers run mode (not
    // regular). For regular mode the caller routes the (0,0,0)
    // case before invoking this.
    const idx: usize = @intCast((s1 + 4) * 81 + (s2 + 4) * 9 + (s3 + 4));
    return .{ .q = idx, .sign = sign };
}

// ─────────────────────────────────────────────────────────────────
// Golomb-Rice parameter selection + decode (T.87 §A.5)
// ─────────────────────────────────────────────────────────────────

/// Compute k: the smallest k ≥ 0 such that `N << k ≥ A`. Equivalent
/// to `ceil(log2(A / N))` when both are positive. T.87 Eq. A.16.
pub inline fn computeK(N: u32, A: u32) u5 {
    var k: u5 = 0;
    while ((@as(u64, N) << k) < @as(u64, A)) : (k += 1) {
        if (k >= 31) return 31; // safety; should never happen for valid streams
    }
    return k;
}

/// Decode one Golomb-Rice code from `br` with parameter `k`. T.87
/// §A.5.3: read a unary part `high`; if it's < LIMIT - qbpp - 1,
/// read `k` low bits and combine. Otherwise we hit the escape: read
/// `qbpp` bits directly and add 1.
pub inline fn decodeGolombRice(br: *bitstream.BitReader, k: u5, limit: u8, qbpp: u8) u32 {
    const high = br.readUnary(limit);
    if (high < @as(u32, limit) - @as(u32, qbpp) - 1) {
        const low: u32 = if (k > 0) br.readBits(@intCast(k)) else 0;
        return (high << k) | low;
    }
    // Escape: large value coded directly. T.87 Eq. A.20.
    const escape: u32 = br.readBits(@intCast(qbpp));
    return escape + 1;
}

/// Map the unsigned `MErrval` (received over the wire) back to the
/// signed `Errval`. T.87 Eq. A.13 / §A.5.2 inverse:
///   Even MErrval → +MErrval/2
///   Odd MErrval  → -(MErrval+1)/2
pub inline fn mapMErrvalToErrval(merrval: u32) i32 {
    const m: i32 = @intCast(merrval);
    if (m & 1 == 0) return @divFloor(m, 2);
    return -@divFloor(m + 1, 2);
}

// ─────────────────────────────────────────────────────────────────
// State update (T.87 §A.6)
// ─────────────────────────────────────────────────────────────────

/// Apply the post-sample state update at the given context.
///
/// Order matters:
///   1. Bias correction adjustment (`updateBiasCorrection`) reads
///      pre-update B[Q] and N[Q] before mutating C[Q].
///   2. Then A and N accumulate the new sample.
///   3. If N hits RESET, halve all three (decimation — T.87
///      §A.6.1 step "Reset").
pub inline fn updateState(state: *ScanState, ci: usize, q: usize, errval: i32) void {
    const ctx = &state.contexts[ci][q];
    // Step 1: bias-correction adjustment. Reads pre-update B/N.
    updateBiasCorrection(ctx, errval);
    // Step 2: accumulate.
    ctx.A +%= @intCast(@abs(errval));
    ctx.N +%= 1;
    // Step 3: decimation.
    if (ctx.N == state.RESET) {
        ctx.A >>= 1;
        ctx.B = @divFloor(ctx.B - 1, 2);
        ctx.N >>= 1;
    }
}

/// T.87 §A.6.1 bias correction. The algorithm shifts C up/down by
/// 1 based on whether B trends positive (toward over-prediction)
/// or negative (under-prediction), clamped to [-128, 127].
pub inline fn updateBiasCorrection(ctx: *ContextState, errval: i32) void {
    ctx.B +%= errval;
    const n_i: i32 = @intCast(ctx.N);
    if (ctx.B <= -n_i) {
        if (ctx.C > -128) ctx.C -= 1;
        ctx.B +%= n_i;
        if (ctx.B <= -n_i) ctx.B = -n_i + 1;
    } else if (ctx.B > 0) {
        if (ctx.C < 127) ctx.C += 1;
        ctx.B -%= n_i;
        if (ctx.B > 0) ctx.B = 0;
    }
}

// ── Inline tests ─────────────────────────────────────────────────

test "predictMed: vertical edge (Rc >= max → min)" {
    try std.testing.expectEqual(@as(i32, 5), predictMed(5, 10, 10));
    try std.testing.expectEqual(@as(i32, 5), predictMed(5, 10, 20));
}

test "predictMed: horizontal edge (Rc <= min → max)" {
    try std.testing.expectEqual(@as(i32, 10), predictMed(5, 10, 5));
    try std.testing.expectEqual(@as(i32, 10), predictMed(5, 10, 0));
}

test "predictMed: smooth region → Ra + Rb - Rc" {
    // Ra=10, Rb=20, Rc=15 → min=10, max=20. Rc=15 strictly between
    // → 10 + 20 - 15 = 15.
    try std.testing.expectEqual(@as(i32, 15), predictMed(10, 20, 15));
}

test "quantize: standard 8-bit thresholds {3,7,21}" {
    // T1=3, T2=7, T3=21, NEAR=0.
    try std.testing.expectEqual(@as(i32, 0), quantize(0, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 1), quantize(1, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 1), quantize(2, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 2), quantize(3, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 2), quantize(6, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 3), quantize(7, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 3), quantize(20, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, 4), quantize(21, 3, 7, 21, 0));
    // Negative side.
    try std.testing.expectEqual(@as(i32, -1), quantize(-1, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, -2), quantize(-3, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, -3), quantize(-7, 3, 7, 21, 0));
    try std.testing.expectEqual(@as(i32, -4), quantize(-21, 3, 7, 21, 0));
}

test "computeContextIndex: canonical positive-leading tuple" {
    // (1, 0, 0) — positive Q1, sign stays +1.
    const r = computeContextIndex(1, 0, 0);
    try std.testing.expectEqual(@as(i8, 1), r.sign);
    // Index = (1+4)*81 + (0+4)*9 + (0+4) = 405 + 36 + 4 = 445.
    try std.testing.expectEqual(@as(usize, 445), r.q);
}

test "computeContextIndex: sign-canonicalize negative-leading tuple" {
    // (-1, 0, 0) → flip to (1, 0, 0), sign = -1.
    const r = computeContextIndex(-1, 0, 0);
    try std.testing.expectEqual(@as(i8, -1), r.sign);
    try std.testing.expectEqual(@as(usize, 445), r.q);
}

test "computeContextIndex: sign-canonicalize when leading zero" {
    // (0, -2, 1) → first non-zero is q2 = -2 (negative), flip → (0, 2, -1), sign = -1.
    const r = computeContextIndex(0, -2, 1);
    try std.testing.expectEqual(@as(i8, -1), r.sign);
    // Index = (0+4)*81 + (2+4)*9 + (-1+4) = 324 + 54 + 3 = 381.
    try std.testing.expectEqual(@as(usize, 381), r.q);
}

test "computeK: simple cases" {
    // N=1, A=1 → 1 << 0 = 1 >= 1 → k=0.
    try std.testing.expectEqual(@as(u5, 0), computeK(1, 1));
    // N=1, A=2 → k=1 (1<<1=2>=2).
    try std.testing.expectEqual(@as(u5, 1), computeK(1, 2));
    // N=1, A=8 → k=3.
    try std.testing.expectEqual(@as(u5, 3), computeK(1, 8));
    // N=4, A=16 → k=2 (4<<2=16>=16).
    try std.testing.expectEqual(@as(u5, 2), computeK(4, 16));
}

test "mapMErrvalToErrval: round-trip via known mapping" {
    // T.87 Eq. A.13:
    //   MErrval = 2*Errval      if Errval >= 0
    //   MErrval = -2*Errval - 1 if Errval < 0
    // Inverse: even → +n/2, odd → -(n+1)/2.
    try std.testing.expectEqual(@as(i32,  0), mapMErrvalToErrval(0));
    try std.testing.expectEqual(@as(i32, -1), mapMErrvalToErrval(1));
    try std.testing.expectEqual(@as(i32,  1), mapMErrvalToErrval(2));
    try std.testing.expectEqual(@as(i32, -2), mapMErrvalToErrval(3));
    try std.testing.expectEqual(@as(i32,  2), mapMErrvalToErrval(4));
}

test "decodeGolombRice: k=0 simple unary code" {
    // k=0: each Errval is a unary count. Stream 0b110_00000 →
    // unary = 2 (two 1s + a 0), no low bits since k=0 → result 2.
    const data = [_]u8{0b1100_0000};
    var br = bitstream.BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 2), decodeGolombRice(&br, 0, 16, 8));
}

test "decodeGolombRice: k=2 mixed unary+binary" {
    // k=2: unary high then 2 low bits. Stream 0b10_11_xxxx → high=1
    // (one 1-bit then 0), low = 0b11 = 3, total = (1 << 2) | 3 = 7.
    const data = [_]u8{0b1011_0000};
    var br = bitstream.BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 7), decodeGolombRice(&br, 2, 16, 8));
}

test "ScanState.reset: 8-bit lossless defaults" {
    var s: ScanState = undefined;
    s.reset(8, 0);
    try std.testing.expectEqual(@as(u32, 255), s.MAXVAL);
    try std.testing.expectEqual(@as(u32, 0), s.NEAR);
    try std.testing.expectEqual(@as(u32, 3), s.T1);
    try std.testing.expectEqual(@as(u32, 7), s.T2);
    try std.testing.expectEqual(@as(u32, 21), s.T3);
    try std.testing.expectEqual(@as(u32, 64), s.RESET);
    try std.testing.expectEqual(@as(u8, 8), s.qbpp);
    // A.18: LIMIT = 2*(8+8) - 8 - 1 = 23.
    try std.testing.expectEqual(@as(u8, 23), s.LIMIT);
    // Initial context: A=max(2, (RANGE+32)>>6) = max(2, (256+32)>>6) = max(2, 4) = 4.
    try std.testing.expectEqual(@as(u32, 4), s.contexts[0][0].A);
    try std.testing.expectEqual(@as(u32, 1), s.contexts[0][0].N);
}

test "updateBiasCorrection: positive bias decrements toward zero" {
    var ctx = ContextState{ .A = 4, .B = 0, .C = 0, .N = 1 };
    // Errval = +1, N = 1 → B becomes +1 > 0 → C += 1, B -= N = 0.
    updateBiasCorrection(&ctx, 1);
    try std.testing.expectEqual(@as(i8, 1), ctx.C);
    try std.testing.expectEqual(@as(i32, 0), ctx.B);
}

test "updateBiasCorrection: large negative bias decrements C" {
    var ctx = ContextState{ .A = 4, .B = 0, .C = 0, .N = 4 };
    // Errval = -5, N = 4 → B becomes -5 ≤ -N → C -= 1, B += N = -1.
    updateBiasCorrection(&ctx, -5);
    try std.testing.expectEqual(@as(i8, -1), ctx.C);
    try std.testing.expectEqual(@as(i32, -1), ctx.B);
}
