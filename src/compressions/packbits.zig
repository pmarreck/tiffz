//! PackBits compression (TIFF compression=32773).
//!
//! Algorithm per TIFF 6.0 §9 / TTN1 (Apple-original):
//!
//! Loop over the compressed bytes:
//!   read header byte n as signed int8:
//!     n in [   0,  127]  → copy next n+1 bytes verbatim    (literal run)
//!     n in [-127,   -1]  → copy the next 1 byte 1-n times  (repeat run)
//!     n == -128          → no-op (skip; some encoders emit this as filler)
//!
//! Per the spec, runs do NOT cross row boundaries — each row is its
//! own packed stream. We don't actually need to know row boundaries
//! to decode (just produce the expected total byte count); but if the
//! compressed input is malformed or truncated, we surface an error
//! rather than guess.
//!
//! Caller passes in (compressed input, decompressed dest). We return
//! the number of bytes actually written, which the caller compares
//! against the expected uncompressed strip size.

const std = @import("std");

const errors = @import("tiffz-parser").errors;

/// Decode `src` (compressed PackBits bytes) into `dest`. Returns the
/// number of bytes written. Returns DestTooSmall if the stream
/// produces more output than dest can hold; SourceTooShort if a run
/// header references bytes past the end of `src`.
pub fn decode(src: []const u8, dest: []u8) errors.Error!usize {
    var i: usize = 0;
    var di: usize = 0;
    while (i < src.len) {
        const header: i8 = @bitCast(src[i]);
        i += 1;

        if (header == -128) continue; // no-op filler

        if (header >= 0) {
            // Literal run: copy next (header+1) bytes verbatim.
            const len: usize = @as(usize, @intCast(header)) + 1;
            if (i + len > src.len) return error.SourceTooShort;
            if (di + len > dest.len) return error.DestTooSmall;
            @memcpy(dest[di .. di + len], src[i .. i + len]);
            i += len;
            di += len;
        } else {
            // Repeat run: replicate next byte (1 - header) times.
            // header in [-127, -1], so 1 - header in [2, 128].
            const repeat: usize = @as(usize, @intCast(1 - @as(i32, header)));
            if (i >= src.len) return error.SourceTooShort;
            if (di + repeat > dest.len) return error.DestTooSmall;
            const byte = src[i];
            i += 1;
            @memset(dest[di .. di + repeat], byte);
            di += repeat;
        }
    }
    return di;
}

// ---- tests ----
//
// Synthetic roundtrips against the spec's worked examples. The
// reference encoded byte streams below are hand-verified against
// TIFF 6.0 §9 Figure 9 (the canonical PackBits example).

test "packbits.decode: TIFF 6.0 §9 worked example" {
    // From TIFF 6.0 spec page 42, the canonical PackBits example.
    // Original 24 bytes:
    //   AA AA AA 80 00 2A AA AA AA AA 80 00 2A 22 AA AA AA AA AA AA AA AA AA AA
    // Encoded 16 bytes:
    //   FE AA       → repeat byte 0xAA, count = 1 - (-2) = 3 → AA AA AA
    //   02 80 00 2A → literal 3 bytes → 80 00 2A
    //   FD AA       → repeat 0xAA, count = 1 - (-3) = 4 → AA AA AA AA
    //   03 80 00 2A 22 → literal 4 bytes → 80 00 2A 22
    //   F7 AA       → repeat 0xAA, count = 1 - (-9) = 10 → AA × 10
    const encoded = [_]u8{ 0xFE, 0xAA, 0x02, 0x80, 0x00, 0x2A, 0xFD, 0xAA, 0x03, 0x80, 0x00, 0x2A, 0x22, 0xF7, 0xAA };
    const expected = [_]u8{
        0xAA, 0xAA, 0xAA,                   // FE AA
        0x80, 0x00, 0x2A,                   // 02 + 3 literal
        0xAA, 0xAA, 0xAA, 0xAA,             // FD AA
        0x80, 0x00, 0x2A, 0x22,             // 03 + 4 literal
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA,       // F7 AA × 10
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
    };
    var dest: [32]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(expected.len, n);
    try std.testing.expectEqualSlices(u8, &expected, dest[0..n]);
}

test "packbits.decode: -128 no-op skips silently" {
    // 0x80 = -128 → no-op
    // 0x01 = +1  → copy next 2 literal bytes (header+1)
    // 0x01 0x02  → those 2 literal bytes
    const encoded = [_]u8{ 0x80, 0x01, 0x01, 0x02 };
    var dest: [4]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, dest[0..n]);
}

test "packbits.decode: literal run length boundary (header=0 → 1 byte)" {
    const encoded = [_]u8{ 0x00, 0xCD };
    var dest: [4]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0xCD), dest[0]);
}

test "packbits.decode: literal run length 128 (header=127 → 128 bytes)" {
    var encoded: [129]u8 = undefined;
    encoded[0] = 0x7F; // header = 127 → copy next 128 literal bytes
    for (encoded[1..], 0..) |*b, i| b.* = @intCast(i & 0xFF);
    var dest: [128]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 128), n);
    try std.testing.expectEqualSlices(u8, encoded[1..], dest[0..]);
}

test "packbits.decode: repeat run length 128 (header=-127 → 128 bytes)" {
    const encoded = [_]u8{ 0x81, 0x42 }; // 0x81 = -127; repeat = 1 - (-127) = 128
    var dest: [128]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 128), n);
    for (dest) |b| try std.testing.expectEqual(@as(u8, 0x42), b);
}

test "packbits.decode: literal run truncated at src boundary returns SourceTooShort" {
    const encoded = [_]u8{ 0x05, 0x01, 0x02 }; // claims 6 literal bytes, only 2 follow
    var dest: [16]u8 = undefined;
    try std.testing.expectError(error.SourceTooShort, decode(&encoded, &dest));
}

test "packbits.decode: repeat run with no payload byte returns SourceTooShort" {
    const encoded = [_]u8{0xFE}; // header alone, no byte to repeat
    var dest: [16]u8 = undefined;
    try std.testing.expectError(error.SourceTooShort, decode(&encoded, &dest));
}

test "packbits.decode: dest overflow on literal run returns DestTooSmall" {
    const encoded = [_]u8{ 0x03, 0x01, 0x02, 0x03, 0x04 };
    var dest: [2]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, decode(&encoded, &dest));
}

test "packbits.decode: dest overflow on repeat run returns DestTooSmall" {
    const encoded = [_]u8{ 0xF7, 0xAA }; // 10 × 0xAA
    var dest: [4]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, decode(&encoded, &dest));
}

test "packbits.decode: empty input produces empty output" {
    const encoded = [_]u8{};
    var dest: [4]u8 = undefined;
    const n = try decode(&encoded, &dest);
    try std.testing.expectEqual(@as(usize, 0), n);
}
