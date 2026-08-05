//! DNG (Digital Negative) auxiliary metadata parsers (M8).
//!
//! tiffz only parses these structures — it does not act on them. The
//! consumer (validate, raw-pipeline tools, etc.) is responsible for
//! demosaicing the CFA mosaic and executing the opcode list.
//!
//! Coverage:
//!   - CFA pattern (33421/33422) — Bayer / X-Trans / etc. mosaic.
//!   - OpcodeList1/2/3 (51008/51009/51022) — Adobe opcode bytecode.
//!
//! Per DNG spec §10, the opcode list datastream is ALWAYS big-endian
//! regardless of the host TIFF's byte order. CFA pattern data follows
//! the IFD's byte order (it's stored as normal TIFF SHORT/BYTE values).

const std = @import("std");

const parser = @import("tiffz-parser");
const errors = parser.errors;
const header_mod = parser.header;
const Endian = header_mod.Endian;

/// Color-filter-array mosaic pattern from CFARepeatPatternDim (33421)
/// + CFAPattern (33422). Pattern values:
///   0 = Red, 1 = Green, 2 = Blue, 3 = Cyan, 4 = Magenta,
///   5 = Yellow, 6 = White.
/// `pattern` is a borrow into the caller-supplied bytes (zero-copy).
pub const CfaPattern = struct {
    repeat_dim_x: u16,
    repeat_dim_y: u16,
    pattern: []const u8,
};

/// Parse the (CFARepeatPatternDim, CFAPattern) pair from raw IFD entry
/// bytes. `repeat_dim_bytes` is the 4-byte buffer of the dim tag (two
/// SHORT values in IFD byte order). `pattern_bytes` is the value buffer
/// of the pattern tag; we slice the first `dim_x * dim_y` bytes.
pub fn parseCfaPattern(
    repeat_dim_bytes: []const u8,
    pattern_bytes: []const u8,
    ifd_endian: Endian,
) errors.Error!CfaPattern {
    if (repeat_dim_bytes.len < 4) return error.Malformed;
    const std_endian: std.builtin.Endian = if (ifd_endian == .little) .little else .big;
    const dim_x = std.mem.readInt(u16, repeat_dim_bytes[0..2], std_endian);
    const dim_y = std.mem.readInt(u16, repeat_dim_bytes[2..4], std_endian);
    if (dim_x == 0 or dim_y == 0) return error.Malformed;
    const need: usize = @as(usize, dim_x) * @as(usize, dim_y);
    if (pattern_bytes.len < need) return error.Malformed;
    return .{
        .repeat_dim_x = dim_x,
        .repeat_dim_y = dim_y,
        .pattern = pattern_bytes[0..need],
    };
}

/// A single opcode from an OpcodeList. `parameters` is a borrow into
/// the caller-supplied datastream (no copy). The bytes inside
/// `parameters` are big-endian per-opcode-defined fields; tiffz
/// leaves them unparsed for downstream consumers.
pub const Opcode = struct {
    opcode_id: u32,
    /// Minimum DNG version that defines this opcode (e.g. 0x01030000
    /// for DNG 1.3.0.0).
    dng_version: u32,
    /// Bit 0: "optional" — readers may skip if unsupported.
    /// Bit 1: "matrix follows" — see DNG spec for opcodes that mark
    /// successive opcodes as conditional.
    flags: u32,
    parameters: []const u8,
};

/// Parsed view of an OpcodeList. `opcodes` is heap-allocated from
/// the parser's allocator; the parameter byte slices reference the
/// original input datastream. Call `deinit` to release the spine.
pub const OpcodeList = struct {
    opcodes: []Opcode,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OpcodeList) void {
        self.allocator.free(self.opcodes);
        self.* = undefined;
    }
};

/// Maximum opcodes we'll parse from one list before treating the input
/// as malformed. DNG 1.7's full op table has ~30 entries; even a very
/// busy raw chain stays well under 100. A hard cap of 1_000_000 here
/// is generous and only exists to bound allocation on adversarial
/// inputs (e.g. a corrupted count field of 0xFFFFFFFF).
pub const max_opcodes: u32 = 1_000_000;

/// Parse an OpcodeList datastream per DNG spec §10.1. Big-endian
/// throughout, regardless of the host TIFF's byte order.
///
/// The list spine (struct array) is allocated; opcode parameter byte
/// ranges are borrowed slices into `bytes`.
pub fn parseOpcodeList(
    bytes: []const u8,
    allocator: std.mem.Allocator,
) errors.Error!OpcodeList {
    if (bytes.len < 4) return error.Malformed;
    const count = std.mem.readInt(u32, bytes[0..4], .big);
    if (count > max_opcodes) return error.Malformed;

    const opcodes = allocator.alloc(Opcode, count) catch return error.OutOfMemory;
    errdefer allocator.free(opcodes);

    var offset: usize = 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // Each opcode header is 16 bytes: id, dng_version, flags,
        // parameter_size — all u32 big-endian.
        if (bytes.len < offset + 16) return error.Malformed;
        const opcode_id = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const dng_version = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .big);
        const flags = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .big);
        const param_size = std.mem.readInt(u32, bytes[offset + 12 ..][0..4], .big);
        offset += 16;
        if (bytes.len < offset + param_size) return error.Malformed;
        opcodes[i] = .{
            .opcode_id = opcode_id,
            .dng_version = dng_version,
            .flags = flags,
            .parameters = bytes[offset .. offset + param_size],
        };
        offset += param_size;
    }

    return .{ .opcodes = opcodes, .allocator = allocator };
}

// ---- tests ----

