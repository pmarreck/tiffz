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
const lzwz = @import("lzwz");
const compressions_deflate = @import("compressions/deflate.zig");
const compressions_ccitt_t4 = @import("compressions/ccitt_t4.zig");
const compressions_ccitt_t6 = @import("compressions/ccitt_t6.zig");
const compressions_jpeg = @import("compressions/jpeg.zig");
const compressions_zstd = @import("compressions/zstd.zig");
const compressions_lerc = @import("compressions/lerc.zig");
const predictors_mod = @import("predictors.zig");
const findings_mod = @import("findings.zig");

pub const Decoder = struct {
    allocator: Allocator,
    source: Source,
    limits: Limits,
    endian: Endian,
    bigtiff: bool,
    /// IFD chain. We populate IFD0 eagerly in open(); siblings are
    /// resolved on demand by ifd().
    ifds: std.ArrayListUnmanaged(Ifd),
    /// File offsets each IFD in `ifds` was parsed from. Parallel to
    /// `ifds.items`. Used for cycle detection: before parsing the
    /// next IFD we check `next_ifd_offset` against this list; a
    /// repeat means the chain loops back on itself (malformed file
    /// defense — TIFF spec doesn't permit cycles).
    ifd_offsets: std.ArrayListUnmanaged(u64),
    /// Offset of the next-IFD pointer for the last IFD we've parsed
    /// — 0 if we've reached the end of the chain.
    next_ifd_offset: u64,
    /// Optional callback for INFO findings emitted during decode.
    /// See `src/findings.zig` for the per-finding payload semantics.
    finding_cb: findings_mod.Callback = null,
    finding_userdata: ?*anyopaque = null,
    /// One-shot flag for `old_style_lzw_codes` — LZW falls back from
    /// new-style to old-style per strip on malformed streams; surface
    /// the file-level compatibility fact only once.
    lzw_old_style_fired: bool = false,

    pub fn open(allocator: Allocator, source: Source) errors.Error!Decoder {
        return openWithLimits(allocator, source, .{});
    }

    pub fn openWithLimits(
        allocator: Allocator,
        source: Source,
        limits: Limits,
    ) errors.Error!Decoder {
        const h = try header_mod.parse(source);
        const offset_width: ifd_mod.OffsetWidth = if (h.bigtiff) .big else .classic;

        var ifds: std.ArrayListUnmanaged(Ifd) = .empty;
        errdefer ifds.deinit(allocator);

        var ifd_offsets: std.ArrayListUnmanaged(u64) = .empty;
        errdefer ifd_offsets.deinit(allocator);

        var ifd0 = try ifd_mod.parse(allocator, source, h.endian, h.ifd0_offset, limits, offset_width);
        errdefer ifd0.deinit();
        ifds.append(allocator, ifd0) catch return error.OutOfMemory;
        ifd_offsets.append(allocator, h.ifd0_offset) catch return error.OutOfMemory;

        return .{
            .allocator = allocator,
            .source = source,
            .limits = limits,
            .endian = h.endian,
            .bigtiff = h.bigtiff,
            .ifds = ifds,
            .ifd_offsets = ifd_offsets,
            .next_ifd_offset = ifd0.next_offset,
        };
    }

    /// Install a callback for INFO findings emitted during decode.
    /// `cb` may be null to clear. `userdata` is passed through as-is
    /// to each invocation. Thread safety: the callback fires from
    /// whatever thread calls the decode method that detected the
    /// finding; tiffz itself is single-threaded so the callback
    /// inherits the caller's thread context.
    ///
    /// Call this AFTER `Decoder.open` but BEFORE the first IFD walk
    /// or strip decode to receive all findings. Findings detected at
    /// IFD parse time on IFD 0 fire on the next call to `ifd(0)` or
    /// when `scanFindings()` is invoked explicitly.
    pub fn setFindingCallback(
        self: *Decoder,
        cb: findings_mod.Callback,
        userdata: ?*anyopaque,
    ) void {
        self.finding_cb = cb;
        self.finding_userdata = userdata;
    }

    /// Re-scan all materialized IFDs and emit findings via the
    /// installed callback. No-op if no callback is set. Useful when
    /// the callback is installed AFTER `open()` but the caller still
    /// wants findings for the eagerly-parsed IFD 0.
    pub fn scanFindings(self: *Decoder) void {
        if (self.finding_cb == null) return;
        if (self.bigtiff) self.emit(.bigtiff_format, &.{});
        for (self.ifds.items, 0..) |*dir, i| {
            self.scanIfdForFindings(dir, i);
        }
    }

    fn emit(self: *Decoder, finding: findings_mod.InfoFinding, payload: []const u8) void {
        const cb = self.finding_cb orelse return;
        cb(
            self.finding_userdata,
            @intCast(@intFromEnum(finding)),
            if (payload.len > 0) payload.ptr else null,
            payload.len,
        );
    }

    fn emitU32(self: *Decoder, finding: findings_mod.InfoFinding, value: u32) void {
        if (self.finding_cb == null) return;
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        self.emit(finding, &buf);
    }

    /// Scan a single IFD for tag-driven INFO findings and emit each
    /// one observed. Called after every IFD parse (initial + on-
    /// demand chain walks). Errors during scanning are swallowed —
    /// findings emission is best-effort and never blocks the decode
    /// path.
    fn scanIfdForFindings(self: *Decoder, dir: *const Ifd, ifd_index: usize) void {
        if (self.finding_cb == null) return;

        // Multi-IFD: fires per IFD beyond 0. Validate dedupes if it
        // only wants the first signal.
        if (ifd_index >= 1) {
            self.emitU32(.multi_ifd_chain, @intCast(self.ifds.items.len));
        }

        // Compression-code-driven findings. Each IFD emits at most one
        // finding per code (the callback interface is presence-only).
        if (readScalarU16(dir.*, tags.compression, self.endian) catch null) |comp| {
            if (comp == tags.compression_jpeg) self.emit(.jpeg_in_tiff, &.{});
            if (comp == tags.compression_lerc) self.emit(.lerc_compression, &.{});
        }

        // Photometric=CFA or CFAPattern tag presence.
        var cfa_emitted = false;
        if (readScalarU16(dir.*, tags.photometric, self.endian) catch null) |photo| {
            if (photo == tags.photometric_color_filter_array) {
                self.emit(.cfa_pattern_present, &.{});
                cfa_emitted = true;
            }
        }
        if (!cfa_emitted and dir.get(tags.cfa_pattern) != null) {
            self.emit(.cfa_pattern_present, &.{});
        }

        // Predictor != 1.
        if (readScalarU16(dir.*, tags.predictor, self.endian) catch null) |pred| {
            if (pred != 1) self.emitU32(.predictor_applied, pred);
        }

        // PlanarConfiguration == 2.
        if (readScalarU16(dir.*, tags.planar_configuration, self.endian) catch null) |planar| {
            if (planar == tags.planar_separate) self.emit(.planar_separate, &.{});
        }

        // Tiled layout — TileOffsets tag.
        if (dir.get(tags.tile_offsets) != null) self.emit(.tiled_layout, &.{});

        // ExtraSamples == 1 (associated/pre-multiplied alpha) on any sample.
        if (dir.get(tags.extra_samples)) |entry| {
            var i: u32 = 0;
            while (i < entry.count) : (i += 1) {
                const v = dir.arrayElementU64(tags.extra_samples, i, self.endian, self.source) catch break;
                if (v == 1) {
                    self.emit(.pre_multiplied_alpha, &.{});
                    break;
                }
            }
        }

        // DNG opcode lists (51008 / 51009 / 51022). Payload is the
        // opcode count read from the first u32 BE of the value bytes.
        for ([_]u16{ tags.opcode_list_1, tags.opcode_list_2, tags.opcode_list_3 }) |opc_tag| {
            if (dir.cachedValueBytes(opc_tag)) |buf| {
                if (buf.len >= 4) {
                    const count = std.mem.readInt(u32, buf[0..4], .big);
                    self.emitU32(.opcode_list_present, count);
                }
            }
        }

        // GeoTIFF tags — any of the well-known six is enough to flag.
        const geo_tag_ids = [_]u16{
            33550, // ModelPixelScale
            33922, // ModelTiepoint
            34264, // ModelTransformation
            34735, // GeoKeyDirectory
            34736, // GeoDoubleParams
            34737, // GeoAsciiParams
        };
        for (geo_tag_ids) |t| {
            if (dir.get(t) != null) {
                self.emit(.geotiff_tags_present, &.{});
                break;
            }
        }
    }

    pub fn deinit(self: *Decoder) void {
        for (self.ifds.items) |*i| i.deinit();
        self.ifds.deinit(self.allocator);
        self.ifd_offsets.deinit(self.allocator);
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
            // Cycle defense: malformed files can have next_ifd_offset
            // point back to a previously-parsed IFD (self-loop, or a
            // multi-step cycle through the chain). Linear scan is fine
            // — capped at max_ifds (1024 default) so this stays cheap.
            for (self.ifd_offsets.items) |seen| {
                if (seen == self.next_ifd_offset) return error.IfdChainCycle;
            }
            const offset_width: ifd_mod.OffsetWidth = if (self.bigtiff) .big else .classic;
            const parsed_from = self.next_ifd_offset;
            var next = try ifd_mod.parse(
                self.allocator,
                self.source,
                self.endian,
                parsed_from,
                self.limits,
                offset_width,
            );
            errdefer next.deinit();
            self.ifds.append(self.allocator, next) catch return error.OutOfMemory;
            self.ifd_offsets.append(self.allocator, parsed_from) catch return error.OutOfMemory;
            self.next_ifd_offset = next.next_offset;
            // Fire findings for the newly-materialized IFD. The
            // freshly-appended IFD lives at `self.ifds.items.len - 1`.
            const new_index = self.ifds.items.len - 1;
            self.scanIfdForFindings(&self.ifds.items[new_index], new_index);
        }
        return &self.ifds.items[index];
    }

    /// Decode one strip into dest. Dispatches on the IFD's
    /// Compression tag, then reverses any predictor transform per
    /// the Predictor tag (default 1 = no-op). Photometric expansion
    /// is the consumer's job (raw decoded bytes are returned here).
    pub fn decodeStrip(
        self: *Decoder,
        ifd_index: usize,
        strip_index: u32,
        dest: []u8,
        workspace: *Workspace,
    ) errors.Error!usize {
        const written = try self.decodeStripRaw(ifd_index, strip_index, dest, workspace);
        try self.applyPredictorStrip(ifd_index, strip_index, dest[0..written]);
        return written;
    }

    /// Decode one tile into dest. Same compression dispatch as
    /// decodeStrip; the only difference is the metadata layer
    /// (TileOffsets/TileByteCounts instead of StripOffsets/Counts,
    /// fixed-size tiles instead of variable RowsPerStrip). Tiles on
    /// the right/bottom image edge may decode to MORE bytes than
    /// the in-image portion (encoder pads to a full TileWidth ×
    /// TileLength); caller handles the crop during photometric
    /// expansion.
    pub fn decodeTile(
        self: *Decoder,
        ifd_index: usize,
        tile_index: u32,
        dest: []u8,
        workspace: *Workspace,
    ) errors.Error!usize {
        const written = try self.decodeTileRaw(ifd_index, tile_index, dest, workspace);
        try self.applyPredictorTile(ifd_index, dest[0..written]);
        return written;
    }

    /// Return the effective photometric interpretation that the
    /// caller should pass to photometric-expansion code AFTER
    /// strip/tile decode. Mostly mirrors the IFD's PhotometricInterpretation
    /// tag, but handles a known codec-side quirk:
    ///
    /// JPEG-in-TIFF (Compression=7) with PhotometricInterpretation=YCbCr:
    /// jpegz (matching libjpeg-turbo's `JCS_RGB` default) internally
    /// converts YCbCr → RGB during decode, so the bytes returned from
    /// `decodeStrip` / `decodeTile` are RGB-ordered. Callers must NOT
    /// re-apply a YCbCr → RGB transform during photometric expansion.
    /// This getter returns `photometric_rgb` for that case.
    ///
    /// All other (compression, photometric) combinations pass the IFD
    /// value through unchanged. Errors propagate from the IFD parse if
    /// the requested index isn't materializable.
    pub fn photometricAfterDecode(self: *Decoder, ifd_index: usize) errors.Error!u16 {
        const dir = try self.ifd(ifd_index);
        const photometric = (try readScalarU16(dir.*, tags.photometric, self.endian)) orelse return error.Malformed;
        const compression = (try readScalarU16(dir.*, tags.compression, self.endian)) orelse tags.compression_none;
        if (compression == tags.compression_jpeg and photometric == tags.photometric_ycbcr) {
            return tags.photometric_rgb;
        }
        return photometric;
    }

    /// Validate every strip / tile of every materialized IFD by
    /// pushing each chunk through `decodeStrip` / `decodeTile`.
    /// Exists as a convenience for consumers (e.g. validate's TIFF
    /// deep-validation shim) that want one call to exercise the
    /// codec on the full file rather than open-coding the
    /// IFD-walk + strip-loop themselves.
    ///
    /// Allocates a growing scratch buffer for the decoded output —
    /// starts at 1 MiB, doubles on `error.DestTooSmall` up to
    /// `limits.max_decompressed_strip_bytes`. Past that cap,
    /// `DestTooSmall` propagates and the caller decides whether
    /// that's a coverage gap (skip + warn) or a failure.
    ///
    /// Codec / predictor / structural errors propagate to the
    /// caller as-is so validate's `routeError` can sort them into
    /// FAIL vs WARN buckets per its taxonomy.
    pub fn validateAllStripsAndTiles(self: *Decoder, workspace: *Workspace) errors.Error!void {
        const max_dest_bytes: usize = self.limits.max_decompressed_strip_bytes;
        const initial: usize = @min(@as(usize, 1024 * 1024), max_dest_bytes);
        var dest_buf = self.allocator.alloc(u8, initial) catch return error.OutOfMemory;
        defer self.allocator.free(dest_buf);

        // Materialize the full IFD chain up-front so the loop sees
        // every IFD. ifdCount() reflects only what's been parsed so
        // far; advance until ifd(N) errors (end-of-chain or
        // structural). Graceful end-of-chain surfaces as
        // InvalidArgument; treat it as termination.
        var probe: usize = 1;
        while (true) : (probe += 1) {
            _ = self.ifd(probe) catch break;
        }

        var ifd_index: usize = 0;
        while (ifd_index < self.ifdCount()) : (ifd_index += 1) {
            const dir = try self.ifd(ifd_index);
            if (dir.get(tags.tile_offsets)) |tile_off_entry| {
                const tile_byte_counts_entry = dir.get(tags.tile_byte_counts) orelse return error.Malformed;
                if (tile_off_entry.count != tile_byte_counts_entry.count) return error.Malformed;
                if (tile_off_entry.count > self.limits.max_strips_or_tiles) return error.LimitExceededStripCount;
                var t: u32 = 0;
                while (t < tile_off_entry.count) : (t += 1) {
                    const written = try self.runWithGrowingDest(&dest_buf, max_dest_bytes, .tile, ifd_index, t, workspace);
                    const ext = try self.expectedChunkBytes(dir, .tile, t, tile_off_entry.count);
                    if (written < ext.min or written > ext.max) {
                        return error.Malformed;
                    }
                }
            } else if (dir.get(tags.strip_byte_counts)) |strip_bc_entry| {
                if (strip_bc_entry.count > self.limits.max_strips_or_tiles) return error.LimitExceededStripCount;
                var s: u32 = 0;
                while (s < strip_bc_entry.count) : (s += 1) {
                    const written = try self.runWithGrowingDest(&dest_buf, max_dest_bytes, .strip, ifd_index, s, workspace);
                    const ext = try self.expectedChunkBytes(dir, .strip, s, strip_bc_entry.count);
                    if (written < ext.min or written > ext.max) {
                        return error.Malformed;
                    }
                }
            }
            // IFDs with no strip/tile arrays (e.g. SubIFD chains
            // carrying only metadata) are silently skipped — there's
            // nothing to decode.
        }
    }

    /// Decode one strip or tile, growing `dest_buf.*` on
    /// `DestTooSmall` up to `max_dest_bytes`. Used by
    /// `validateAllStripsAndTiles` so callers don't have to size
    /// the scratch ahead of time.
    const ChunkKind = enum { strip, tile };

    const ChunkShape = struct {
        width: u32,
        rows: u32,
        full_rows: u32,
        chunks_per_plane: usize,
    };

    fn runWithGrowingDest(
        self: *Decoder,
        dest_buf: *[]u8,
        max_dest_bytes: usize,
        kind: ChunkKind,
        ifd_index: usize,
        chunk_index: u32,
        workspace: *Workspace,
    ) errors.Error!usize {
        while (true) {
            const result = switch (kind) {
                .strip => self.decodeStrip(ifd_index, chunk_index, dest_buf.*, workspace),
                .tile => self.decodeTile(ifd_index, chunk_index, dest_buf.*, workspace),
            };
            if (result) |written| return written else |err| switch (err) {
                error.DestTooSmall => {
                    if (dest_buf.len >= max_dest_bytes) return err;
                    const new_size = @min(dest_buf.len * 2, max_dest_bytes);
                    dest_buf.* = self.allocator.realloc(dest_buf.*, new_size) catch return error.OutOfMemory;
                },
                else => return err,
            }
        }
    }

    /// Derive the exact byte extent of one decoded strip/tile from its IFD
    /// layout. This makes a successful codec terminator insufficient: every
    /// chunk must also account for all pixels the directory declares.
    fn expectedChunkBytes(
        self: *Decoder,
        dir: *const Ifd,
        kind: ChunkKind,
        chunk_index: u32,
        chunk_count: u64,
    ) errors.Error!ExpectedExtent {
        const image_width = (try readScalarU32(dir.*, tags.image_width, self.endian)) orelse return error.Malformed;
        const image_length = (try readScalarU32(dir.*, tags.image_length, self.endian)) orelse return error.Malformed;
        if (image_width == 0 or image_length == 0) return error.Malformed;

        const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
        if (samples == 0) return error.Malformed;
        const planar_raw = (try readScalarU16(dir.*, tags.planar_configuration, self.endian)) orelse tags.planar_chunky;
        const planar = switch (planar_raw) {
            tags.planar_chunky, tags.planar_separate => planar_raw,
            else => return error.Malformed,
        };

        const shape: ChunkShape = switch (kind) {
            .strip => blk: {
                const rps_raw = (try readScalarU32(dir.*, tags.rows_per_strip, self.endian)) orelse image_length;
                if (rps_raw == 0) return error.Malformed;
                const rows_per_strip: u32 = @min(rps_raw, image_length);
                const strips_per_plane = try ceilDivU32(image_length, rows_per_strip);
                const strip_in_plane = chunk_index % strips_per_plane;
                const first_row = strip_in_plane * rows_per_strip;
                break :blk .{
                    .width = image_width,
                    .rows = @min(rows_per_strip, image_length - first_row),
                    .full_rows = rows_per_strip,
                    .chunks_per_plane = strips_per_plane,
                };
            },
            .tile => blk: {
                const tile_width = (try readScalarU32(dir.*, tags.tile_width, self.endian)) orelse return error.Malformed;
                const tile_length = (try readScalarU32(dir.*, tags.tile_length, self.endian)) orelse return error.Malformed;
                if (tile_width == 0 or tile_length == 0) return error.Malformed;
                const tiles_across = try ceilDivU32(image_width, tile_width);
                const tiles_down = try ceilDivU32(image_length, tile_length);
                break :blk .{
                    .width = tile_width,
                    .rows = tile_length,
                    .full_rows = tile_length,
                    .chunks_per_plane = try checkedMul(@as(usize, tiles_across), @as(usize, tiles_down)),
                };
            },
        };

        const planes: usize = if (planar == tags.planar_separate) samples else 1;
        const expected_chunk_count = try checkedMul(shape.chunks_per_plane, planes);
        if (chunk_count != @as(u64, expected_chunk_count) or @as(usize, chunk_index) >= expected_chunk_count) {
            return error.Malformed;
        }
        const plane_index: u16 = if (planar == tags.planar_separate)
            @intCast(@as(usize, chunk_index) / shape.chunks_per_plane)
        else
            0;
        const bits_per_pixel = try self.bitsPerPixel(dir, samples, planar, plane_index);

        // TIFF 6.0 §21: chunky YCbCr with chroma subsampling stores H×V-pixel
        // data units of (H·V luma + 1 Cb + 1 Cr) samples, not one full sample
        // set per pixel, so the flat per-row model below over-counts by the
        // subsample ratio. JPEG-in-TIFF (compression 7) is excluded: jpegz
        // returns upsampled RGB, which the flat model already sizes correctly.
        if (planar == tags.planar_chunky and samples == 3 and bits_per_pixel == 24) {
            const photometric = (try readScalarU16(dir.*, tags.photometric, self.endian)) orelse 0;
            const compression = (try readScalarU16(dir.*, tags.compression, self.endian)) orelse tags.compression_none;
            if (photometric == tags.photometric_ycbcr and compression != tags.compression_jpeg) {
                const sub = try readYCbCrSubSampling(dir.*, self.endian);
                if (sub[0] > 1 or sub[1] > 1) {
                    return subsampledYCbCrExtent(
                        @as(usize, shape.width),
                        @as(usize, shape.rows),
                        @as(usize, shape.full_rows),
                        @as(usize, sub[0]),
                        @as(usize, sub[1]),
                        1,
                        self.limits.max_decompressed_strip_bytes,
                    );
                }
            }
        }

        const bits_per_row = try checkedMul(@as(usize, shape.width), bits_per_pixel);
        const bytes_per_row = bits_per_row / 8 + @intFromBool(bits_per_row % 8 != 0);
        const expected = try checkedMul(bytes_per_row, @as(usize, shape.rows));
        if (expected > self.limits.max_decompressed_strip_bytes) {
            return error.LimitExceededDecompressedStripBytes;
        }
        return .{ .min = expected, .max = expected };
    }

    /// Read per-sample bit depths without allocating. TIFF permits either a
    /// uniform scalar or one SHORT per sample; planar-separate chunks use the
    /// depth of their own plane while chunky chunks sum all sample depths.
    fn bitsPerPixel(
        self: *Decoder,
        dir: *const Ifd,
        samples: u16,
        planar: u16,
        plane_index: u16,
    ) errors.Error!usize {
        const bps_entry = dir.get(tags.bits_per_sample) orelse {
            return if (planar == tags.planar_separate) 1 else @as(usize, samples);
        };
        if (bps_entry.field_type != .short) return error.UnsupportedTagType;
        if (bps_entry.count != 1 and bps_entry.count != samples) return error.Malformed;

        const valueAt = struct {
            fn read(decoder: *Decoder, directory: *const Ifd, index: u16) errors.Error!usize {
                const value = try directory.arrayElementU64(tags.bits_per_sample, index, decoder.endian, decoder.source);
                if (value == 0 or value > std.math.maxInt(usize)) return error.Malformed;
                return @intCast(value);
            }
        }.read;

        if (planar == tags.planar_separate) {
            const bps_index: u16 = if (bps_entry.count == 1) 0 else plane_index;
            return valueAt(self, dir, bps_index);
        }

        var total: usize = 0;
        var sample_index: u16 = 0;
        while (sample_index < samples) : (sample_index += 1) {
            const bps_index: u16 = if (bps_entry.count == 1) 0 else sample_index;
            const value = try valueAt(self, dir, bps_index);
            if (value > std.math.maxInt(usize) - total) return error.Malformed;
            total += value;
        }
        return total;
    }

    /// Common shared per-IFD metadata that both strip and tile
    /// predictors need. Read once per call.
    const PredictorMeta = struct {
        predictor: predictors_mod.Predictor,
        samples: u16,
        bps: u16,
        planar: predictors_mod.PlanarConfig,
    };

    fn readPredictorMeta(self: *Decoder, ifd_index: usize) errors.Error!?PredictorMeta {
        const dir = try self.ifd(ifd_index);
        const pred_raw = (try readScalarU16(dir.*, tags.predictor, self.endian)) orelse 1;
        if (pred_raw == 1) return null; // no-op fast path

        const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
        const planar_raw = (try readScalarU16(dir.*, tags.planar_configuration, self.endian)) orelse 1;
        const planar: predictors_mod.PlanarConfig = @enumFromInt(planar_raw);

        // BitsPerSample is technically per-sample; read the first
        // value and assume uniform (M5 limitation).
        var bps: u16 = 8;
        if (dir.get(tags.bits_per_sample)) |bps_entry| {
            var buf: [16]u8 = undefined;
            const need: usize = @as(usize, bps_entry.field_type.elementBytes()) * @as(usize, bps_entry.count);
            if (need > buf.len) return error.Malformed;
            try dir.readEntryValueCached(tags.bits_per_sample, self.endian, self.source, buf[0..need]);
            bps = header_mod.readU16(buf[0..2], self.endian);
        }

        return .{
            .predictor = predictors_mod.Predictor.fromU16(pred_raw),
            .samples = samples,
            .bps = bps,
            .planar = planar,
        };
    }

    /// Run the inverse Predictor transform over a just-decoded strip.
    fn applyPredictorStrip(self: *Decoder, ifd_index: usize, strip_index: u32, bytes: []u8) errors.Error!void {
        const meta = (try self.readPredictorMeta(ifd_index)) orelse return;
        const dir = try self.ifd(ifd_index);
        const width = (try readScalarU32(dir.*, tags.image_width, self.endian)) orelse return error.Malformed;
        const length = (try readScalarU32(dir.*, tags.image_length, self.endian)) orelse return error.Malformed;
        const rps_raw = (try readScalarU32(dir.*, tags.rows_per_strip, self.endian)) orelse length;
        const rps: u32 = if (rps_raw > length) length else rps_raw;
        const remaining_rows: u32 = length - strip_index * rps;
        const this_rows: u32 = @min(rps, remaining_rows);
        try predictors_mod.applyInverse(bytes, meta.predictor, width, this_rows, meta.samples, meta.bps, meta.planar, self.endian, self.allocator);
    }

    /// Run the inverse Predictor transform over a just-decoded tile.
    /// Tile rows = TileLength regardless of image edge — the encoder
    /// pads tile data past the image edge to the full tile dimensions,
    /// so the predictor reverses across the FULL tile.
    fn applyPredictorTile(self: *Decoder, ifd_index: usize, bytes: []u8) errors.Error!void {
        const meta = (try self.readPredictorMeta(ifd_index)) orelse return;
        const dir = try self.ifd(ifd_index);
        const tile_w = (try readScalarU32(dir.*, tags.tile_width, self.endian)) orelse return error.Malformed;
        const tile_h = (try readScalarU32(dir.*, tags.tile_length, self.endian)) orelse return error.Malformed;
        try predictors_mod.applyInverse(bytes, meta.predictor, tile_w, tile_h, meta.samples, meta.bps, meta.planar, self.endian, self.allocator);
    }

    /// Per-chunk extent for the shared codec dispatch.
    const ChunkExtent = struct {
        offset: u64,
        byte_count: u32,
        /// Pixel width per scan-line — for strip this is ImageWidth;
        /// for tile this is TileWidth. Only used by CCITT.
        width: u32,
        /// Number of scan-lines in this chunk — for strip this is the
        /// clamped RowsPerStrip; for tile this is TileLength. Only
        /// used by CCITT.
        rows: u32,
    };

    /// Internal: the codec dispatch without predictor application.
    fn decodeStripRaw(
        self: *Decoder,
        ifd_index: usize,
        strip_index: u32,
        dest: []u8,
        workspace: *Workspace,
    ) errors.Error!usize {
        const dir = try self.ifd(ifd_index);

        // Reject tiled layout from the strip API — caller should
        // route to decodeTile.
        if (dir.get(tags.tile_offsets) != null) return error.UnsupportedTagType;

        const offsets_entry = dir.get(tags.strip_offsets) orelse return error.Malformed;
        const counts_entry = dir.get(tags.strip_byte_counts) orelse return error.Malformed;
        if (strip_index >= offsets_entry.count or strip_index >= counts_entry.count) {
            return error.InvalidArgument;
        }
        if (offsets_entry.count > self.limits.max_strips_or_tiles) {
            return error.LimitExceededStripCount;
        }

        const offset = try dir.arrayElementU64(tags.strip_offsets, strip_index, self.endian, self.source);
        const byte_count_u64 = try dir.arrayElementU64(tags.strip_byte_counts, strip_index, self.endian, self.source);
        if (byte_count_u64 > self.limits.max_compressed_strip_bytes) {
            return error.LimitExceededCompressedStripBytes;
        }
        const byte_count: u32 = @intCast(byte_count_u64);

        // CCITT needs to know the per-chunk row+width. For strips
        // these come from ImageWidth + clamped RowsPerStrip × strip_index.
        const width = (try readScalarU32(dir.*, tags.image_width, self.endian)) orelse return error.Malformed;
        const length = (try readScalarU32(dir.*, tags.image_length, self.endian)) orelse return error.Malformed;
        const rps_raw = (try readScalarU32(dir.*, tags.rows_per_strip, self.endian)) orelse length;
        const rps: u32 = if (rps_raw > length) length else rps_raw;
        const remaining_rows: u32 = length - strip_index * rps;
        const this_rows: u32 = @min(rps, remaining_rows);

        return self.decodeBytes(dir, .{
            .offset = offset,
            .byte_count = byte_count,
            .width = width,
            .rows = this_rows,
        }, dest, workspace);
    }

    /// Internal: codec dispatch for tile layout.
    fn decodeTileRaw(
        self: *Decoder,
        ifd_index: usize,
        tile_index: u32,
        dest: []u8,
        workspace: *Workspace,
    ) errors.Error!usize {
        const dir = try self.ifd(ifd_index);

        // Reject strip layout from the tile API — caller should
        // route to decodeStrip.
        if (dir.get(tags.tile_offsets) == null) return error.UnsupportedTagType;

        const offsets_entry = dir.get(tags.tile_offsets) orelse return error.Malformed;
        const counts_entry = dir.get(tags.tile_byte_counts) orelse return error.Malformed;
        if (tile_index >= offsets_entry.count or tile_index >= counts_entry.count) {
            return error.InvalidArgument;
        }
        if (offsets_entry.count > self.limits.max_strips_or_tiles) {
            return error.LimitExceededStripCount;
        }

        const offset = try dir.arrayElementU64(tags.tile_offsets, tile_index, self.endian, self.source);
        const byte_count_u64 = try dir.arrayElementU64(tags.tile_byte_counts, tile_index, self.endian, self.source);
        if (byte_count_u64 > self.limits.max_compressed_strip_bytes) {
            return error.LimitExceededCompressedStripBytes;
        }
        const byte_count: u32 = @intCast(byte_count_u64);

        const tile_w = (try readScalarU32(dir.*, tags.tile_width, self.endian)) orelse return error.Malformed;
        const tile_h = (try readScalarU32(dir.*, tags.tile_length, self.endian)) orelse return error.Malformed;

        return self.decodeBytes(dir, .{
            .offset = offset,
            .byte_count = byte_count,
            .width = tile_w,
            .rows = tile_h,
        }, dest, workspace);
    }

    /// Shared codec dispatch. Reads Compression from dir, then
    /// dispatches to the matching codec. The ChunkExtent carries the
    /// per-chunk row/width (only used by CCITT).
    fn decodeBytes(
        self: *Decoder,
        dir: *const Ifd,
        ext: ChunkExtent,
        dest: []u8,
        workspace: *Workspace,
    ) errors.Error!usize {
        const comp = (try readScalarU16(dir.*, tags.compression, self.endian)) orelse 1;
        const offset = ext.offset;
        const byte_count = ext.byte_count;

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
                // LZW is delegated to the shared, profile-configured core.
                // This wrapper owns only TIFF's legacy-warning and public
                // error vocabulary; it contains no bit or dictionary logic.
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = self.decodeLzw(scratch, dest) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_ccitt_t6 => blk: {
                // CCITT G4 / T.6 2D modified-modified-Huffman.
                // T6Options bit 1 = uncompressed mode (deferred).
                // FillOrder same as T.4.
                const t6_opts: u32 = (try readScalarU32(dir.*, tags.t6_options, self.endian)) orelse 0;
                if ((t6_opts & 0x2) != 0) break :blk error.UnsupportedCompression;

                const fill_raw = (try readScalarU16(dir.*, tags.fill_order, self.endian)) orelse 1;
                const fill: compressions_ccitt_t6.FillOrder = switch (fill_raw) {
                    1 => .msb_first,
                    2 => .lsb_first,
                    else => break :blk error.Malformed,
                };

                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;

                const written = compressions_ccitt_t6.decode(
                    self.allocator,
                    scratch,
                    dest,
                    ext.width,
                    ext.rows,
                    fill,
                ) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_ccitt_t4 => blk: {
                // CCITT G3 (T.4) 1D modified Huffman. Read T4Options
                // (default 0 = 1D non-byte-aligned) and FillOrder
                // (default 1 = MSB-first). 2D and uncompressed-mode
                // bits rejected.
                const t4_opts: u32 = (try readScalarU32(dir.*, tags.t4_options, self.endian)) orelse 0;
                if ((t4_opts & 0x1) != 0) break :blk error.UnsupportedCompression;
                if ((t4_opts & 0x2) != 0) break :blk error.UnsupportedCompression;
                const eol_byte_align: bool = (t4_opts & 0x4) != 0;

                const fill_raw = (try readScalarU16(dir.*, tags.fill_order, self.endian)) orelse 1;
                const fill: compressions_ccitt_t4.FillOrder = switch (fill_raw) {
                    1 => .msb_first,
                    2 => .lsb_first,
                    else => break :blk error.Malformed,
                };

                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;

                const written = compressions_ccitt_t4.decode(
                    scratch,
                    dest,
                    ext.width,
                    ext.rows,
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
            tags.compression_zstd => blk: {
                // ZSTD-in-TIFF (Compression=50000, GDAL/libtiff
                // extension). Each strip/tile is an independent ZSTD
                // frame.
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = compressions_zstd.decode(scratch[0..byte_count], dest) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_lerc => blk: {
                // LERC-in-TIFF (Compression=34887, Esri / GDAL /
                // libtiff extension). LercParameters (tag 50674) is
                // REQUIRED and strictly validated: two u32 values
                // [codec_version, add_compression]. add_compression
                // ∈ {0=none, 1=Deflate, 2=Zstd} — if 1 or 2, the strip
                // is post-filtered by that codec into the inner LERC
                // blob. Any missing / malformed / out-of-range value →
                // Malformed. No forgiving fallback.
                const params_raw = readTwoU32(dir.*, tags.lerc_parameters, self.endian, self.source) catch break :blk error.Malformed;
                const lerc_params = compressions_lerc.parseParameters(params_raw) catch break :blk error.Malformed;

                // For AddCompression != none we need a scratch buffer
                // sized for the inner LERC blob (post-Deflate/Zstd).
                // LERC's own header overhead can make its blob LARGER
                // than the uncompressed strip for tiny strips (e.g.
                // 16x16 grayscale: raw 256 B, LERC blob ~300 B). Size
                // generously: `max(dest.len, byte_count * 8) + 4 KiB`
                // covers the small-strip header case and any realistic
                // inflated LERC blob.
                const scratch_len = if (lerc_params.add_compression == .none)
                    0
                else blk_scratch: {
                    const bc_upper = byte_count *| 8;
                    const base = if (dest.len > bc_upper) dest.len else bc_upper;
                    break :blk_scratch base +| 4096;
                };
                const scratch_slice = if (scratch_len == 0)
                    dest[0..0]
                else
                    workspace.ensureScratch(scratch_len) catch break :blk error.OutOfMemory;

                const src_buf = workspace.ensureScratch2(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(src_buf, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;

                const written = compressions_lerc.decode(
                    src_buf[0..byte_count],
                    dest,
                    scratch_slice,
                    lerc_params,
                ) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_jpeg => blk: {
                // JPEG-in-TIFF (Compression=7, TIFF Tech Note 2).
                // Supports photometric=RGB (2) and photometric=YCbCr (6).
                // CAVEAT: the JPEG codec (libjpeg via jpegz.wrapperDecode)
                // performs YCbCr→RGB conversion internally for YCbCr-marked
                // JPEG streams. The bytes written to `dest` are therefore
                // RGB pixels regardless of the TIFF photometric tag. The
                // caller MUST NOT re-apply photometric=YCbCr expansion
                // after this strip decode — treat the output as
                // photometric=RGB. (libtiff's TIFFReadRGBAImage helper
                // takes the same approach.) Other photometrics (CMYK,
                // Lab) inside JPEG-in-TIFF are out of scope; the JPEG
                // codec would need explicit colorspace handling.
                const photo = (try readScalarU16(dir.*, tags.photometric, self.endian)) orelse return error.Malformed;
                if (photo != tags.photometric_rgb and photo != tags.photometric_ycbcr) {
                    break :blk error.UnsupportedCompression;
                }

                // Read strip bytes into scratch.
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;

                // Read JPEGTables tag (347) if present — TIFF Tech Note 2
                // Mode 2. The value is eagerly cached on the Ifd at
                // parse time, so we borrow the cached slice. Inline-fit
                // JPEGTables (≤8 bytes) isn't a real shape — any
                // useful tables-stream is hundreds of bytes — so we
                // reject it as malformed.
                const tables_slice: ?[]const u8 = if (dir.get(tags.jpeg_tables)) |tables_entry| t: {
                    const tables_len = ifd_mod.Ifd.entryValueBytes(tables_entry.*);
                    if (tables_len > self.limits.max_tag_value_bytes) break :blk error.LimitExceededTagValueBytes;
                    break :t (dir.cachedValueBytes(tags.jpeg_tables) orelse break :blk error.Malformed);
                } else null;

                const written = compressions_jpeg.decode(self.allocator, scratch, tables_slice, dest) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            else => error.UnsupportedCompression,
        };
    }

    /// Adapt the shared strict LZW core to TIFF's public error vocabulary.
    /// Only a malformed TIFF-6 stream attempts the established old-style
    /// compatibility profile; incomplete new-style data remains truncation.
    fn decodeLzw(self: *Decoder, src: []const u8, dest: []u8) errors.Error!usize {
        const primary = lzwz.decode(lzwz.Profile.tiff6(), src, dest) catch |first_err| {
            switch (first_err) {
                error.MalformedCode => {},
                else => return mapLzwError(first_err),
            }

            const legacy = lzwz.decode(lzwz.Profile.tiffLegacy(), src, dest) catch |legacy_err| {
                return mapLzwError(legacy_err);
            };
            if (!self.lzw_old_style_fired) {
                self.lzw_old_style_fired = true;
                self.emit(.old_style_lzw_codes, &.{});
            }
            return legacy.decoded_len;
        };
        return primary.decoded_len;
    }

    fn mapLzwError(err: lzwz.DecodeError) errors.Error {
        return switch (err) {
            error.MalformedCode => error.Malformed,
            error.IncompleteSource => error.SourceTooShort,
            error.DestTooSmall => error.DestTooSmall,
            // decode() never returns this count-only API error, but retain a
            // conservative malformed-data mapping if lzwz extends its
            // shared error set through this adapter in the future.
            error.DecodedLengthMismatch => error.Malformed,
        };
    }
};

/// Divide a non-zero TIFF dimension, rounding up without an overflow-prone
/// `(numerator + denominator - 1)` intermediate.
fn ceilDivU32(numerator: u32, denominator: u32) errors.Error!u32 {
    if (denominator == 0) return error.Malformed;
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

/// One decoded strip/tile's permitted byte extent. `min` covers every logical
/// (in-image) sample the directory declares; `max` additionally permits
/// spec-legal trailing padding (e.g. a final subsampled strip padded up to a
/// full RowsPerStrip). For every non-subsampled chunk min == max, so the
/// historical exact-equality gate is preserved bit-for-bit.
const ExpectedExtent = struct { min: usize, max: usize };

/// Ceiling division for usize. Denominators here are subsample factors
/// (1/2/4), always nonzero.
fn ceilDivUsize(numerator: usize, denominator: usize) usize {
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

/// TIFF 6.0 §21 chunky YCbCr chroma-subsampling storage extent for one chunk.
/// A data unit packs `sub_h × sub_v` luma samples + one Cb + one Cr, each
/// `sample_bytes` wide, so one unit = (sub_h·sub_v + 2)·sample_bytes bytes and
/// `blocks_across = ceil(width / sub_h)` units span a block row. The vertical
/// direction may be padded: a chunk carries at least `ceil(logical_rows /
/// sub_v)` block rows (`min`) and at most `ceil(full_rows / sub_v)` (`max`, the
/// encoder padding the final strip up to RowsPerStrip). libtiff's
/// TIFFVStripSize/TIFFStripSize yield exactly these bounds — verified against
/// ycbcr-cat.tif whose last strip requires 2250 but stores 3750.
fn subsampledYCbCrExtent(
    width: usize,
    logical_rows: usize,
    full_rows: usize,
    sub_h: usize,
    sub_v: usize,
    sample_bytes: usize,
    max_bytes: usize,
) errors.Error!ExpectedExtent {
    const blocks_across = ceilDivUsize(width, sub_h);
    const unit_bytes = try checkedMul(sub_h * sub_v + 2, sample_bytes);
    const req_block_rows = ceilDivUsize(logical_rows, sub_v);
    const pad_block_rows = ceilDivUsize(full_rows, sub_v);
    const min = try checkedMul(try checkedMul(blocks_across, req_block_rows), unit_bytes);
    const max = try checkedMul(try checkedMul(blocks_across, pad_block_rows), unit_bytes);
    if (max > max_bytes) return error.LimitExceededDecompressedStripBytes;
    return .{ .min = min, .max = max };
}

/// Read YCbCrSubSampling (tag 530): two SHORTs [ChromaSubsampleHoriz,
/// ChromaSubsampleVert]. Absent ⇒ TIFF 6.0 default {2,2}. Only {1,2,4} are
/// spec-legal per axis; anything else is Malformed.
fn readYCbCrSubSampling(dir: Ifd, endian: Endian) errors.Error![2]u16 {
    const e = dir.get(tags.ycbcr_subsampling) orelse return .{ 2, 2 };
    if (e.count != 2) return error.Malformed;
    if (e.field_type != .short) return error.UnsupportedTagType;
    const h = header_mod.readU16(e.raw_value_or_offset[0..2], endian);
    const v = header_mod.readU16(e.raw_value_or_offset[2..4], endian);
    if ((h != 1 and h != 2 and h != 4) or (v != 1 and v != 2 and v != 4)) return error.Malformed;
    return .{ h, v };
}

/// Multiply layout quantities only after proving the product fits the native
/// address size, preventing malformed dimensions from wrapping into a small
/// expected output extent.
fn checkedMul(a: usize, b: usize) errors.Error!usize {
    if (a != 0 and b > std.math.maxInt(usize) / a) return error.Malformed;
    return a * b;
}

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

/// Read a two-element u32 array tag (LercParameters payload — count
/// must be exactly 2 and field_type LONG). Fails Malformed on any
/// other shape. Strict by design: LercParameters is a small private
/// tag with a well-known schema, so a permissive read would only hide
/// producer bugs.
///
/// Two u32 = 8 bytes, which OVERFLOWS classic TIFF's 4-byte inline
/// value slot — the payload is stored out-of-line at `raw_value_or_offset`.
/// We read via `arrayElementU64`, which honors the eager out-of-line
/// value cache and the inline / read-through fallbacks.
fn readTwoU32(dir: Ifd, tag: u16, endian: Endian, source: Source) errors.Error![2]u32 {
    const e = dir.get(tag) orelse return error.Malformed;
    if (e.count != 2) return error.Malformed;
    if (e.field_type != .long) return error.Malformed;
    const a = try dir.arrayElementU64(tag, 0, endian, source);
    const b = try dir.arrayElementU64(tag, 1, endian, source);
    if (a > std.math.maxInt(u32) or b > std.math.maxInt(u32)) return error.Malformed;
    return .{ @intCast(a), @intCast(b) };
}

/// Read element [index] from a SHORT/LONG/LONG8 array tag, widened to u64.
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

test "decodeStrip: compression=6 (OJPEG, never supported) rejected as Unsupported" {
    const w_entry: [12]u8 = .{ 0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 };
    const h_entry: [12]u8 = .{ 0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 };
    const comp_entry: [12]u8 = .{ 0x03, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00 }; // Compression = 6 (OJPEG, deprecated; per SPEC §3 we'll never support this)
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

test "subsampledYCbCrExtent: interior 2:2 strip is exact (min == max)" {
    // width 250, H=2 -> 125 blocks; unit=(2*2+2)=6B; 10 rows, V=2 -> 5 block rows.
    // 125*5*6 = 3750, both bounds (full strip, no padding slack).
    const ext = try subsampledYCbCrExtent(250, 10, 10, 2, 2, 1, 1 << 30);
    try std.testing.expectEqual(@as(usize, 3750), ext.min);
    try std.testing.expectEqual(@as(usize, 3750), ext.max);
}

test "subsampledYCbCrExtent: final 2:2 strip permits pad from required to full" {
    // ycbcr-cat.tif last strip: 5 logical rows in a RowsPerStrip=10 strip.
    // required = 125*ceil(5/2)*6 = 125*3*6 = 2250 (libtiff TIFFVStripSize).
    // padded   = 125*ceil(10/2)*6 = 125*5*6 = 3750 (libtiff TIFFStripSize).
    const ext = try subsampledYCbCrExtent(250, 5, 10, 2, 2, 1, 1 << 30);
    try std.testing.expectEqual(@as(usize, 2250), ext.min);
    try std.testing.expectEqual(@as(usize, 3750), ext.max);
}

test "subsampledYCbCrExtent: horizontal-only 2:1 with odd width rounds blocks up" {
    // width 251, H=2 -> ceil(251/2)=126 blocks; unit=(2*1+2)=4B; V=1 -> 8 block rows.
    // 126*8*4 = 4032, exact.
    const ext = try subsampledYCbCrExtent(251, 8, 8, 2, 1, 1, 1 << 30);
    try std.testing.expectEqual(@as(usize, 4032), ext.min);
    try std.testing.expectEqual(@as(usize, 4032), ext.max);
}

test "subsampledYCbCrExtent: vertical-only 1:2 final strip pads vertically" {
    // width 100, H=1 -> 100 blocks; unit=(1*2+2)=4B; logical 5 rows -> ceil(5/2)=3,
    // full 8 rows -> ceil(8/2)=4. min=100*3*4=1200, max=100*4*4=1600.
    const ext = try subsampledYCbCrExtent(100, 5, 8, 1, 2, 1, 1 << 30);
    try std.testing.expectEqual(@as(usize, 1200), ext.min);
    try std.testing.expectEqual(@as(usize, 1600), ext.max);
}

test "subsampledYCbCrExtent: 4:4 subsampling with odd small dims" {
    // width 10, H=4 -> ceil(10/4)=3 blocks; unit=(4*4+2)=18B; logical 10 rows ->
    // ceil(10/4)=3, full 16 rows -> ceil(16/4)=4. min=3*3*18=162, max=3*4*18=216.
    const ext = try subsampledYCbCrExtent(10, 10, 16, 4, 4, 1, 1 << 30);
    try std.testing.expectEqual(@as(usize, 162), ext.min);
    try std.testing.expectEqual(@as(usize, 216), ext.max);
}

test "subsampledYCbCrExtent: exceeding the decompressed-byte limit errors" {
    try std.testing.expectError(
        error.LimitExceededDecompressedStripBytes,
        subsampledYCbCrExtent(1_000_000, 1_000_000, 1_000_000, 2, 2, 1, 1000),
    );
}

test "validateAllStripsAndTiles: tag-absent YCbCrSubSampling uses the {2,2} default extent" {
    // Chunky YCbCr 2×2 image, uncompressed, with NO YCbCrSubSampling tag (530):
    // the decoder must fall back to the TIFF 6.0 default {2,2} when sizing the
    // subsampled chunk. One 2×2 data unit = 4·Y + Cb + Cr = 6 stored bytes; the
    // flat non-subsampled model would demand 2×2×3 = 12, so acceptance proves the
    // default-subsampling path is exercised end-to-end (not the flat fallback).
    const w_entry: [12]u8 = .{ 0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }; // ImageWidth = 2
    const h_entry: [12]u8 = .{ 0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }; // ImageLength = 2
    const bps_entry: [12]u8 = .{ 0x02, 0x01, 0x03, 0x00, 0x03, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00 }; // BitsPerSample = 3×SHORT @ 0x80
    const comp_entry: [12]u8 = .{ 0x03, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }; // Compression = 1 (none)
    const photo_entry: [12]u8 = .{ 0x06, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00 }; // Photometric = 6 (YCbCr)
    const so_entry: [12]u8 = .{ 0x11, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x88, 0x00, 0x00, 0x00 }; // StripOffsets = 0x88
    const spp_entry: [12]u8 = .{ 0x15, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00 }; // SamplesPerPixel = 3
    const rps_entry: [12]u8 = .{ 0x16, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00 }; // RowsPerStrip = 2
    const sbc_entry: [12]u8 = .{ 0x17, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00 }; // StripByteCounts = 6

    const strip = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x80, 0x80 }; // 4·Y + Cb + Cr

    var bytes = synthesize(9, .{ w_entry, h_entry, bps_entry, comp_entry, photo_entry, so_entry, spp_entry, rps_entry, sbc_entry }, &strip, 0x88);
    // BitsPerSample {8,8,8} out-of-line at 0x80 (synthesize writes only the strip).
    bytes[0x80] = 8;
    bytes[0x82] = 8;
    bytes[0x84] = 8;

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();

    try dec.validateAllStripsAndTiles(&ws);
}
