//! The Decoder primitive: random-access TIFF decode engine. All four
//! access patterns (validate / pipeline / random / eager) build on
//! this. See `docs/superpowers/specs/2026-05-04-tiffz-api-design.md`.
//!
//! M3: uncompressed strip-based decode for classic TIFF. open() parses
//! the file header and IFD0 (lazy IFD chain — siblings parsed on
//! demand). decodeStrip() handles compression=1 (none) — copies the
//! on-disk strip bytes verbatim into dest. Other compressions, tile
//! layout, and photometric expansion land in later milestones.

const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("errors.zig");
const Limits = @import("limits.zig").Limits;
const Source = @import("source.zig").Source;
const Workspace = @import("workspace.zig").Workspace;
const header_mod = @import("header.zig");
const Endian = header_mod.Endian;
const ifd_mod = @import("ifd.zig");
const Ifd = ifd_mod.Ifd;
const tags = @import("tags.zig");

pub const Decoder = struct {
    allocator: Allocator,
    source: Source,
    limits: Limits,
    endian: Endian,
    bigtiff: bool,
    /// IFD chain. We populate IFD0 eagerly in open(); siblings are
    /// resolved on demand by ifd().
    ifds: std.ArrayListUnmanaged(Ifd),
    /// Offset of the next-IFD pointer for the last IFD we've parsed
    /// — 0 if we've reached the end of the chain.
    next_ifd_offset: u64,

    pub fn open(allocator: Allocator, source: Source) errors.Error!Decoder {
        return openWithLimits(allocator, source, .{});
    }

    pub fn openWithLimits(
        allocator: Allocator,
        source: Source,
        limits: Limits,
    ) errors.Error!Decoder {
        const h = try header_mod.parse(source);
        if (h.bigtiff) return error.UnsupportedTagType; // M7

        var ifds: std.ArrayListUnmanaged(Ifd) = .{};
        errdefer ifds.deinit(allocator);

        var ifd0 = try ifd_mod.parse(allocator, source, h.endian, h.ifd0_offset, limits);
        errdefer ifd0.deinit();
        ifds.append(allocator, ifd0) catch return error.OutOfMemory;

        return .{
            .allocator = allocator,
            .source = source,
            .limits = limits,
            .endian = h.endian,
            .bigtiff = h.bigtiff,
            .ifds = ifds,
            .next_ifd_offset = ifd0.next_offset,
        };
    }

    pub fn deinit(self: *Decoder) void {
        for (self.ifds.items) |*i| i.deinit();
        self.ifds.deinit(self.allocator);
    }

    pub fn ifdCount(self: *const Decoder) usize {
        return self.ifds.items.len;
    }

    /// Get an IFD by index. Lazily walks the chain to materialize
    /// IFDs we haven't parsed yet (so a consumer that only ever
    /// touches IFD0 pays nothing for trailing IFDs).
    pub fn ifd(self: *Decoder, index: usize) errors.Error!*const Ifd {
        while (index >= self.ifds.items.len) {
            if (self.next_ifd_offset == 0) return error.InvalidArgument;
            if (self.ifds.items.len >= self.limits.max_ifds) {
                return error.LimitExceededIfdCount;
            }
            var next = try ifd_mod.parse(
                self.allocator,
                self.source,
                self.endian,
                self.next_ifd_offset,
                self.limits,
            );
            errdefer next.deinit();
            self.ifds.append(self.allocator, next) catch return error.OutOfMemory;
            self.next_ifd_offset = next.next_offset;
        }
        return &self.ifds.items[index];
    }

    /// Decode one strip into dest. M3 supports compression=1 (none)
    /// only — strip bytes are copied verbatim from the source. Tiled
    /// layout is M6; other compressions are M4+; photometric
    /// expansion is the consumer's job (raw bytes returned here).
    pub fn decodeStrip(
        self: *Decoder,
        ifd_index: usize,
        strip_index: u32,
        dest: []u8,
    ) errors.Error!usize {
        const dir = try self.ifd(ifd_index);

        // Reject tiled layout — has TileOffsets/TileWidth/TileLength,
        // no StripOffsets. M6 implements decodeTile.
        if (dir.get(tags.tile_offsets) != null) return error.UnsupportedTagType;

        // Compression must be 1 (none) for M3.
        const comp = (try readScalarU16(dir.*, tags.compression, self.endian)) orelse 1;
        if (comp != tags.compression_none) return error.UnsupportedCompression;

        // Read the strip metadata arrays.
        const offsets_entry = dir.get(tags.strip_offsets) orelse return error.Malformed;
        const counts_entry = dir.get(tags.strip_byte_counts) orelse return error.Malformed;

        if (strip_index >= offsets_entry.count or strip_index >= counts_entry.count) {
            return error.InvalidArgument;
        }
        if (offsets_entry.count > self.limits.max_strips_or_tiles) {
            return error.LimitExceededStripCount;
        }

        // StripOffsets and StripByteCounts can be SHORT or LONG per
        // TIFF 6.0; we accept either.
        const offset = try readArrayElementU32(
            offsets_entry.*,
            strip_index,
            self.endian,
            self.source,
            self.allocator,
        );
        const byte_count = try readArrayElementU32(
            counts_entry.*,
            strip_index,
            self.endian,
            self.source,
            self.allocator,
        );

        if (byte_count > self.limits.max_compressed_strip_bytes) {
            return error.LimitExceededCompressedStripBytes;
        }
        if (byte_count > self.limits.max_decompressed_strip_bytes) {
            // For uncompressed, decompressed == compressed.
            return error.LimitExceededDecompressedStripBytes;
        }
        if (byte_count > dest.len) return error.DestTooSmall;

        const n = self.source.readAt(dest[0..byte_count], offset) catch return error.Io;
        if (n < byte_count) return error.SourceShortRead;
        return n;
    }
};

