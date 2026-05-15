//! JPEG-LS bit reader (T.87 §A.1.3 / §B.1.1.2).
//!
//! Different from the T.81 `bitstream.BitReader`:
//!
//!   T.81 byte-stuffing rule: 0xFF in data is followed by 0x00; the
//!     decoder reads the 0x00 and ignores it, treating the 0xFF as
//!     literal payload. Otherwise 0xFF + non-zero = marker.
//!
//!   T.87 BIT-stuffing rule (§A.1.3): every time the encoder writes
//!     a byte equal to 0xFF, it inserts a single 0 bit BEFORE the
//!     next real data bit. Marker detection (§B.1.1.2): a 0xFF in
//!     data followed by a byte whose top bit is 1 (i.e. ≥ 0x80) is
//!     a marker — the inserted 0 bit isn't there.
//!
//! Reader rules:
//!   - Buffer bytes into a 64-bit MSB-aligned word.
//!   - After consuming an 0xFF byte:
//!       * If next byte's top bit is 1 → marker; set `marker_seen`
//!         and stop refilling.
//!       * Otherwise → discard the next byte's top bit (the
//!         inserted 0) and append only its bottom 7 bits.

const std = @import("std");

pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    /// 64-bit MSB-aligned bit accumulator.
    buf: u64,
    /// Bits valid in `buf` (top `valid` bits — buf >> (64 - valid)).
    valid: u7,
    /// True while the last consumed byte was 0xFF (next byte triggers
    /// either a marker or a bit-stuffed escape).
    last_byte_was_ff: bool,
    marker_seen: bool,
    /// The marker byte itself (e.g. 0xD9 for EOI). Valid only when
    /// `marker_seen == true`.
    marker_byte: u8,

    pub fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .pos = 0,
            .buf = 0,
            .valid = 0,
            .last_byte_was_ff = false,
            .marker_seen = false,
            .marker_byte = 0,
        };
    }

    /// Refill `buf` until at least `min_bits` bits are valid OR we
    /// hit end-of-stream / a marker. The MSB-aligned layout means
    /// `buf` always has its newest bits at the TOP.
    inline fn refill(self: *BitReader, min_bits: u7) void {
        while (self.valid < min_bits and !self.marker_seen) {
            if (self.pos >= self.data.len) return;
            const byte = self.data[self.pos];
            if (self.last_byte_was_ff) {
                if (byte & 0x80 != 0) {
                    // Marker — the inserted 0 isn't here. Don't
                    // consume; let the caller seek past it later.
                    self.marker_seen = true;
                    self.marker_byte = byte;
                    return;
                }
                // Bit-stuffed escape: top bit is the inserted 0;
                // append only the lower 7 bits.
                self.pos += 1;
                // Align "byte's bottom 7 bits" to the top of where
                // the next bits go.
                self.buf |= @as(u64, byte & 0x7F) << @intCast(64 - 7 - @as(u7, self.valid));
                self.valid += 7;
                self.last_byte_was_ff = false; // bottom 7 of 0x7F can't form 0xFF
            } else {
                self.pos += 1;
                self.buf |= @as(u64, byte) << @intCast(64 - 8 - @as(u7, self.valid));
                self.valid += 8;
                self.last_byte_was_ff = (byte == 0xFF);
            }
        }
    }

    /// Read `n` bits MSB-first. n ∈ [0, 32]. Refills as needed; if
    /// the stream is exhausted (or hit a marker), returns zero-padded
    /// bits — same convention as the rest of the library's bit
    /// readers ("supply zero data until decoding is complete").
    pub fn readBits(self: *BitReader, n: u6) u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        self.refill(@intCast(n));
        // Take top n bits.
        const shift: u6 = @intCast(64 - @as(u7, n));
        const result: u32 = @intCast(self.buf >> shift);
        // Consume them: shift buf left by n.
        self.buf = self.buf << @intCast(n);
        if (self.valid >= n) self.valid -= @intCast(n) else self.valid = 0;
        return result;
    }

    /// Peek `n` bits without consuming. Used for variable-length
    /// codes where the number of bits needed is determined by the
    /// content.
    pub fn peekBits(self: *BitReader, n: u6) u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        self.refill(@intCast(n));
        const shift: u6 = @intCast(64 - @as(u7, n));
        return @intCast(self.buf >> shift);
    }

    /// Consume `n` previously-peeked bits.
    pub fn consume(self: *BitReader, n: u6) void {
        self.buf = self.buf << @intCast(n);
        if (self.valid >= n) self.valid -= @intCast(n) else self.valid = 0;
    }

    /// Read a unary code: count consecutive 1-bits, stop at the
    /// first 0 (which is consumed). `limit` is the maximum count
    /// before we bail and return `limit` exactly — protects against
    /// pathological streams that would otherwise spin forever.
    /// Used by Golomb-Rice decode (T.87 §A.5.3).
    pub fn readUnary(self: *BitReader, limit: u8) u32 {
        var count: u32 = 0;
        while (count < limit) : (count += 1) {
            const bit = self.readBits(1);
            if (bit == 0) return count;
        }
        return count;
    }
};

