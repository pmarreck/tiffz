//! Q-coder — binary arithmetic decoder for JPEG (T.81 Annex D / §F.1.4).
//!
//! Two layers in this module:
//!
//!   1. `QCoder` — pure binary arithmetic decoder. Operates on a
//!      single-byte "context" cell holding {state_index, MPS}. Reads
//!      raw bytes from a JPEG entropy stream with 0xFF marker-escape
//!      handling. **Codec-agnostic enough that the same state machine
//!      could host a JPEG 2000 MQ-coder adapter later** (B3); only
//!      the renormalization details and statistics-table semantics
//!      differ between the two.
//!
//!   2. JPEG-specific binarization (T.81 §F.1.4.4.1) — DC differential
//!      and AC coefficient decoders. Land in a follow-on commit
//!      (GREEN1b); this commit ships just the Q-coder kernel + table.
//!
//! Reference: T.81 §D.2 (decoder pseudocode), Table D.2 (state
//! transition table), libjpeg-turbo's `jdarith.c` + `jaricom.c`. The
//! `qe_table` below is **ported byte-for-byte** from libjpeg's
//! `jpeg_aritab` — the table IS the JPEG committee's deterministic
//! spec; matching libjpeg exactly is the testable byte-equality
//! ground truth.

const std = @import("std");

/// Errors a Q-coder consumer can surface upstream.
pub const Error = error{
    TruncatedStream,
    InvalidMarker,
};

/// One entry in T.81 Table D.2. libjpeg packs these four fields into
/// a single JLONG via the V() macro; Zig comptime gives us a clean
/// struct layout at zero cost.
pub const QeEntry = struct {
    /// LPS subinterval probability estimate Qe (T.81 §D.2). 16-bit
    /// value in the range that keeps `A - Qe` representable in u16.
    qe: u16,
    /// Next state index after coding an LPS.
    next_lps: u7,
    /// Next state index after coding an MPS.
    next_mps: u7,
    /// If true, swap MPS↔LPS at this state when an LPS is coded.
    switch_mps: bool,
};

