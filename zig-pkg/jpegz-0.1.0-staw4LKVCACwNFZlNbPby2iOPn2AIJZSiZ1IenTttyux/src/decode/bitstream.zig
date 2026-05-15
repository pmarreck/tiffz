//! JPEG entropy-coded bitstream reader.
//!
//! Inside an SOS scan, the byte sequence `0xFF 0x00` is a literal
//! `0xFF` payload byte (T.81 §F.1.2.3 byte stuffing). Any other
//! `0xFF NN` is a marker — those terminate the scan. This reader
//! consumes raw bytes from the entropy stream and produces an
//! MSB-first bit stream, transparently handling the FF/00 stuffing.
//!
//! The reader tracks "marker reached" state separately from "stream
//! exhausted" — an upstream MCU loop checks `markerHit()` after each
//! coefficient block to know whether to stop and let the marker
//! parser take over (RST handling, EOI, next SOS, etc.).
//!
//! Hot path: peek 16 bits at a time so the Huffman fast-lookup table
//! can inspect them without per-bit overhead. `consume(N)` advances
//! the bit cursor.

const std = @import("std");

/// Returned by `peek` when the stream has been fully consumed AND
/// no marker was found. Distinct from `markerHit()` (which means
/// a marker terminated the scan cleanly).
pub const Error = error{
    UnexpectedEnd,
    /// Caller asked for more bits than the reader can provide
    /// (stream exhausted with no marker; usually means truncated input).
    NotEnoughBits,
};

pub const BitReader = struct {
    data: []const u8,
    /// Byte position in `data`.
    byte_pos: usize,
    /// Bit-buffer accumulator (top bits-valid bits are payload, MSB-first).
    /// Up to 32 bits of lookahead so peek16() always returns a full
    /// 16 even after a refill.
    buf: u32,
    /// Number of valid payload bits currently in `buf`.
    bits_valid: u5,
    /// Set true when the scan was terminated by a marker (other than
    /// 0xFF 0x00 byte-stuffing). The marker byte that triggered exit
    /// is captured in `marker_byte` for the caller's marker dispatcher.
    marker_seen: bool,
    marker_byte: u8,

    pub fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .byte_pos = 0,
            .buf = 0,
            .bits_valid = 0,
            .marker_seen = false,
            .marker_byte = 0,
        };
    }

    /// Pull bytes from `data` into the bit buffer until at least
    /// `min_bits` valid bits are available, OR a marker is reached,
    /// OR the stream is exhausted. Handles 0xFF 0x00 stuffing.
    fn refill(self: *BitReader, min_bits: u5) void {
        while (self.bits_valid < min_bits and !self.marker_seen) {
            if (self.byte_pos >= self.data.len) return;
            const b = self.data[self.byte_pos];
            self.byte_pos += 1;
            if (b == 0xFF) {
                // Byte stuffing or marker. Need next byte to know.
                if (self.byte_pos >= self.data.len) {
                    // Dangling 0xFF at EOF: treat as marker-with-undefined-byte.
                    self.marker_seen = true;
                    self.marker_byte = 0;
                    return;
                }
                const next = self.data[self.byte_pos];
                self.byte_pos += 1;
                if (next == 0x00) {
                    // Stuffed literal 0xFF — push it as a payload byte.
                    self.buf |= (@as(u32, 0xFF) << @intCast(24 - self.bits_valid));
                    self.bits_valid += 8;
                } else {
                    // Real marker. Step the byte position back so the
                    // marker parser sees the 0xFF 0xNN pair.
                    self.byte_pos -= 2;
                    self.marker_seen = true;
                    self.marker_byte = next;
                    return;
                }
            } else {
                self.buf |= (@as(u32, b) << @intCast(24 - self.bits_valid));
                self.bits_valid += 8;
            }
        }
    }

    /// Look at the next `n` bits without consuming. n in 1..16.
    /// Returns 0-extended if fewer bits are available.
    pub fn peekBits(self: *BitReader, n: u5) u16 {
        std.debug.assert(n >= 1 and n <= 16);
        if (self.bits_valid < n) self.refill(n);
        // Top n bits of buf, right-aligned.
        return @intCast((self.buf >> @intCast(32 - @as(u6, n))) & ((@as(u32, 1) << n) - 1));
    }

    /// Consume `n` bits previously inspected via peekBits.
    pub fn consume(self: *BitReader, n: u5) void {
        std.debug.assert(n <= self.bits_valid);
        self.buf <<= @intCast(n);
        self.bits_valid -= n;
    }

    /// Read and consume `n` bits. Returns NotEnoughBits if a marker
    /// was hit before n bits could be assembled.
    pub fn readBits(self: *BitReader, n: u5) Error!u16 {
        std.debug.assert(n >= 1 and n <= 16);
        if (self.bits_valid < n) self.refill(n);
        if (self.bits_valid < n) return error.NotEnoughBits;
        const v = self.peekBits(n);
        self.consume(n);
        return v;
    }

    /// True if a non-stuffing marker terminated the entropy stream.
    pub fn markerHit(self: BitReader) bool {
        return self.marker_seen;
    }

    /// Byte offset of the 0xFF that started the terminating marker.
    /// Only valid after `markerHit() == true`.
    pub fn markerOffset(self: BitReader) usize {
        return self.byte_pos;
    }

    /// Reposition the reader just past a marker we've already seen
    /// (sets byte_pos forward by 2 to skip the FF Mm pair, clears the
    /// bit buffer, and resets marker_seen so subsequent reads can hit
    /// the next marker). Used by JPEG decoders to handle restart
    /// markers (RSTm) inline without re-creating the BitReader,
    /// which would lose absolute-offset tracking when the original
    /// data slice was sub-sliced earlier.
    pub fn skipPastMarker(self: *BitReader) void {
        std.debug.assert(self.marker_seen);
        self.byte_pos += 2;
        self.buf = 0;
        self.bits_valid = 0;
        self.marker_seen = false;
        self.marker_byte = 0;
    }

    /// Discard any padding bits in the bit buffer (per T.81 §F.1.2.3
    /// the encoder pads to byte boundary with 1-bits before emitting
    /// a restart marker), then peek at the next bytes in `data` to
    /// detect a marker. Used by JPEG decoders at MCU restart-interval
    /// boundaries: the previous MCU's last AC coefficient was decoded
    /// successfully and the bit buffer may still have unconsumed
    /// padding bits, so `marker_seen` hasn't fired via `refill()`. This
    /// method ensures the BitReader's marker_seen / marker_byte state
    /// reflects what's actually at byte_pos.
    pub fn seekToMarker(self: *BitReader) void {
        // Drop padding bits — at restart boundaries these are 1-bits
        // the encoder added to reach byte alignment before the marker.
        self.buf = 0;
        self.bits_valid = 0;
        // Advance past any leading 0xFF fill bytes (rare but legal).
        while (self.byte_pos < self.data.len and self.data[self.byte_pos] == 0xFF and
            self.byte_pos + 1 < self.data.len and self.data[self.byte_pos + 1] == 0xFF)
        {
            self.byte_pos += 1;
        }
        if (self.byte_pos + 1 >= self.data.len) {
            self.marker_seen = false;
            return;
        }
        if (self.data[self.byte_pos] == 0xFF and self.data[self.byte_pos + 1] != 0x00) {
            self.marker_seen = true;
            self.marker_byte = self.data[self.byte_pos + 1];
        } else {
            self.marker_seen = false;
        }
    }
};