// ── Inline tests ─────────────────────────────────────────────────

test "BitReader: read MSB-first across byte boundary" {
    // Bytes 0b10110100 0b11010001 → 16 bits MSB-first.
    const data = [_]u8{ 0xB4, 0xD1 };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0b1), br.readBits(1));
    try std.testing.expectEqual(@as(u32, 0b011010), br.readBits(6));
    try std.testing.expectEqual(@as(u32, 0b011), br.readBits(3));
    try std.testing.expectEqual(@as(u32, 0b010001), br.readBits(6));
}

test "BitReader: bit-stuffed 0xFF discards next top bit" {
    // 0xFF then 0x7E. 0xFF is 8 bits of all-1s, then the encoder
    // inserted a 0; the 0x7E byte's top bit (0) is the stuffed bit,
    // bottom 7 bits = 0x7E & 0x7F = 0x7E = 0b1111110 are real data.
    const data = [_]u8{ 0xFF, 0x7E };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0xFF), br.readBits(8));
    // Next 7 bits = 0x7E = 0b1111110.
    try std.testing.expectEqual(@as(u32, 0b1111110), br.readBits(7));
}

test "BitReader: 0xFF followed by top-bit-set byte signals marker" {
    // 0xD0 (some entropy bits), then 0xFF 0xD9 (EOI marker).
    const data = [_]u8{ 0xD0, 0xFF, 0xD9 };
    var br = BitReader.init(&data);
    // 8 bits of 0xD0 readable.
    try std.testing.expectEqual(@as(u32, 0xD0), br.readBits(8));
    // 0xFF can be consumed as data.
    try std.testing.expectEqual(@as(u32, 0xFF), br.readBits(8));
    // Now the next refill should detect the marker.
    _ = br.readBits(1);
    try std.testing.expect(br.marker_seen);
    try std.testing.expectEqual(@as(u8, 0xD9), br.marker_byte);
}

test "BitReader: readUnary terminates at 0-bit" {
    // 0b1110_0000 → unary = 3, then a 0, then padding.
    const data = [_]u8{0b1110_0000};
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 3), br.readUnary(16));
}

test "BitReader: readUnary respects limit on degenerate stream" {
    const data = [_]u8{ 0xFF, 0x7F, 0xFF, 0x7F, 0xFF, 0x7F };
    // 0xFF is 8 ones, then bit-stuff escape, then 0x7F & 0x7F = 7
    // ones, but wait — the bit-stuff makes the bottom 7 bits of 0x7F
    // = 0b1111111 = 7 more ones. So the stream is effectively a long
    // run of 1s. The limit must terminate it.
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 16), br.readUnary(16));
}

test "BitReader: exhausted stream returns zero-padded" {
    const data = [_]u8{0xFF};  // single byte
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0xFF), br.readBits(8));
    // No more data; readBits should return 0 padding.
    try std.testing.expectEqual(@as(u32, 0), br.readBits(8));
}