/// Probability estimation state machine — T.81 Table D.2, identical
/// to libjpeg's `jaricom.c` `jpeg_aritab[113+1]`. Indices 0..112 are
/// the 113 states from the spec. Index 113 is libjpeg's extra
/// "fixed probability ~0.5" entry per T.851 §10.3 Table 5; we keep it
/// for parity even though JPEG never references it directly.
pub const QE_TABLE = [114]QeEntry{
    .{ .qe = 0x5a1d, .next_lps = 1,   .next_mps = 1,   .switch_mps = true  },
    .{ .qe = 0x2586, .next_lps = 14,  .next_mps = 2,   .switch_mps = false },
    .{ .qe = 0x1114, .next_lps = 16,  .next_mps = 3,   .switch_mps = false },
    .{ .qe = 0x080b, .next_lps = 18,  .next_mps = 4,   .switch_mps = false },
    .{ .qe = 0x03d8, .next_lps = 20,  .next_mps = 5,   .switch_mps = false },
    .{ .qe = 0x01da, .next_lps = 23,  .next_mps = 6,   .switch_mps = false },
    .{ .qe = 0x00e5, .next_lps = 25,  .next_mps = 7,   .switch_mps = false },
    .{ .qe = 0x006f, .next_lps = 28,  .next_mps = 8,   .switch_mps = false },
    .{ .qe = 0x0036, .next_lps = 30,  .next_mps = 9,   .switch_mps = false },
    .{ .qe = 0x001a, .next_lps = 33,  .next_mps = 10,  .switch_mps = false },
    .{ .qe = 0x000d, .next_lps = 35,  .next_mps = 11,  .switch_mps = false },
    .{ .qe = 0x0006, .next_lps = 9,   .next_mps = 12,  .switch_mps = false },
    .{ .qe = 0x0003, .next_lps = 10,  .next_mps = 13,  .switch_mps = false },
    .{ .qe = 0x0001, .next_lps = 12,  .next_mps = 13,  .switch_mps = false },
    .{ .qe = 0x5a7f, .next_lps = 15,  .next_mps = 15,  .switch_mps = true  },
    .{ .qe = 0x3f25, .next_lps = 36,  .next_mps = 16,  .switch_mps = false },
    .{ .qe = 0x2cf2, .next_lps = 38,  .next_mps = 17,  .switch_mps = false },
    .{ .qe = 0x207c, .next_lps = 39,  .next_mps = 18,  .switch_mps = false },
    .{ .qe = 0x17b9, .next_lps = 40,  .next_mps = 19,  .switch_mps = false },
    .{ .qe = 0x1182, .next_lps = 42,  .next_mps = 20,  .switch_mps = false },
    .{ .qe = 0x0cef, .next_lps = 43,  .next_mps = 21,  .switch_mps = false },
    .{ .qe = 0x09a1, .next_lps = 45,  .next_mps = 22,  .switch_mps = false },
    .{ .qe = 0x072f, .next_lps = 46,  .next_mps = 23,  .switch_mps = false },
    .{ .qe = 0x055c, .next_lps = 48,  .next_mps = 24,  .switch_mps = false },
    .{ .qe = 0x0406, .next_lps = 49,  .next_mps = 25,  .switch_mps = false },
    .{ .qe = 0x0303, .next_lps = 51,  .next_mps = 26,  .switch_mps = false },
    .{ .qe = 0x0240, .next_lps = 52,  .next_mps = 27,  .switch_mps = false },
    .{ .qe = 0x01b1, .next_lps = 54,  .next_mps = 28,  .switch_mps = false },
    .{ .qe = 0x0144, .next_lps = 56,  .next_mps = 29,  .switch_mps = false },
    .{ .qe = 0x00f5, .next_lps = 57,  .next_mps = 30,  .switch_mps = false },
    .{ .qe = 0x00b7, .next_lps = 59,  .next_mps = 31,  .switch_mps = false },
    .{ .qe = 0x008a, .next_lps = 60,  .next_mps = 32,  .switch_mps = false },
    .{ .qe = 0x0068, .next_lps = 62,  .next_mps = 33,  .switch_mps = false },
    .{ .qe = 0x004e, .next_lps = 63,  .next_mps = 34,  .switch_mps = false },
    .{ .qe = 0x003b, .next_lps = 32,  .next_mps = 35,  .switch_mps = false },
    .{ .qe = 0x002c, .next_lps = 33,  .next_mps = 9,   .switch_mps = false },
    .{ .qe = 0x5ae1, .next_lps = 37,  .next_mps = 37,  .switch_mps = true  },
    .{ .qe = 0x484c, .next_lps = 64,  .next_mps = 38,  .switch_mps = false },
    .{ .qe = 0x3a0d, .next_lps = 65,  .next_mps = 39,  .switch_mps = false },
    .{ .qe = 0x2ef1, .next_lps = 67,  .next_mps = 40,  .switch_mps = false },
    .{ .qe = 0x261f, .next_lps = 68,  .next_mps = 41,  .switch_mps = false },
    .{ .qe = 0x1f33, .next_lps = 69,  .next_mps = 42,  .switch_mps = false },
    .{ .qe = 0x19a8, .next_lps = 70,  .next_mps = 43,  .switch_mps = false },
    .{ .qe = 0x1518, .next_lps = 72,  .next_mps = 44,  .switch_mps = false },
    .{ .qe = 0x1177, .next_lps = 73,  .next_mps = 45,  .switch_mps = false },
    .{ .qe = 0x0e74, .next_lps = 74,  .next_mps = 46,  .switch_mps = false },
    .{ .qe = 0x0bfb, .next_lps = 75,  .next_mps = 47,  .switch_mps = false },
    .{ .qe = 0x09f8, .next_lps = 77,  .next_mps = 48,  .switch_mps = false },
    .{ .qe = 0x0861, .next_lps = 78,  .next_mps = 49,  .switch_mps = false },
    .{ .qe = 0x0706, .next_lps = 79,  .next_mps = 50,  .switch_mps = false },
    .{ .qe = 0x05cd, .next_lps = 48,  .next_mps = 51,  .switch_mps = false },
    .{ .qe = 0x04de, .next_lps = 50,  .next_mps = 52,  .switch_mps = false },
    .{ .qe = 0x040f, .next_lps = 50,  .next_mps = 53,  .switch_mps = false },
    .{ .qe = 0x0363, .next_lps = 51,  .next_mps = 54,  .switch_mps = false },
    .{ .qe = 0x02d4, .next_lps = 52,  .next_mps = 55,  .switch_mps = false },
    .{ .qe = 0x025c, .next_lps = 53,  .next_mps = 56,  .switch_mps = false },
    .{ .qe = 0x01f8, .next_lps = 54,  .next_mps = 57,  .switch_mps = false },
    .{ .qe = 0x01a4, .next_lps = 55,  .next_mps = 58,  .switch_mps = false },
    .{ .qe = 0x0160, .next_lps = 56,  .next_mps = 59,  .switch_mps = false },
    .{ .qe = 0x0125, .next_lps = 57,  .next_mps = 60,  .switch_mps = false },
    .{ .qe = 0x00f6, .next_lps = 58,  .next_mps = 61,  .switch_mps = false },
    .{ .qe = 0x00cb, .next_lps = 59,  .next_mps = 62,  .switch_mps = false },
    .{ .qe = 0x00ab, .next_lps = 61,  .next_mps = 63,  .switch_mps = false },
    .{ .qe = 0x008f, .next_lps = 61,  .next_mps = 32,  .switch_mps = false },
    .{ .qe = 0x5b12, .next_lps = 65,  .next_mps = 65,  .switch_mps = true  },
    .{ .qe = 0x4d04, .next_lps = 80,  .next_mps = 66,  .switch_mps = false },
    .{ .qe = 0x412c, .next_lps = 81,  .next_mps = 67,  .switch_mps = false },
    .{ .qe = 0x37d8, .next_lps = 82,  .next_mps = 68,  .switch_mps = false },
    .{ .qe = 0x2fe8, .next_lps = 83,  .next_mps = 69,  .switch_mps = false },
    .{ .qe = 0x293c, .next_lps = 84,  .next_mps = 70,  .switch_mps = false },
    .{ .qe = 0x2379, .next_lps = 86,  .next_mps = 71,  .switch_mps = false },
    .{ .qe = 0x1edf, .next_lps = 87,  .next_mps = 72,  .switch_mps = false },
    .{ .qe = 0x1aa9, .next_lps = 87,  .next_mps = 73,  .switch_mps = false },
    .{ .qe = 0x174e, .next_lps = 72,  .next_mps = 74,  .switch_mps = false },
    .{ .qe = 0x1424, .next_lps = 72,  .next_mps = 75,  .switch_mps = false },
    .{ .qe = 0x119c, .next_lps = 74,  .next_mps = 76,  .switch_mps = false },
    .{ .qe = 0x0f6b, .next_lps = 74,  .next_mps = 77,  .switch_mps = false },
    .{ .qe = 0x0d51, .next_lps = 75,  .next_mps = 78,  .switch_mps = false },
    .{ .qe = 0x0bb6, .next_lps = 77,  .next_mps = 79,  .switch_mps = false },
    .{ .qe = 0x0a40, .next_lps = 77,  .next_mps = 48,  .switch_mps = false },
    .{ .qe = 0x5832, .next_lps = 80,  .next_mps = 81,  .switch_mps = true  },
    .{ .qe = 0x4d1c, .next_lps = 88,  .next_mps = 82,  .switch_mps = false },
    .{ .qe = 0x438e, .next_lps = 89,  .next_mps = 83,  .switch_mps = false },
    .{ .qe = 0x3bdd, .next_lps = 90,  .next_mps = 84,  .switch_mps = false },
    .{ .qe = 0x34ee, .next_lps = 91,  .next_mps = 85,  .switch_mps = false },
    .{ .qe = 0x2eae, .next_lps = 92,  .next_mps = 86,  .switch_mps = false },
    .{ .qe = 0x299a, .next_lps = 93,  .next_mps = 87,  .switch_mps = false },
    .{ .qe = 0x2516, .next_lps = 86,  .next_mps = 71,  .switch_mps = false },
    .{ .qe = 0x5570, .next_lps = 88,  .next_mps = 89,  .switch_mps = true  },
    .{ .qe = 0x4ca9, .next_lps = 95,  .next_mps = 90,  .switch_mps = false },
    .{ .qe = 0x44d9, .next_lps = 96,  .next_mps = 91,  .switch_mps = false },
    .{ .qe = 0x3e22, .next_lps = 97,  .next_mps = 92,  .switch_mps = false },
    .{ .qe = 0x3824, .next_lps = 99,  .next_mps = 93,  .switch_mps = false },
    .{ .qe = 0x32b4, .next_lps = 99,  .next_mps = 94,  .switch_mps = false },
    .{ .qe = 0x2e17, .next_lps = 93,  .next_mps = 86,  .switch_mps = false },
    .{ .qe = 0x56a8, .next_lps = 95,  .next_mps = 96,  .switch_mps = true  },
    .{ .qe = 0x4f46, .next_lps = 101, .next_mps = 97,  .switch_mps = false },
    .{ .qe = 0x47e5, .next_lps = 102, .next_mps = 98,  .switch_mps = false },
    .{ .qe = 0x41cf, .next_lps = 103, .next_mps = 99,  .switch_mps = false },
    .{ .qe = 0x3c3d, .next_lps = 104, .next_mps = 100, .switch_mps = false },
    .{ .qe = 0x375e, .next_lps = 99,  .next_mps = 93,  .switch_mps = false },
    .{ .qe = 0x5231, .next_lps = 105, .next_mps = 102, .switch_mps = false },
    .{ .qe = 0x4c0f, .next_lps = 106, .next_mps = 103, .switch_mps = false },
    .{ .qe = 0x4639, .next_lps = 107, .next_mps = 104, .switch_mps = false },
    .{ .qe = 0x415e, .next_lps = 103, .next_mps = 99,  .switch_mps = false },
    .{ .qe = 0x5627, .next_lps = 105, .next_mps = 106, .switch_mps = true  },
    .{ .qe = 0x50e7, .next_lps = 108, .next_mps = 107, .switch_mps = false },
    .{ .qe = 0x4b85, .next_lps = 109, .next_mps = 103, .switch_mps = false },
    .{ .qe = 0x5597, .next_lps = 110, .next_mps = 109, .switch_mps = false },
    .{ .qe = 0x504f, .next_lps = 111, .next_mps = 107, .switch_mps = false },
    .{ .qe = 0x5a10, .next_lps = 110, .next_mps = 111, .switch_mps = true  },
    .{ .qe = 0x5522, .next_lps = 112, .next_mps = 109, .switch_mps = false },
    .{ .qe = 0x59eb, .next_lps = 112, .next_mps = 111, .switch_mps = true  },
    // Index 113 — fixed-probability ~0.5 (T.851 §10.3 Table 5).
    // libjpeg keeps it; we mirror for parity. JPEG itself never
    // references this slot.
    .{ .qe = 0x5a1d, .next_lps = 113 & 0x7F, .next_mps = 113 & 0x7F, .switch_mps = false },
};

