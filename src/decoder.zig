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
const compressions_none = @import("compressions/none.zig");
const compressions_packbits = @import("compressions/packbits.zig");
const compressions_lzw = @import("compressions/lzw.zig");
const compressions_deflate = @import("compressions/deflate.zig");
const compressions_ccitt_t4 = @import("compressions/ccitt_t4.zig");

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

    /// Decode one strip into dest. Dispatches on the IFD's
    /// Compression tag:
    ///   1     (none)     — bytes copied verbatim from source
    ///   32773 (PackBits) — TIFF 6.0 §9 RLE
    ///   others           — UnsupportedCompression for now (M4+)
    ///
    /// Tiled layout is M6; photometric expansion is the consumer's
    /// job (raw decoded bytes are returned here).
    pub fn decodeStrip(
        self: *Decoder,
        ifd_index: usize,
        strip_index: u32,
        dest: []u8,
        workspace: *Workspace,
    ) errors.Error!usize {
        const dir = try self.ifd(ifd_index);

        // Reject tiled layout — has TileOffsets/TileWidth/TileLength,
        // no StripOffsets. M6 implements decodeTile.
        if (dir.get(tags.tile_offsets) != null) return error.UnsupportedTagType;

        const comp = (try readScalarU16(dir.*, tags.compression, self.endian)) orelse 1;

        // Read the strip metadata arrays. Both can be SHORT or LONG.
        const offsets_entry = dir.get(tags.strip_offsets) orelse return error.Malformed;
        const counts_entry = dir.get(tags.strip_byte_counts) orelse return error.Malformed;

        if (strip_index >= offsets_entry.count or strip_index >= counts_entry.count) {
            return error.InvalidArgument;
        }
        if (offsets_entry.count > self.limits.max_strips_or_tiles) {
            return error.LimitExceededStripCount;
        }

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

        return switch (comp) {
            tags.compression_none => blk: {
                if (byte_count > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk compressions_none.decode(self.source, offset, byte_count, dest);
            },
            tags.compression_packbits => blk: {
                // PackBits: read compressed strip bytes into workspace
                // scratch, then expand into dest.
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = compressions_packbits.decode(scratch, dest) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_lzw => blk: {
                // LZW: try TIFF 6.0 new-style first; if Malformed,
                // retry with old-style (Adobe/Sun original timing,
                // common in 1990s TIFF writers — libtiff's
                // "Old-style LZW codes" warning territory).
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = if (compressions_lzw.decodeVariant(scratch, dest, .new_style)) |n| n else |first_err| switch (first_err) {
                    error.Malformed => compressions_lzw.decodeVariant(scratch, dest, .old_style) catch |e| break :blk e,
                    else => break :blk first_err,
                };
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_ccitt_t4 => blk: {
                // CCITT G3 (T.4) 1D modified Huffman. Read T4Options
                // (default 0 = 1D non-byte-aligned) and FillOrder
                // (default 1 = MSB-first). Reject 2D mode for now —
                // M4-E (CCITT G4 / T.6) shares the 2D state machine
                // and that's where 2D lands.
                const t4_opts: u32 = (try readScalarU32(dir.*, tags.t4_options, self.endian)) orelse 0;
                if ((t4_opts & 0x1) != 0) break :blk error.UnsupportedCompression; // 2D
                if ((t4_opts & 0x2) != 0) break :blk error.UnsupportedCompression; // uncompressed mode
                const eol_byte_align: bool = (t4_opts & 0x4) != 0;

                const fill_raw = (try readScalarU16(dir.*, tags.fill_order, self.endian)) orelse 1;
                const fill: compressions_ccitt_t4.FillOrder = switch (fill_raw) {
                    1 => .msb_first,
                    2 => .lsb_first,
                    else => break :blk error.Malformed,
                };

                const width = (try readScalarU32(dir.*, tags.image_width, self.endian)) orelse {
                    break :blk error.Malformed;
                };
                const length = (try readScalarU32(dir.*, tags.image_length, self.endian)) orelse {
                    break :blk error.Malformed;
                };
                const rps_raw = (try readScalarU32(dir.*, tags.rows_per_strip, self.endian)) orelse length;
                // RowsPerStrip = (uint32) -1 means "all rows in one strip" for fax.
                const rps: u32 = if (rps_raw > length) length else rps_raw;
                const remaining_rows: u32 = length - strip_index * rps;
                const this_rows: u32 = @min(rps, remaining_rows);

                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;

                const written = compressions_ccitt_t4.decode(
                    scratch,
                    dest,
                    width,
                    this_rows,
                    fill,
                    eol_byte_align,
                ) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_deflate, tags.compression_deflate_adobe => blk: {
                // Deflate / AdobeDeflate (compression=8 / 32946): zlib-
                // framed stream. Both codes mean the same on-disk format
                // per TIFF Technical Note 2; AdobeDeflate is just a
                // separate registration.
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = compressions_deflate.decode(scratch, dest) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            else => error.UnsupportedCompression,
        };
    }
};

/// Read a single u32-shaped scalar tag (ImageWidth / ImageLength /
/// RowsPerStrip / etc.). Tolerates SHORT-typed encoders too.
/// Returns null if the tag isn't present.
fn readScalarU32(dir: Ifd, tag: u16, endian: Endian) errors.Error!?u32 {
    const e = dir.get(tag) orelse return null;
    if (e.count != 1) return error.Malformed;
    return switch (e.field_type) {
        .short => @intCast(header_mod.readU16(e.raw_value_or_offset[0..2], endian)),
        .long => header_mod.readU32(&e.raw_value_or_offset, endian),
        else => error.UnsupportedTagType,
    };
}

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

    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();

    var dest: [12]u8 = undefined;
    const n = try dec.decodeStrip(0, 0, &dest, &ws);
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqualSlices(u8, &strip, dest[0..12]);
}

test "decodeStrip: compression=4 (CCITT G4, M4-E) rejected as Unsupported" {
    const w_entry: [12]u8 = .{ 0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 };
    const h_entry: [12]u8 = .{ 0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 };
    const comp_entry: [12]u8 = .{ 0x03, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00 }; // Compression = 4 (CCITT G4, not yet supported)
    const so_entry: [12]u8 = .{ 0x11, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, 0x00 };
    const sbc_entry: [12]u8 = .{ 0x17, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00 };

    const strip = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const bytes = synthesize(5, .{ w_entry, h_entry, comp_entry, so_entry, sbc_entry }, &strip, 0x60);

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();

    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();

    var dest: [4]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedCompression,
        dec.decodeStrip(0, 0, &dest, &ws),
    );
}

test "Decoder type compiles" {
    _ = Decoder;
}