// ── Tests ────────────────────────────────────────────────────

test "BitReader basic MSB-first" {
    // 0b10110100 0b11001010 → bits MSB first: 1,0,1,1,0,1,0,0,1,1,0,0,1,0,1,0
    const data = [_]u8{ 0b10110100, 0b11001010 };
    var r = BitReader.init(&data);
    try std.testing.expectEqual(@as(u16, 1), try r.readBits(1));
    try std.testing.expectEqual(@as(u16, 0), try r.readBits(1));
    try std.testing.expectEqual(@as(u16, 1), try r.readBits(1));
    try std.testing.expectEqual(@as(u16, 1), try r.readBits(1));
    try std.testing.expectEqual(@as(u16, 0b0100), try r.readBits(4));
    try std.testing.expectEqual(@as(u16, 0b11001010), try r.readBits(8));
}

test "BitReader 0xFF 0x00 byte stuffing yields literal 0xFF byte" {
    // 0xAA 0xFF 0x00 0xBB → stream sees 0xAA 0xFF 0xBB
    const data = [_]u8{ 0xAA, 0xFF, 0x00, 0xBB };
    var r = BitReader.init(&data);
    try std.testing.expectEqual(@as(u16, 0xAA), try r.readBits(8));
    try std.testing.expectEqual(@as(u16, 0xFF), try r.readBits(8));
    try std.testing.expectEqual(@as(u16, 0xBB), try r.readBits(8));
    try std.testing.expect(!r.markerHit());
}

test "BitReader stops on real marker (FF D9 = EOI)" {
    // 0x12 0xFF 0xD9 → reads 0x12, then marker hit (D9)
    const data = [_]u8{ 0x12, 0xFF, 0xD9 };
    var r = BitReader.init(&data);
    try std.testing.expectEqual(@as(u16, 0x12), try r.readBits(8));
    // Asking for more bits returns NotEnoughBits because the marker
    // terminated the scan; bit buffer is now empty.
    try std.testing.expectError(error.NotEnoughBits, r.readBits(1));
    try std.testing.expect(r.markerHit());
    try std.testing.expectEqual(@as(u8, 0xD9), r.marker_byte);
}

test "BitReader RST marker (FF D0) terminates scan; caller decides resume" {
    const data = [_]u8{ 0x55, 0xFF, 0xD0 };
    var r = BitReader.init(&data);
    try std.testing.expectEqual(@as(u16, 0x55), try r.readBits(8));
    try std.testing.expectError(error.NotEnoughBits, r.readBits(1));
    try std.testing.expect(r.markerHit());
    try std.testing.expectEqual(@as(u8, 0xD0), r.marker_byte);
}

test "BitReader exhaustion without marker" {
    const data = [_]u8{0x12};
    var r = BitReader.init(&data);
    _ = try r.readBits(8);
    try std.testing.expectError(error.NotEnoughBits, r.readBits(1));
    // No marker — just plain end of input.
    try std.testing.expect(!r.markerHit());
}

test "BitReader 16-bit peek across stuffing boundary" {
    // 0xFF 0x00 0xFF 0x00 → stream is 0xFF 0xFF
    const data = [_]u8{ 0xFF, 0x00, 0xFF, 0x00 };
    var r = BitReader.init(&data);
    try std.testing.expectEqual(@as(u16, 0xFFFF), r.peekBits(16));
    r.consume(16);
}