/// Single-byte context cell — bit 7 holds the current MPS value,
/// bits 6..0 are the index into `QE_TABLE`. Same layout as libjpeg's
/// `unsigned char *st` pattern; storing as `u8` lets us use the same
/// XOR tricks (`sv ^= 0x80` to swap MPS) at zero cost.
pub const Context = u8;

/// Initial context: state 0, MPS = 0. JPEG arithmetic spec requires
/// every context to be initialized this way at scan start AND at
/// every RST marker.
pub const INITIAL_CONTEXT: Context = 0;

/// Q-coder state machine — pure binary arithmetic decoder.
///
/// Operates on a byte-stuffed JPEG entropy stream (0xFF NN where NN
/// != 0 is a marker; 0xFF 0x00 is a literal 0xFF byte). Marker
/// detection sets `marker_byte` and `marker_seen` for the upstream
/// consumer; subsequent decode calls return 0 bits (per T.81 §F.1.4
/// arith convention — "supply zero data until decoding is complete").
pub const QCoder = struct {
    /// Entropy stream backing store.
    data: []const u8,
    pos: usize,
    /// Range register (T.81 §D.2.2). Renormalized into [0x8000, 0xFFFF];
    /// transiently holds 0x10000 between the renorm-loop's final shift
    /// and the loop-exit check (T.81 §D.2.6 / libjpeg's JLONG width).
    /// Must be wider than 16 bits to avoid that shift truncating to 0
    /// — the bug that earlier u16 representation introduced.
    a: u32,
    /// Code register (T.81 §D.2.2). Holds the look-ahead bits.
    c: u32,
    /// Bit shift counter — signed because it dips below zero during
    /// the initial 2-byte load (T.81 §D.2.6).
    ct: i32,
    /// Set to the marker byte if a non-stuffed 0xFF was consumed;
    /// upstream walks back to the marker to dispatch.
    marker_byte: u8,
    marker_seen: bool,

    pub fn init(data: []const u8) QCoder {
        // T.81 §D.2.6 prescribes initial A and C states. We follow
        // libjpeg's two-pass pattern: enter the decode loop with
        // A = 0, ct = -16. The first two byte fetches load C, then
        // ct crosses zero and A is re-set to 0x8000. This is exactly
        // what `arith_decode` does on first call.
        return .{
            .data = data,
            .pos = 0,
            .a = 0,
            .c = 0,
            .ct = -16,
            .marker_byte = 0,
            .marker_seen = false,
        };
    }

    /// T.81 §D.2.6 byte fetch with 0xFF marker handling. Returns the
    /// byte to insert into the code register. On a marker, sets
    /// `marker_byte`/`marker_seen` and returns 0 (the "supply zero
    /// data until decoding is complete" convention).
    inline fn getByte(self: *QCoder) u8 {
        if (self.marker_seen) return 0;
        if (self.pos >= self.data.len) return 0;
        const b = self.data[self.pos];
        self.pos += 1;
        if (b != 0xFF) return b;
        // 0xFF — could be 0xFF 0x00 (literal 0xFF) or a marker.
        // libjpeg loops to "swallow extra 0xFF bytes" before checking.
        var next: u8 = 0;
        while (self.pos < self.data.len) {
            next = self.data[self.pos];
            self.pos += 1;
            if (next != 0xFF) break;
        }
        if (next == 0) return 0xFF; // 0xFF 0x00 escape — literal 0xFF.
        // Real marker — record and supply 0 from here on.
        self.marker_byte = next;
        self.marker_seen = true;
        return 0;
    }

    /// Decode one binary symbol per T.81 §D.2.4 / §D.2.5. Updates
    /// the context cell at `ctx_ptr` (state index + MPS) per the
    /// `qe_table` transitions. Returns the decoded bit (0 or 1).
    pub fn decode(self: *QCoder, ctx_ptr: *Context) u1 {
        // Renormalize and pull in new bytes per T.81 §D.2.6 / libjpeg
        // `arith_decode` (jdarith.c:122-155). Faithful port — the
        // peculiar `++e->ct` in the inner branch is the trick that
        // brings ct to exactly 0 after the second initial-byte fetch,
        // which is what triggers the one-shot `a = 0x8000` init.
        while (self.a < 0x8000) {
            self.ct -= 1;
            if (self.ct < 0) {
                const byte = self.getByte();
                self.c = (self.c << 8) | @as(u32, byte);
                self.ct += 8;
                // libjpeg's `if ((ct += 8) < 0) if (++ct == 0) a = 0x8000`.
                // The inner increment undoes the outer pre-decrement;
                // when it lands at exactly 0, we just finished the
                // 2-byte initial preload (ct trace: -16 → -17 → -9
                // → -8 after iter 1; -8 → -9 → -1 → 0 in iter 2).
                if (self.ct < 0) {
                    self.ct += 1;
                    if (self.ct == 0) self.a = 0x8000;
                }
            }
            // a is u32 so the shift can transiently produce 0x10000
            // (= libjpeg's JLONG value after exit); the loop check
            // then sees 0x10000 >= 0x8000 and bails.
            self.a = self.a << 1;
        }

        // Decode procedure per T.81 §D.2.4.
        const sv: Context = ctx_ptr.*;
        const state_index: usize = @as(usize, sv & 0x7F);
        const entry = QE_TABLE[state_index];
        const qe: u32 = entry.qe;
        const mps_bit: u1 = @intCast((sv >> 7) & 1);

        // Conditional subtraction (T.81 Fig. D.4).
        const a_after_mps: u32 = self.a - qe;
        self.a = a_after_mps;
        const temp: u32 = a_after_mps << @as(u5, @intCast(self.ct));
        // Note: libjpeg's reference does `temp <<= e->ct` with int,
        // but `ct` after loop exit is 0..7 — fits u5.

        var decoded: u1 = mps_bit;
        if (self.c >= temp) {
            // LPS region — possibly with MPS/LPS conditional exchange.
            self.c -= temp;
            if (self.a < qe) {
                // Conditional exchange: MPS occurred even though we
                // entered the LPS branch. State transitions per
                // estimate_after_MPS.
                self.a = qe;
                ctx_ptr.* = (sv & 0x80) | @as(u8, entry.next_mps);
                decoded = mps_bit;
            } else {
                // True LPS.
                self.a = qe;
                if (entry.switch_mps) {
                    ctx_ptr.* = ((sv & 0x80) ^ 0x80) | @as(u8, entry.next_lps);
                } else {
                    ctx_ptr.* = (sv & 0x80) | @as(u8, entry.next_lps);
                }
                decoded = @as(u1, ~mps_bit) & 1;
            }
        } else if (self.a < 0x8000) {
            // MPS region with conditional exchange (a after subtraction
            // dipped below 0x8000, so renormalization is needed).
            if (self.a < qe) {
                // Conditional exchange: LPS occurred.
                if (entry.switch_mps) {
                    ctx_ptr.* = ((sv & 0x80) ^ 0x80) | @as(u8, entry.next_lps);
                } else {
                    ctx_ptr.* = (sv & 0x80) | @as(u8, entry.next_lps);
                }
                decoded = @as(u1, ~mps_bit) & 1;
            } else {
                ctx_ptr.* = (sv & 0x80) | @as(u8, entry.next_mps);
                decoded = mps_bit;
            }
        }
        // If `self.c < temp` AND `self.a >= 0x8000`, no state change
        // needed; result is MPS at the current state.
        return decoded;
    }
};