/// Read a single u16-shaped scalar tag (BitsPerSample / Compression /
/// Photometric / etc.). Returns null if the tag isn't present.
/// Single-element scalars always fit inline — no Source read needed.
fn readScalarU16(dir: Ifd, tag: u16, endian: Endian) errors.Error!?u16 {
    const e = dir.get(tag) orelse return null;
    if (e.count != 1) return error.Malformed;
    if (e.field_type != .short) {
        // Some encoders stuff Compression into a LONG; tolerate it.
        if (e.field_type == .long) {
            const v32 = header_mod.readU32(&e.raw_value_or_offset, endian);
            if (v32 > std.math.maxInt(u16)) return error.Malformed;
            return @intCast(v32);
        }
        return error.UnsupportedTagType;
    }
    return header_mod.readU16(e.raw_value_or_offset[0..2], endian);
}

/// Read element [index] from a SHORT-or-LONG array tag, widened to u32.
/// StripOffsets/StripByteCounts use this shape — TIFF 6.0 lets writers
/// use either type. Per-IFD-entry type, not per-element.
fn readArrayElementU32(
    entry: ifd_mod.Entry,
    index: u32,
    endian: Endian,
    source: Source,
    allocator: Allocator,
) errors.Error!u32 {
    if (index >= entry.count) return error.InvalidArgument;

    const total_bytes = Ifd.entryValueBytes(entry);
    // For inline-fitting arrays (count×elem ≤ 4), values are in
    // raw_value_or_offset directly. For larger arrays, read from
    // the source via the offset stored there.
    if (total_bytes <= 4) {
        return readArrayInline(entry, index, endian);
    }

    // Out of line — read just the element we need (single element pread).
    const elem_bytes = entry.field_type.elementBytes();
    if (elem_bytes == 0) return error.UnsupportedTagType;
    const offset: u64 = header_mod.readU32(&entry.raw_value_or_offset, endian);
    const elem_offset = offset + @as(u64, index) * @as(u64, elem_bytes);

    var buf: [4]u8 = undefined;
    const need: usize = elem_bytes;
    if (need > buf.len) return error.UnsupportedTagType;
    const got = source.readAt(buf[0..need], elem_offset) catch return error.Io;
    if (got < need) return error.SourceShortRead;
    _ = allocator; // not needed for single-element pread

    return switch (entry.field_type) {
        .short => @intCast(header_mod.readU16(buf[0..2], endian)),
        .long => header_mod.readU32(buf[0..4], endian),
        else => error.UnsupportedTagType,
    };
}