test "dng.parseCfaPattern: 2x2 Bayer GRBG, big-endian IFD" {
    // CFARepeatPatternDim = (2, 2) — two SHORTs in big-endian.
    const dim_bytes = [_]u8{ 0x00, 0x02, 0x00, 0x02 };
    // CFAPattern = G(1) R(0) B(2) G(1) — 2x2 GRBG Bayer.
    const pat_bytes = [_]u8{ 1, 0, 2, 1 };
    const cfa = try parseCfaPattern(&dim_bytes, &pat_bytes, .big);
    try std.testing.expectEqual(@as(u16, 2), cfa.repeat_dim_x);
    try std.testing.expectEqual(@as(u16, 2), cfa.repeat_dim_y);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 1 }, cfa.pattern);
}

test "dng.parseCfaPattern: 6x6 X-Trans, little-endian IFD" {
    // 6x6 = 36 sample positions. Pattern is one of Fuji's X-Trans
    // layouts (G dominates with no axis-aligned regularity).
    const dim_bytes = [_]u8{ 0x06, 0x00, 0x06, 0x00 }; // (6, 6) little-endian
    const pat_bytes = [_]u8{
        1, 1, 0, 1, 1, 2,
        1, 1, 2, 1, 1, 0,
        2, 0, 1, 0, 2, 1,
        1, 1, 2, 1, 1, 0,
        1, 1, 0, 1, 1, 2,
        0, 2, 1, 2, 0, 1,
    };
    const cfa = try parseCfaPattern(&dim_bytes, &pat_bytes, .little);
    try std.testing.expectEqual(@as(u16, 6), cfa.repeat_dim_x);
    try std.testing.expectEqual(@as(u16, 6), cfa.repeat_dim_y);
    try std.testing.expectEqual(@as(usize, 36), cfa.pattern.len);
}

test "dng.parseCfaPattern: rejects dim=0" {
    const dim_bytes = [_]u8{ 0x00, 0x00, 0x00, 0x02 };
    const pat_bytes = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.Malformed, parseCfaPattern(&dim_bytes, &pat_bytes, .big));
}

test "dng.parseCfaPattern: rejects short pattern buffer" {
    const dim_bytes = [_]u8{ 0x00, 0x03, 0x00, 0x03 }; // 9 samples
    const pat_bytes = [_]u8{ 0, 1, 2, 0 }; // only 4 supplied
    try std.testing.expectError(error.Malformed, parseCfaPattern(&dim_bytes, &pat_bytes, .big));
}

test "dng.parseOpcodeList: single opcode with parameters" {
    // count=1, then one opcode { id=1, ver=0x01030000, flags=0, size=4, params=[0xAA,0xBB,0xCC,0xDD] }
    const bytes = [_]u8{
        // count (BE)
        0x00, 0x00, 0x00, 0x01,
        // opcode_id
        0x00, 0x00, 0x00, 0x01,
        // dng_version = 0x01030000 (DNG 1.3.0.0)
        0x01, 0x03, 0x00, 0x00,
        // flags
        0x00, 0x00, 0x00, 0x00,
        // parameter_size
        0x00, 0x00, 0x00, 0x04,
        // parameters
        0xAA, 0xBB, 0xCC, 0xDD,
    };
    var list = try parseOpcodeList(&bytes, std.testing.allocator);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), list.opcodes.len);
    try std.testing.expectEqual(@as(u32, 1), list.opcodes[0].opcode_id);
    try std.testing.expectEqual(@as(u32, 0x01030000), list.opcodes[0].dng_version);
    try std.testing.expectEqual(@as(u32, 0), list.opcodes[0].flags);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC, 0xDD }, list.opcodes[0].parameters);
}

test "dng.parseOpcodeList: two opcodes with mixed payload sizes" {
    const bytes = [_]u8{
        // count = 2
        0x00, 0x00, 0x00, 0x02,
        // opcode 1: id=1, ver=0x01030000, flags=0, size=0
        0x00, 0x00, 0x00, 0x01,
        0x01, 0x03, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        // opcode 2: id=2, ver=0x01040000, flags=1 (optional), size=2
        0x00, 0x00, 0x00, 0x02,
        0x01, 0x04, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x02,
        // opcode 2 params
        0x11, 0x22,
    };
    var list = try parseOpcodeList(&bytes, std.testing.allocator);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.opcodes.len);
    try std.testing.expectEqual(@as(u32, 1), list.opcodes[0].opcode_id);
    try std.testing.expectEqual(@as(usize, 0), list.opcodes[0].parameters.len);
    try std.testing.expectEqual(@as(u32, 2), list.opcodes[1].opcode_id);
    try std.testing.expectEqual(@as(u32, 1), list.opcodes[1].flags);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22 }, list.opcodes[1].parameters);
}

test "dng.parseOpcodeList: empty list (count=0)" {
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    var list = try parseOpcodeList(&bytes, std.testing.allocator);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 0), list.opcodes.len);
}

test "dng.parseOpcodeList: rejects truncated opcode header" {
    // count=1 but only 8 bytes for the opcode header (needs 16).
    const bytes = [_]u8{
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x01,
        0x01, 0x03, 0x00, 0x00,
    };
    try std.testing.expectError(error.Malformed, parseOpcodeList(&bytes, std.testing.allocator));
}

test "dng.parseOpcodeList: rejects truncated parameters" {
    // count=1, opcode declares param_size=8 but only 4 bytes follow.
    const bytes = [_]u8{
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x01,
        0x01, 0x03, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x08,
        0xAA, 0xBB, 0xCC, 0xDD,
    };
    try std.testing.expectError(error.Malformed, parseOpcodeList(&bytes, std.testing.allocator));
}

test "dng.parseOpcodeList: rejects implausibly large opcode count" {
    const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    try std.testing.expectError(error.Malformed, parseOpcodeList(&bytes, std.testing.allocator));
}