// ─────── JPEG-specific binarization (T.81 §F.1.4.4.1) ───────────
//
// SOF9 (sequential arithmetic). Faithful port of libjpeg-turbo
// `jdarith.c` `decode_mcu` — see jdarith.c:504-624. Key insights
// vs the Huffman variant of the same field: SSSS-arith uses an `m`
// accumulator decoded via a unary X-walk (X1..X14), where m's
// magnitude range starts at 0 (v=1) and doubles with each unary
// 1-bit; AC differs from DC by an extra inner arith_decode at the
// magnitude-category context and a Kx-conditioned context split
// for the X-walk. See `NEXT_STEPS_B1.md` § "Spec interpretation
// crux" for the m-table and the libjpeg trace it derives from.

/// libjpeg's DC_STAT_BINS (jdarith.c line 69). T.81 §F.1.4.4.1.3
/// requires ≥49 bins; libjpeg rounds up to 64 — we mirror for parity.
pub const DC_STAT_BINS: usize = 64;
/// libjpeg's AC_STAT_BINS (jdarith.c line 70). T.81 §F.1.4.4.2 needs
/// ≥245; libjpeg rounds up to 256.
pub const AC_STAT_BINS: usize = 256;

/// Errors surfaced by the arithmetic binarization layer. `Truncated`
/// and `InvalidMarker` come from the Q-coder; `BackendError` signals
/// a bitstream that violates T.81 invariants (e.g. magnitude
/// overflow past 2^15, run length past Se=63).
pub const ArithError = error{
    TruncatedStream,
    InvalidMarker,
    BackendError,
};