fn readArrayInline(entry: ifd_mod.Entry, index: u32, endian: Endian) errors.Error!u32 {
    return switch (entry.field_type) {
        .short => blk: {
            const start: usize = @as(usize, index) * 2;
            if (start + 2 > 4) return error.Malformed;
            break :blk @intCast(header_mod.readU16(entry.raw_value_or_offset[start..][0..2], endian));
        },
        .long => blk: {
            if (entry.count != 1) return error.Malformed; // only one LONG fits inline
            break :blk header_mod.readU32(&entry.raw_value_or_offset, endian);
        },
        else => error.UnsupportedTagType,
    };
}

// ---- tests ----

const BufferHandle = @import("source.zig").BufferHandle;

/// Build a minimal LE classic TIFF with one IFD containing the
/// listed entries plus an inline strip. Returns the full byte stream.
/// Layout: header (8) + IFD0 (2 + 12*N + 4) + strip bytes.
fn synthesize(comptime entries_count: comptime_int, ifd_entries: [entries_count][12]u8, strip: []const u8, comptime strip_offset: u32) [256]u8 {
    var out: [256]u8 = .{0} ** 256;
    out[0] = 'I';
    out[1] = 'I';
    out[2] = 0x2A;
    out[3] = 0x00;
    out[4] = 0x08;
    out[5] = 0x00;
    out[6] = 0x00;
    out[7] = 0x00;
    out[8] = @intCast(entries_count & 0xFF);
    out[9] = @intCast((entries_count >> 8) & 0xFF);
    inline for (ifd_entries, 0..) |e, i| {
        @memcpy(out[10 + i * 12 ..][0..12], &e);
    }
    @memcpy(out[strip_offset..][0..strip.len], strip);
    return out;
}

test "decodeStrip: uncompressed RGB single strip" {
    // 2x2 RGB image, photometric=2, compression=1, 1 strip of 12 bytes.
    // Strip bytes at offset 0x60.
    const w_entry: [12]u8 = .{ 0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }; // ImageWidth = 2 (SHORT)
    const h_entry: [12]u8 = .{ 0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }; // ImageLength = 2
    const bps_entry: [12]u8 = .{ 0x02, 0x01, 0x03, 0x00, 0x03, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00 }; // BitsPerSample = 3*SHORT @ offset 0x80
    const comp_entry: [12]u8 = .{ 0x03, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }; // Compression = 1
    const photo_entry: [12]u8 = .{ 0x06, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }; // PhotoInterp = 2 (RGB)
    const so_entry: [12]u8 = .{ 0x11, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00 }; // StripOffsets = 0x80 (LONG, count=1, inline)
    const spp_entry: [12]u8 = .{ 0x15, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00 }; // SamplesPerPixel = 3
    const rps_entry: [12]u8 = .{ 0x16, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }; // RowsPerStrip = 2
    const sbc_entry: [12]u8 = .{ 0x17, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00 }; // StripByteCounts = 12

    const strip = [_]u8{
        0xFF, 0x00, 0x00, // pixel 0,0 — red
        0x00, 0xFF, 0x00, // pixel 0,1 — green
        0x00, 0x00, 0xFF, // pixel 1,0 — blue
        0xFF, 0xFF, 0x00, // pixel 1,1 — yellow
    };

    const bytes = synthesize(9, .{ w_entry, h_entry, bps_entry, comp_entry, photo_entry, so_entry, spp_entry, rps_entry, sbc_entry }, &strip, 0x80);

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();

    try std.testing.expectEqual(@as(usize, 1), dec.ifdCount());

    var dest: [12]u8 = undefined;
    const n = try dec.decodeStrip(0, 0, &dest);
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqualSlices(u8, &strip, dest[0..12]);
}

test "decodeStrip: compression=2 rejected as Unsupported" {
    const w_entry: [12]u8 = .{ 0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 };
    const h_entry: [12]u8 = .{ 0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 };
    const comp_entry: [12]u8 = .{ 0x03, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00 }; // Compression = 5 (LZW)
    const so_entry: [12]u8 = .{ 0x11, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, 0x00 };
    const sbc_entry: [12]u8 = .{ 0x17, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00 };

    const strip = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const bytes = synthesize(5, .{ w_entry, h_entry, comp_entry, so_entry, sbc_entry }, &strip, 0x60);

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();

    var dest: [4]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedCompression,
        dec.decodeStrip(0, 0, &dest),
    );
}

test "Decoder type compiles" {
    _ = Decoder;
}
