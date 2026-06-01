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
const compressions_ccitt_t6 = @import("compressions/ccitt_t6.zig");
const compressions_jpeg = @import("compressions/jpeg.zig");
const compressions_zstd = @import("compressions/zstd.zig");
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
    /// One-shot flag for `old_style_lzw_codes` — the LZW codec falls
    /// back from new-style to old-style per strip on malformed
    /// streams; we only want to surface the file-level fact once.
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

        // Compression == 7 → JPEG-in-TIFF.
        if (readScalarU16(dir.*, tags.compression, self.endian) catch null) |comp| {
            if (comp == tags.compression_jpeg) self.emit(.jpeg_in_tiff, &.{});
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
                var t: u32 = 0;
                while (t < tile_off_entry.count) : (t += 1) {
                    try self.runWithGrowingDest(&dest_buf, max_dest_bytes, .tile, ifd_index, t, workspace);
                }
            } else if (dir.get(tags.strip_byte_counts)) |strip_bc_entry| {
                var s: u32 = 0;
                while (s < strip_bc_entry.count) : (s += 1) {
                    try self.runWithGrowingDest(&dest_buf, max_dest_bytes, .strip, ifd_index, s, workspace);
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
    fn runWithGrowingDest(
        self: *Decoder,
        dest_buf: *[]u8,
        max_dest_bytes: usize,
        kind: enum { strip, tile },
        ifd_index: usize,
        chunk_index: u32,
        workspace: *Workspace,
    ) errors.Error!void {
        while (true) {
            const result = switch (kind) {
                .strip => self.decodeStrip(ifd_index, chunk_index, dest_buf.*, workspace),
                .tile => self.decodeTile(ifd_index, chunk_index, dest_buf.*, workspace),
            };
            if (result) |_| return else |err| switch (err) {
                error.DestTooSmall => {
                    if (dest_buf.len >= max_dest_bytes) return err;
                    const new_size = @min(dest_buf.len * 2, max_dest_bytes);
                    dest_buf.* = self.allocator.realloc(dest_buf.*, new_size) catch return error.OutOfMemory;
                },
                else => return err,
            }
        }
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
                // LZW: try TIFF 6.0 new-style first; if Malformed,
                // retry with old-style (Adobe/Sun original timing,
                // common in 1990s TIFF writers — libtiff's
                // "Old-style LZW codes" warning territory).
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch break :blk error.Io;
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = if (compressions_lzw.decodeVariant(scratch, dest, .new_style)) |n| n else |first_err| switch (first_err) {
                    error.Malformed => fb: {
                        const n = compressions_lzw.decodeVariant(scratch, dest, .old_style) catch |e| break :blk e;
                        if (!self.lzw_old_style_fired) {
                            self.lzw_old_style_fired = true;
                            self.emit(.old_style_lzw_codes, &.{});
                        }
                        break :fb n;
                    },
                    else => break :blk first_err,
                };
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

test "Decoder type compiles" {
    _ = Decoder;
}