/// Per-scan state — Q-coder + statistics + DC predictor + DAC
/// conditioning parameters. 1:1 with libjpeg's
/// `arith_entropy_decoder` (jdarith.c:32-52). Lives by value;
/// allocator-free.
pub const ScanState = struct {
    qcoder: QCoder,
    /// Per-table DC statistics areas. Each cell holds {state_index,
    /// MPS} packed per `Context`. Indexed by `arith_dc_table[tbl][cell]`.
    dc_stats: [4][DC_STAT_BINS]Context,
    /// Per-table AC statistics areas.
    ac_stats: [4][AC_STAT_BINS]Context,
    /// Fixed-probability bin (~0.5). Used for AC sign and refinement
    /// scan flips. Initialized to state index 113 — QE_TABLE[113] has
    /// next_lps=113, next_mps=113, so it never transitions.
    fixed_bin: Context,
    /// DC predictor per component (T.81 §F.1.2.1.3). Held mod 2^16 —
    /// libjpeg does `(last_dc_val + v) & 0xffff` after each block to
    /// match T.81's i16 wraparound. Store as i32 with the mask applied.
    last_dc_val: [4]i32,
    /// DC context for next block: one of {0, 4, 8, 12, 16} — picks
    /// the statistics-bin base for the upcoming DC decode based on
    /// the prior block's diff magnitude category.
    dc_context: [4]u8,
    /// DAC DC conditioning: lower magnitude-bin threshold per table
    /// (T.81 §B.2.4.3 / §F.1.4.4.1.2). Default 0.
    arith_dc_L: [4]u8,
    /// DAC DC conditioning: upper magnitude-bin threshold. Default 1.
    arith_dc_U: [4]u8,
    /// DAC AC conditioning: Kx — context boundary between low-freq
    /// and high-freq AC unary X-walk slots. Default 5.
    arith_ac_K: [4]u8,

    /// Initial state at scan start. All statistics zeroed (T.81
    /// §F.1.4.4 — every context begins at state 0 with MPS=0). DAC
    /// defaults applied unconditionally — even fixtures with no DAC
    /// segment use these.
    pub fn init(data: []const u8) ScanState {
        return .{
            .qcoder = QCoder.init(data),
            .dc_stats = .{.{INITIAL_CONTEXT} ** DC_STAT_BINS} ** 4,
            .ac_stats = .{.{INITIAL_CONTEXT} ** AC_STAT_BINS} ** 4,
            .fixed_bin = 113,
            .last_dc_val = .{ 0, 0, 0, 0 },
            .dc_context = .{ 0, 0, 0, 0 },
            .arith_dc_L = .{ 0, 0, 0, 0 },
            .arith_dc_U = .{ 1, 1, 1, 1 },
            .arith_ac_K = .{ 5, 5, 5, 5 },
        };
    }

    /// Reset on RSTm marker (T.81 §F.2.4.2). Q-coder restarts over
    /// the remaining bytes, all statistics re-zero, DC predictors
    /// and contexts reset. DAC parameters persist (scan-wide).
    pub fn resetForRestart(self: *ScanState, data: []const u8) void {
        self.qcoder = QCoder.init(data);
        self.dc_stats = .{.{INITIAL_CONTEXT} ** DC_STAT_BINS} ** 4;
        self.ac_stats = .{.{INITIAL_CONTEXT} ** AC_STAT_BINS} ** 4;
        self.last_dc_val = .{ 0, 0, 0, 0 };
        self.dc_context = .{ 0, 0, 0, 0 };
    }

    /// Per-scan reset for SOF10 progressive — see libjpeg jdarith.c
    /// `start_pass`. The Q-coder always restarts at every SOS, but
    /// only the statistics tables touched by this scan type get
    /// zeroed:
    ///   - DC-first (Ss=0, Ah=0): zero dc_stats + reset DC predictors.
    ///   - DC-refine (Ss=0, Ah>0): zero nothing.
    ///   - AC-first / AC-refine (Ss>0): zero ac_stats.
    /// `fixed_bin` never changes (state 113 forever); DAC L/U/Kx
    /// persist (frame-scope).
    pub fn startScan(self: *ScanState, data: []const u8, reset_dc: bool, reset_ac: bool) void {
        self.qcoder = QCoder.init(data);
        if (reset_dc) {
            self.dc_stats = .{.{INITIAL_CONTEXT} ** DC_STAT_BINS} ** 4;
            self.last_dc_val = .{ 0, 0, 0, 0 };
            self.dc_context = .{ 0, 0, 0, 0 };
        }
        if (reset_ac) {
            self.ac_stats = .{.{INITIAL_CONTEXT} ** AC_STAT_BINS} ** 4;
        }
    }
};

/// Decode one DC differential per T.81 §F.1.4.4.1 / Fig. F.19-F.24.
/// Faithful port of libjpeg's decode_mcu DC arm (jdarith.c:534-571).
/// Mutates `state.last_dc_val[ci]` and `state.dc_context[ci]` in
/// place; returns the i16-wrapped DC sample to store at block[0].
///
/// The magnitude-category SSSS_arith is *not* the same as
/// Huffman's SSSS — see NEXT_STEPS_B1.md § crux for the m-table.
pub fn decodeDcSof9(state: *ScanState, ci: usize, dc_tbl: u8) ArithError!i16 {
    if (dc_tbl >= 4) return error.InvalidMarker;
    const stats: *[DC_STAT_BINS]Context = &state.dc_stats[dc_tbl];
    const ctx_base: u8 = state.dc_context[ci];
    var st_idx: usize = ctx_base;

    // Fig. F.19: zero-test (S0).
    if (state.qcoder.decode(&stats[st_idx]) == 0) {
        state.dc_context[ci] = 0;
    } else {
        // Fig. F.22: sign decode at S0+1.
        const sign: u1 = state.qcoder.decode(&stats[st_idx + 1]);
        // st_idx ← base + 2 (sign=0 → S2) or base + 3 (sign=1 → S3).
        st_idx = @as(usize, ctx_base) + 2 + @as(usize, sign);
        // Fig. F.23: first magnitude bit. m ∈ {0, 1} from this decode.
        var m: i32 = @intCast(state.qcoder.decode(&stats[st_idx]));
        if (m != 0) {
            // Enter unary X-walk starting at X1 = cell 20. The loop
            // tests at the current cell; on a 1, shift m left and
            // advance to next X cell.
            st_idx = 20;
            while (state.qcoder.decode(&stats[st_idx]) == 1) {
                m <<= 1;
                if (m == 0x8000) return error.BackendError;
                st_idx += 1;
                if (st_idx >= DC_STAT_BINS) return error.BackendError;
            }
        }

        // T.81 §F.1.4.4.1.2: set dc_context for the NEXT block based
        // on the magnitude category of this block's diff. arith_dc_L/U
        // ∈ [0, 15] per T.81 §B.2.4.3; reject out-of-range as malformed.
        const sign_int: i32 = @intCast(sign);
        if (state.arith_dc_L[dc_tbl] > 15 or state.arith_dc_U[dc_tbl] > 15)
            return error.BackendError;
        const dc_L_shift: u5 = @intCast(state.arith_dc_L[dc_tbl]);
        const dc_U_shift: u5 = @intCast(state.arith_dc_U[dc_tbl]);
        const L: i32 = (@as(i32, 1) << dc_L_shift) >> 1;
        const U: i32 = (@as(i32, 1) << dc_U_shift) >> 1;
        if (m < L) {
            state.dc_context[ci] = 0;
        } else if (m > U) {
            state.dc_context[ci] = @intCast(12 + sign_int * 4);
        } else {
            state.dc_context[ci] = @intCast(4 + sign_int * 4);
        }

        // Fig. F.24: magnitude bit pattern. All k-2 mag bits share one
        // context cell (= current st_idx + 14). The Q-coder adapts the
        // probability across iterations automatically.
        var v: i32 = m;
        st_idx += 14;
        while (true) {
            m >>= 1;
            if (m == 0) break;
            if (state.qcoder.decode(&stats[st_idx]) == 1) v |= m;
        }
        v += 1;
        if (sign == 1) v = -v;

        // T.81 wraparound — libjpeg masks to u16 then re-interprets
        // as i16 when storing into JCOEF. Trap #5 in NEXT_STEPS.
        const sum: i32 = state.last_dc_val[ci] + v;
        state.last_dc_val[ci] = sum & 0xFFFF;
    }

    // Return i16-wrapped DC. Mask bit 15 → sign extend.
    const u_val: u16 = @intCast(@as(u32, @bitCast(state.last_dc_val[ci])) & 0xFFFF);
    return @bitCast(u_val);
}

/// Decode the 63 AC coefficients of one block per T.81 §F.1.4.4.2 /
/// Fig. F.20. Faithful port of libjpeg's decode_mcu AC arm
/// (jdarith.c:577-620). Writes non-zero values into `zz` in **zig-zag
/// index order** — k=1..63 — leaving the natural-order placement
/// and dequantization to the caller (mirrors baseline.zig's split).
/// `zz` must be pre-zeroed.
///
/// **AC differs from DC** at the magnitude-category step: an extra
/// inner arith_decode at the same st *before* entering the X-walk,
/// plus a Kx-conditioned base for the X-walk (cell 189 if k ≤ Kx,
/// else 217). Trap #4 — don't share helpers with DC.
pub fn decodeAcSof9(
    state: *ScanState,
    ac_tbl: u8,
    zz: *[64]i32,
) ArithError!void {
    if (ac_tbl >= 4) return error.InvalidMarker;
    const stats: *[AC_STAT_BINS]Context = &state.ac_stats[ac_tbl];
    const Kx: u8 = state.arith_ac_K[ac_tbl];

    var k: usize = 1;
    while (k <= 63) {
        var st_idx: usize = 3 * (k - 1);
        // EOB flag at cell 3*(k-1). End of block → remaining ACs are 0.
        if (state.qcoder.decode(&stats[st_idx]) == 1) break;
        // Run-of-zeros: while is-zero (cell st+1) bit is 0, skip k.
        while (state.qcoder.decode(&stats[st_idx + 1]) == 0) {
            st_idx += 3;
            k += 1;
            if (k > 63) return error.BackendError;
        }
        // Sign decode against the shared fixed-probability bin.
        const sign: u1 = state.qcoder.decode(&state.fixed_bin);
        // M context = cell 3*(k-1) + 2.
        st_idx += 2;
        var m: i32 = @intCast(state.qcoder.decode(&stats[st_idx]));
        if (m != 0) {
            // EXTRA inner decision at SAME st before X-walk.
            if (state.qcoder.decode(&stats[st_idx]) == 1) {
                m <<= 1;
                // Kx-conditioned X-walk base.
                st_idx = if (k <= @as(usize, Kx)) 189 else 217;
                while (state.qcoder.decode(&stats[st_idx]) == 1) {
                    m <<= 1;
                    if (m == 0x8000) return error.BackendError;
                    st_idx += 1;
                    if (st_idx >= AC_STAT_BINS) return error.BackendError;
                }
            }
        }
        // Magnitude bit pattern (shared context at st + 14).
        var v: i32 = m;
        st_idx += 14;
        while (true) {
            m >>= 1;
            if (m == 0) break;
            if (state.qcoder.decode(&stats[st_idx]) == 1) v |= m;
        }
        v += 1;
        if (sign == 1) v = -v;

        zz[k] = v;
        k += 1;
    }
}

// ─────── SOF10 progressive arithmetic (T.81 §G.1.2) ─────────────
//
// Four scan types: DC-first / AC-first / DC-refine / AC-refine.
// The shape of each mirrors libjpeg-turbo `jdarith.c` exactly:
// `decode_mcu_DC_first` (lines 250-320), `decode_mcu_AC_first`
// (329-395), `decode_mcu_DC_refine` (403-428), `decode_mcu_AC_refine`
// (436-498).
//
// Differences vs SOF9 sequential:
//   - DC scans store the reconstructed sample << Al into block[0]
//     instead of writing the i16 wraparound directly. Later scans
//     refine the bits Al-1..0.
//   - AC scans walk a [Ss..Se] zig-zag range, not all 63 coefs.
//   - Output is i16 in NATURAL order (un-zig-zagged) — same shape
//     as `progressive.zig`'s persistent coef_buf — because multiple
//     scans accumulate into the same block buffer.
//   - DC refinement uses `fixed_bin` for the single per-block bit.
//   - AC refinement is the gnarly one: walks EOBx, branches on
//     "previously nonzero" (refine bit at st+2) vs "newly nonzero"
//     (decision at st+1, sign at fixed_bin).
//
// `ZIGZAG_AC[k]` maps a zigzag index k to its natural-order
// position in the block — same as libjpeg's `jpeg_natural_order`,
// same as `baseline.zig`'s `ZIGZAG`. Local copy keeps arith_coder
// independent of the higher-level decode modules.
pub const ZIGZAG_AC: [64]u8 = .{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// T.81 §G.1.2.1 — DC first pass (Ss=0, Ah=0). Faithful port of
/// libjpeg's `decode_mcu_DC_first` DC arm (jdarith.c:280-313).
/// Writes the reconstructed DC sample << al into block[0].
/// `block` is natural-order i16 (only index 0 is touched here).
pub fn decodeDcFirstArith(
    state: *ScanState,
    ci: usize,
    dc_tbl: u8,
    al: u4,
    block: []i16,
) ArithError!void {
    if (dc_tbl >= 4) return error.InvalidMarker;
    const stats: *[DC_STAT_BINS]Context = &state.dc_stats[dc_tbl];
    const ctx_base: u8 = state.dc_context[ci];
    var st_idx: usize = ctx_base;

    if (state.qcoder.decode(&stats[st_idx]) == 0) {
        state.dc_context[ci] = 0;
    } else {
        const sign: u1 = state.qcoder.decode(&stats[st_idx + 1]);
        st_idx = @as(usize, ctx_base) + 2 + @as(usize, sign);
        var m: i32 = @intCast(state.qcoder.decode(&stats[st_idx]));
        if (m != 0) {
            st_idx = 20;
            while (state.qcoder.decode(&stats[st_idx]) == 1) {
                m <<= 1;
                if (m == 0x8000) return error.BackendError;
                st_idx += 1;
                if (st_idx >= DC_STAT_BINS) return error.BackendError;
            }
        }
        const sign_int: i32 = @intCast(sign);
        if (state.arith_dc_L[dc_tbl] > 15 or state.arith_dc_U[dc_tbl] > 15)
            return error.BackendError;
        const dc_L_shift: u5 = @intCast(state.arith_dc_L[dc_tbl]);
        const dc_U_shift: u5 = @intCast(state.arith_dc_U[dc_tbl]);
        const L: i32 = (@as(i32, 1) << dc_L_shift) >> 1;
        const U: i32 = (@as(i32, 1) << dc_U_shift) >> 1;
        if (m < L) state.dc_context[ci] = 0
        else if (m > U) state.dc_context[ci] = @intCast(12 + sign_int * 4)
        else state.dc_context[ci] = @intCast(4 + sign_int * 4);

        var v: i32 = m;
        st_idx += 14;
        while (true) {
            m >>= 1;
            if (m == 0) break;
            if (state.qcoder.decode(&stats[st_idx]) == 1) v |= m;
        }
        v += 1;
        if (sign == 1) v = -v;
        const sum: i32 = state.last_dc_val[ci] + v;
        state.last_dc_val[ci] = sum & 0xFFFF;
    }
    // Sign-extend to i16 and emit shifted into the block's DC slot.
    const u_val: u16 = @intCast(@as(u32, @bitCast(state.last_dc_val[ci])) & 0xFFFF);
    const dc_i16: i16 = @bitCast(u_val);
    // T.81 §G.1.2.1: emit dc_i16 << al. Use a 32-bit shift then
    // truncate to i16 to handle wraparound the same way libjpeg's
    // `(JCOEF)LEFT_SHIFT(...)` does.
    const shifted: i32 = @as(i32, dc_i16) << al;
    block[0] = @truncate(shifted);
}

/// T.81 §G.1.2.3 — DC refinement scan (Ss=0, Ah>0). One bit per
/// block decoded against `fixed_bin`. If the bit is 1, OR-in the
/// `1 << al` mask at block[0]. Mirrors libjpeg's
/// `decode_mcu_DC_refine` (jdarith.c:402-428).
pub fn decodeDcRefineArith(state: *ScanState, al: u4, block: []i16) void {
    const bit: u1 = state.qcoder.decode(&state.fixed_bin);
    if (bit == 1) {
        const mask: i16 = @as(i16, 1) << al;
        block[0] |= mask;
    }
}

/// T.81 §G.1.2.2 — AC first pass (Ss>=1, Ah=0). Decodes the AC
/// coefficients in zig-zag range [ss, se], shifted left by `al`,
/// into `block[ZIGZAG_AC[k]]`. Mirrors `decode_mcu_AC_first`
/// (jdarith.c:329-395). Loop semantics match `decodeAcSof9` —
/// extra inner arith_decode at M, Kx-conditioned X-walk base.
pub fn decodeAcFirstArith(
    state: *ScanState,
    ac_tbl: u8,
    ss: u8,
    se: u8,
    al: u4,
    block: []i16,
) ArithError!void {
    if (ac_tbl >= 4) return error.InvalidMarker;
    if (ss < 1 or se > 63 or se < ss) return error.InvalidMarker;
    const stats: *[AC_STAT_BINS]Context = &state.ac_stats[ac_tbl];
    const Kx: u8 = state.arith_ac_K[ac_tbl];

    var k: usize = ss;
    while (k <= se) {
        var st_idx: usize = 3 * (k - 1);
        if (state.qcoder.decode(&stats[st_idx]) == 1) break; // EOB
        while (state.qcoder.decode(&stats[st_idx + 1]) == 0) {
            st_idx += 3;
            k += 1;
            if (k > se) return error.BackendError;
        }
        const sign: u1 = state.qcoder.decode(&state.fixed_bin);
        st_idx += 2;
        var m: i32 = @intCast(state.qcoder.decode(&stats[st_idx]));
        if (m != 0) {
            if (state.qcoder.decode(&stats[st_idx]) == 1) {
                m <<= 1;
                st_idx = if (k <= @as(usize, Kx)) 189 else 217;
                while (state.qcoder.decode(&stats[st_idx]) == 1) {
                    m <<= 1;
                    if (m == 0x8000) return error.BackendError;
                    st_idx += 1;
                    if (st_idx >= AC_STAT_BINS) return error.BackendError;
                }
            }
        }
        var v: i32 = m;
        st_idx += 14;
        while (true) {
            m >>= 1;
            if (m == 0) break;
            if (state.qcoder.decode(&stats[st_idx]) == 1) v |= m;
        }
        v += 1;
        if (sign == 1) v = -v;
        // Shift << al and write at the ZIG-ZAG index k. progressive.zig's
        // coef buffers are zig-zag-indexed throughout; un-zig-zagging
        // happens inside `assembleProgressiveGeneric`.
        const shifted: i32 = v << al;
        block[k] = @truncate(shifted);
        k += 1;
    }
}

/// T.81 §G.1.2.4 — AC refinement scan (Ss>=1, Ah>0). For each
/// zig-zag position in [ss, se]:
///   - If we're past the previous-stage EOB index, test an EOB
///     flag at cell 3*(k-1). If 1, terminate the scan early.
///   - For previously-nonzero coefs, optionally flip-toward magnitude
///     bit (cell 3*(k-1) + 2, fixed_bin not involved).
///   - For previously-zero coefs, decide newly-nonzero (cell 3*(k-1)+1)
///     and on yes decode the sign from `fixed_bin`, setting
///     `±(1 << al)`.
///   - Otherwise walk forward (st += 3, k++) until something fires.
/// Mirrors `decode_mcu_AC_refine` (jdarith.c:435-497).
pub fn decodeAcRefineArith(
    state: *ScanState,
    ac_tbl: u8,
    ss: u8,
    se: u8,
    al: u4,
    block: []i16,
) ArithError!void {
    if (ac_tbl >= 4) return error.InvalidMarker;
    if (ss < 1 or se > 63 or se < ss) return error.InvalidMarker;
    const stats: *[AC_STAT_BINS]Context = &state.ac_stats[ac_tbl];
    const p1: i16 = @as(i16, 1) << al;
    const m1: i16 = -p1;

    // EOBx = highest zig-zag index in [1..se] with a nonzero coef.
    // progressive.zig stores coefs zig-zag-indexed, so block[k] is
    // the kth zig-zag coefficient (NOT block[natural_order[k]]).
    var kex: usize = se;
    while (kex > 0) : (kex -= 1) {
        if (block[kex] != 0) break;
    }

    var k: usize = ss;
    while (k <= se) : (k += 1) {
        var st_idx: usize = 3 * (k - 1);
        if (k > kex) {
            if (state.qcoder.decode(&stats[st_idx]) == 1) break; // EOB
        }
        // Inner: walk until "previously nonzero" or "newly nonzero" fires.
        while (true) {
            const coef: i16 = block[k];
            if (coef != 0) {
                // Previously nonzero — possibly flip magnitude bit.
                if (state.qcoder.decode(&stats[st_idx + 2]) == 1) {
                    block[k] = coef +| (if (coef < 0) m1 else p1);
                }
                break;
            }
            if (state.qcoder.decode(&stats[st_idx + 1]) == 1) {
                // Newly nonzero.
                const sign: u1 = state.qcoder.decode(&state.fixed_bin);
                block[k] = if (sign == 1) m1 else p1;
                break;
            }
            st_idx += 3;
            k += 1;
            if (k > se) return error.BackendError;
        }
    }
}

test "QE_TABLE: spec-known anchors" {
    // Index 0: Qe = 0x5a1d (the most-frequently-used probability)
    try std.testing.expectEqual(@as(u16, 0x5a1d), QE_TABLE[0].qe);
    try std.testing.expectEqual(@as(u7, 1), QE_TABLE[0].next_lps);
    try std.testing.expectEqual(@as(u7, 1), QE_TABLE[0].next_mps);
    try std.testing.expectEqual(true, QE_TABLE[0].switch_mps);
    // Index 112: last "real" state — Qe = 0x59eb, switch_mps set.
    try std.testing.expectEqual(@as(u16, 0x59eb), QE_TABLE[112].qe);
    try std.testing.expectEqual(true, QE_TABLE[112].switch_mps);
}

test "QCoder init: no allocations, neutral state" {
    const qc = QCoder.init(&[_]u8{});
    try std.testing.expectEqual(@as(u32, 0), qc.a);
    try std.testing.expectEqual(@as(u32, 0), qc.c);
    try std.testing.expectEqual(@as(i32, -16), qc.ct);
    try std.testing.expectEqual(false, qc.marker_seen);
}

test "QCoder.decode: terminates on all-zero stream from initial context" {
    // Regression for the renormalization-loop infinite-loop bug
    // (u16 a truncating 0x10000 to 0, never exits). With u32 a and
    // the libjpeg `++ct` fix, the loop must complete in finite time.
    const stream = [_]u8{0} ** 16;
    var qc = QCoder.init(&stream);
    var ctx: Context = INITIAL_CONTEXT;
    // 8 consecutive decodes — enough to exercise multiple renorm loops.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = qc.decode(&ctx);
    }
    // a must be in the normalized range after the call.
    try std.testing.expect(qc.a >= 0x8000);
}

test "QCoder.getByte: 0xFF 0x00 escape returns literal 0xFF" {
    const stream = [_]u8{ 0xFF, 0x00, 0x42 };
    var qc = QCoder.init(&stream);
    try std.testing.expectEqual(@as(u8, 0xFF), qc.getByte());
    try std.testing.expectEqual(@as(u8, 0x42), qc.getByte());
    try std.testing.expectEqual(false, qc.marker_seen);
}

test "QCoder.getByte: 0xFF NN where NN != 0 sets marker state" {
    const stream = [_]u8{ 0x01, 0xFF, 0xD0, 0x02 };
    var qc = QCoder.init(&stream);
    try std.testing.expectEqual(@as(u8, 0x01), qc.getByte());
    try std.testing.expectEqual(@as(u8, 0), qc.getByte()); // marker → zero
    try std.testing.expectEqual(true, qc.marker_seen);
    try std.testing.expectEqual(@as(u8, 0xD0), qc.marker_byte);
    // Subsequent calls keep returning 0.
    try std.testing.expectEqual(@as(u8, 0), qc.getByte());
}

test "ScanState.init: DAC defaults applied even with no DAC marker" {
    const state = ScanState.init(&[_]u8{});
    // T.81 §B.2.4.3 defaults: L=0, U=1, Kx=5 for all 4 tables.
    for (state.arith_dc_L) |v| try std.testing.expectEqual(@as(u8, 0), v);
    for (state.arith_dc_U) |v| try std.testing.expectEqual(@as(u8, 1), v);
    for (state.arith_ac_K) |v| try std.testing.expectEqual(@as(u8, 5), v);
    // fixed_bin starts at state 113 (~Qe=0.5) per T.851 §10.3.
    try std.testing.expectEqual(@as(Context, 113), state.fixed_bin);
    // DC predictors and contexts start at 0.
    for (state.last_dc_val) |v| try std.testing.expectEqual(@as(i32, 0), v);
    for (state.dc_context) |v| try std.testing.expectEqual(@as(u8, 0), v);
    // Statistics zeroed.
    try std.testing.expectEqual(INITIAL_CONTEXT, state.dc_stats[0][0]);
    try std.testing.expectEqual(INITIAL_CONTEXT, state.ac_stats[0][245]);
}

test "ScanState.resetForRestart: predictors and stats reset, DAC persists" {
    const data = [_]u8{ 0x12, 0x34, 0x56 };
    var state = ScanState.init(&data);
    state.last_dc_val[0] = 1234;
    state.dc_context[2] = 12;
    state.dc_stats[0][3] = 0x80 | 50; // non-initial value
    state.arith_ac_K[1] = 9; // simulate a DAC override
    state.resetForRestart(data[1..]);
    try std.testing.expectEqual(@as(i32, 0), state.last_dc_val[0]);
    try std.testing.expectEqual(@as(u8, 0), state.dc_context[2]);
    try std.testing.expectEqual(INITIAL_CONTEXT, state.dc_stats[0][3]);
    // DAC overrides survive — they apply scan-wide.
    try std.testing.expectEqual(@as(u8, 9), state.arith_ac_K[1]);
}

test "decodeDcSof9: smoke — completes on short stream without panicking" {
    // The full-precision test is the cleanroom-vs-wrapper fixture suite
    // (tests/unit/decode.zig). This smoke test just confirms the function
    // is wired up and doesn't crash on a tiny buffer.
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var state = ScanState.init(&data);
    _ = decodeDcSof9(&state, 0, 0) catch |e| switch (e) {
        // Either a normal return or a BackendError — both are acceptable
        // for arbitrary input. What we're guarding against is a panic.
        error.BackendError, error.TruncatedStream, error.InvalidMarker => {},
    };
}

test "decodeAcSof9: smoke — completes on short stream without panicking" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var state = ScanState.init(&data);
    var zz: [64]i32 = .{0} ** 64;
    _ = decodeAcSof9(&state, 0, &zz) catch |e| switch (e) {
        error.BackendError, error.TruncatedStream, error.InvalidMarker => {},
    };
}
