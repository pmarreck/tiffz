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

const parser = @import("tiffz-parser");
const errors = parser.errors;
const Limits = parser.Limits;
const Source = parser.Source;
const Workspace = @import("workspace.zig").Workspace;
const header_mod = parser.header;
const Endian = header_mod.Endian;
const ifd_mod = parser.ifd;
const Ifd = ifd_mod.Ifd;
const tags = parser.tags;
const compressions_none = @import("compressions/none.zig");
const compressions_packbits = @import("compressions/packbits.zig");
const compressions_next = @import("compressions/next.zig");
const compressions_thunderscan = @import("compressions/thunderscan.zig");
const compressions_sgilog = @import("compressions/sgilog.zig");
const lzwz = @import("lzwz");
const compressions_deflate = @import("compressions/deflate.zig");
const compressions_ccitt_t4 = @import("compressions/ccitt_t4.zig");
const compressions_ccitt_t6 = @import("compressions/ccitt_t6.zig");
const compressions_jpeg = @import("compressions/jpeg.zig");
const compressions_zstd = @import("compressions/zstd.zig");
const compressions_lerc = @import("compressions/lerc.zig");
const predictors_mod = @import("predictors.zig");
const findings_mod = @import("findings.zig");
const conformance = @import("ifd_conformance.zig");
const jpeg_geometry = @import("jpeg_geometry.zig");
const presence = @import("ifd_presence.zig");

/// One tag 330 value plus the directory that named it. The parent index is
/// how a pointer back at an ancestor is told from a second name for a page
/// that was already parsed.
const SubIfdJob = struct {
    offset: u64,
    parent: usize,
};

/// Where a resource cap fired. Offset is a file byte, ifd_index is the
/// directory being entered, and bytes is how many Source bytes had been read.
pub const LimitProgress = struct {
    offset: u64,
    ifd_index: u64,
    bytes: u64,
};

/// How a discrepancy is reported. `known_failure` is reserved for an
/// admitted pattern. This library does not admit patterns; the consumer
/// registry does. A resource cap is not a discrepancy.
pub const ReportClass = enum(i32) {
    warning = 1,
    @"error" = 2,
    known_failure = 3,
};

/// One validation record. The decoded samples are not the result.
/// `offset` is a real file position when known, and is never a
/// fabricated zero. `type_name` is a static error or finding name.
pub const Discrepancy = struct {
    class: ReportClass,
    offset: ?u64,
    type_name: [:0]const u8,
};

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
    /// Parent index for each materialized IFD, parallel to `ifds`.
    /// Null is IFD0. A next-IFD link parents the new page on the page
    /// that pointed at it. A tag 330 link does the same. Walking this
    /// chain decides whether a child offset is an ancestor.
    ifd_parent: std.ArrayListUnmanaged(?usize),
    /// Tag 330 jobs waiting to be parsed. Drained only once the
    /// current next-IFD link is 0, so existing chain indices stay put
    /// and children follow that chain.
    pending_subifds: std.ArrayListUnmanaged(SubIfdJob) = .empty,
    /// How many IFDs, in walk order, have had their directory rules checked
    /// by the current validation walk; a stop checks the rest.
    rules_checked: usize = 0,
    /// True while `checkUnreachedConformance` runs: every record emitted
    /// then carries `MetadataFlags.after_stop`.
    after_stop_pass: bool = false,
    /// True while the walk or the post-stop pass handles an IFD whose
    /// presence check is deferred: its records carry
    /// `MetadataFlags.presence_deferred`.
    presence_deferred_ifd: bool = false,
    /// IFDs whose presence check did not run, in walk order, covering the
    /// post-stop pass (`presenceDeferred`).
    presence_deferred_list: std.ArrayListUnmanaged(presence.DeferredPresence) = .empty,
    pending_subifd_read: usize = 0,
    /// Next materialized IFD whose tag 330 list has not been queued.
    subifd_scan: usize = 0,
    /// Offset of the next-IFD pointer for the last IFD we've parsed
    /// — 0 if we've reached the end of the chain.
    next_ifd_offset: u64,
    /// Optional callback for native and nested findings emitted during decode.
    /// See `src/findings.zig` for the per-finding payload semantics.
    finding_cb: findings_mod.Callback = null,
    finding_userdata: ?*anyopaque = null,
    /// One-shot flag for `old_style_lzw_codes` — LZW falls back from
    /// new-style to old-style per strip on malformed streams; surface
    /// the file-level compatibility fact only once.
    lzw_old_style_fired: bool = false,
    /// One-shot warning for bounded, nonconformant final-strip padding.
    final_strip_padding_fired: bool = false,
    /// One-shot warning for an exact-extent LZW stream missing its EOD code.
    lzw_missing_eod_fired: bool = false,
    /// One-shot warning for tile geometry whose chunks use strip tag arrays.
    tiled_via_strip_tags_fired: bool = false,
    /// Counts Source bytes for max_bytes_visited. Owned by this decoder.
    budget: *parser.source.ByteBudget,
    /// Filled when a LimitExceeded error is returned. Absent otherwise.
    limit_progress: ?LimitProgress = null,
    /// First file discrepancy. An error replaces a warning. A later
    /// error does not replace the first error. Limits never land here.
    discrepancy: ?Discrepancy = null,
    /// File offset of the chunk currently being checked. Null when the
    /// offset array itself could not be read.
    active_chunk_offset: ?u64 = null,
    /// Rows fully decoded before CCITT T.6 EOFB. Absent unless that outcome fired.
    facsimile_rows: ?u32 = null,

    pub fn open(allocator: Allocator, source: Source) errors.Error!Decoder {
        return openWithLimits(allocator, source, .{});
    }

    pub fn openWithLimits(
        allocator: Allocator,
        source: Source,
        limits: Limits,
    ) errors.Error!Decoder {
        return openWithCallback(allocator, source, limits, null, null);
    }

    /// `openWithLimits` with the finding callback installed from the start, so
    /// a record about IFD 0 reaches it even when open fails: an IFD 0 that runs
    /// past the end of the file emits finding 23 here, then open fails
    /// SourceShortRead as before (validate, 2026-11-07).
    pub fn openWithCallback(
        allocator: Allocator,
        source: Source,
        limits: Limits,
        cb: findings_mod.Callback,
        userdata: ?*anyopaque,
    ) errors.Error!Decoder {
        if (limits.max_ifd_depth < 1) return error.LimitExceededIfdDepth;

        const budget = allocator.create(parser.source.ByteBudget) catch return error.OutOfMemory;
        budget.* = .{ .inner = source, .max_bytes = limits.max_bytes_visited };
        errdefer allocator.destroy(budget);
        const metered = budget.source();

        const h = try header_mod.parse(metered);
        const offset_width: ifd_mod.OffsetWidth = if (h.bigtiff) .big else .classic;

        var ifds: std.ArrayListUnmanaged(Ifd) = .empty;
        errdefer ifds.deinit(allocator);

        var ifd_offsets: std.ArrayListUnmanaged(u64) = .empty;
        errdefer ifd_offsets.deinit(allocator);

        var ifd_parent: std.ArrayListUnmanaged(?usize) = .empty;
        errdefer ifd_parent.deinit(allocator);

        var ifd0_extent: ?ifd_mod.ExtentPastEof = null;
        var ifd0 = ifd_mod.parseExtent(allocator, metered, h.endian, h.ifd0_offset, limits, offset_width, &ifd0_extent) catch |err| {
            if (ifd0_extent) |e| emitExtentTo(cb, userdata, 0, e);
            return err;
        };
        errdefer ifd0.deinit();
        ifds.append(allocator, ifd0) catch return error.OutOfMemory;
        ifd_offsets.append(allocator, h.ifd0_offset) catch return error.OutOfMemory;
        ifd_parent.append(allocator, null) catch return error.OutOfMemory;

        return .{
            .allocator = allocator,
            .source = metered,
            .budget = budget,
            .limits = limits,
            .endian = h.endian,
            .bigtiff = h.bigtiff,
            .ifds = ifds,
            .ifd_offsets = ifd_offsets,
            .ifd_parent = ifd_parent,
            .next_ifd_offset = ifd0.next_offset,
            .finding_cb = cb,
            .finding_userdata = userdata,
        };
    }

    /// Install a callback for native and nested findings emitted during decode.
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

    /// Forward a jpegz strict facade result without flattening JP2/JXL leaf
    /// identity or collapsing unsupported/indeterminate into a binary result.
    pub fn emitStrictValidationFindings(
        self: *Decoder,
        result: *const compressions_jpeg.jpegz.StrictValidationResult,
    ) void {
        for (result.findings.items) |finding| {
            const source: findings_mod.SourceDecoder = switch (finding.source) {
                .jpegz => .jpegz,
                .jp2z => .jp2z,
                .libjxlz => .libjxlz,
            };
            self.emitDetailed(
                source,
                @intCast(finding.leaf_code),
                if (finding.code) |code| @intCast(@intFromEnum(code)) else null,
                findings_mod.strictFindingVerdict(finding),
                finding.offset,
                finding.host_offset,
                finding.offset_is_exact,
                finding.detail orelse &.{},
            );
        }
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
        self.emitDetailed(
            .tiffz,
            @intCast(@intFromEnum(finding)),
            null,
            .valid,
            null,
            null,
            false,
            payload,
        );
    }

    /// Finding 23 for a structure that runs past the end of the file, through
    /// `cb` (a no-op when null): verdict corrupt, the 40-byte payload of
    /// docs/plan_context/extent-past-eof.md, anchored on the declaring entry or
    /// else the declared start, exact. Static so open can emit it for IFD 0.
    fn encodeExtent(ifd_index: u32, e: ifd_mod.ExtentPastEof, payload: *[findings_mod.extent_past_eof_payload_len]u8) void {
        std.mem.writeInt(u32, payload[0..4], ifd_index, .little);
        std.mem.writeInt(u16, payload[4..6], @intFromEnum(e.kind), .little);
        std.mem.writeInt(u16, payload[6..8], e.tag, .little);
        std.mem.writeInt(u64, payload[8..16], e.start, .little);
        std.mem.writeInt(u64, payload[16..24], e.length, .little);
        std.mem.writeInt(u64, payload[24..32], e.file_size, .little);
        std.mem.writeInt(u64, payload[32..40], e.entry_offset orelse std.math.maxInt(u64), .little);
    }

    /// Finding 23 from a live decoder: the same record, with the per-IFD
    /// flags `emitDetailed` adds.
    fn emitExtentPastEof(self: *Decoder, ifd_index: u32, e: ifd_mod.ExtentPastEof) void {
        var payload: [findings_mod.extent_past_eof_payload_len]u8 = undefined;
        encodeExtent(ifd_index, e, &payload);
        const anchor = e.entry_offset orelse e.start;
        self.noteDiscrepancy(.@"error", anchor, "extent_past_eof");
        self.emitDetailed(
            .tiffz,
            @intCast(@intFromEnum(findings_mod.InfoFinding.extent_past_eof)),
            null,
            .corrupt,
            anchor,
            null,
            true,
            &payload,
        );
    }

    fn emitExtentTo(cb: findings_mod.Callback, userdata: ?*anyopaque, ifd_index: u32, e: ifd_mod.ExtentPastEof) void {
        const callback = cb orelse return;
        var payload: [findings_mod.extent_past_eof_payload_len]u8 = undefined;
        encodeExtent(ifd_index, e, &payload);
        const flags = findings_mod.MetadataFlags.byte_offset_present | findings_mod.MetadataFlags.offset_is_exact;
        callback(
            userdata,
            @intFromEnum(findings_mod.SourceDecoder.tiffz),
            @intCast(@intFromEnum(findings_mod.InfoFinding.extent_past_eof)),
            0,
            @intFromEnum(findings_mod.Verdict.corrupt),
            e.entry_offset orelse e.start,
            0,
            flags,
            &payload,
            payload.len,
        );
    }

    /// Emit one fully-qualified finding without flattening a nested decoder's
    /// raw code, mapped code, verdict, or offset provenance.
    fn emitDetailed(
        self: *Decoder,
        source_decoder: findings_mod.SourceDecoder,
        finding_code: i32,
        mapped_finding_code: ?i32,
        verdict: findings_mod.Verdict,
        byte_offset: ?u64,
        host_byte_offset: ?u64,
        offset_is_exact: bool,
        payload: []const u8,
    ) void {
        const cb = self.finding_cb orelse return;
        var flags: u32 = 0;
        if (mapped_finding_code != null) flags |= findings_mod.MetadataFlags.mapped_code_present;
        if (byte_offset != null) flags |= findings_mod.MetadataFlags.byte_offset_present;
        if (host_byte_offset != null) flags |= findings_mod.MetadataFlags.host_offset_present;
        if (offset_is_exact) flags |= findings_mod.MetadataFlags.offset_is_exact;
        if (self.after_stop_pass) flags |= findings_mod.MetadataFlags.after_stop;
        if (self.presence_deferred_ifd) flags |= findings_mod.MetadataFlags.presence_deferred;
        cb(
            self.finding_userdata,
            @intFromEnum(source_decoder),
            finding_code,
            mapped_finding_code orelse 0,
            @intFromEnum(verdict),
            byte_offset orelse 0,
            host_byte_offset orelse 0,
            flags,
            if (payload.len > 0) payload.ptr else null,
            payload.len,
        );
    }

    /// Check one IFD against the directory rules in `ifd_conformance` and emit
    /// a corrupt finding per fault. Notes the first fault for progress and
    /// returns whether there was any. Validation fails Malformed once the
    /// walk ends, so every page is still decoded for reach.
    /// `dng` is what IFD 0 declares about DNG (`conformance.Dng.fromIfd0`).
    fn checkIfdConformance(self: *Decoder, dir: *const Ifd, ifd_index: usize, dng: ?conformance.Dng) errors.Error!bool {
        var faults: std.ArrayListUnmanaged(conformance.Fault) = .empty;
        defer faults.deinit(self.allocator);
        try conformance.check(self.allocator, dir, self.endian, dng, &faults);
        const ifd_offset = self.ifdFileOffset(ifd_index) orelse return error.Bug;
        for (faults.items) |fault| {
            const entry_offset = conformance.entryOffset(ifd_offset, fault.entryIndex(), dir.offset_width);
            const finding: findings_mod.InfoFinding = switch (fault) {
                .unsorted => .ifd_entries_unsorted,
                .field_invalid => .tag_field_invalid,
            };
            self.noteDiscrepancy(.@"error", entry_offset, switch (fault) {
                .unsorted => "ifd_entries_unsorted",
                .field_invalid => "tag_field_invalid",
            });
            var buf: [conformance.max_payload_len]u8 = undefined;
            self.emitDetailed(
                .tiffz,
                @intCast(@intFromEnum(finding)),
                null,
                .corrupt,
                entry_offset,
                null,
                true,
                conformance.encodePayload(fault, @intCast(ifd_index), entry_offset, &buf),
            );
        }
        const required = self.checkIfdPresence(dir, ifd_index, ifd_offset);
        return faults.items.len > 0 or required;
    }

    /// `tag_presence_invalid` for one IFD (`ifd_presence`), emitted as a
    /// corrupt finding per record; true if any. The X/YResolution rows stay
    /// off until the owner signs off (validate, 2026-11-05).
    fn checkIfdPresence(self: *Decoder, dir: *const Ifd, ifd_index: usize, ifd_offset: u64) bool {
        const result = presence.check(dir, .{ .resolution = false });
        for (result.items()) |record| {
            const anchor = if (record.entry_index) |i| conformance.entryOffset(ifd_offset, i, dir.offset_width) else ifd_offset;
            self.noteDiscrepancy(.@"error", anchor, "tag_presence_invalid");
            var buf: [presence.payload_len]u8 = undefined;
            self.emitDetailed(
                .tiffz,
                @intCast(@intFromEnum(findings_mod.InfoFinding.tag_presence_invalid)),
                null,
                .corrupt,
                anchor,
                null,
                true,
                presence.encodePayload(record, @intCast(ifd_index), anchor, &buf),
            );
        }
        return result.len > 0;
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

        // Tiled layout is established by canonical offsets or tile geometry.
        if (dir.get(tags.tile_offsets) != null or
            (dir.get(tags.tile_width) != null and dir.get(tags.tile_length) != null))
        {
            self.emit(.tiled_layout, &.{});
        }

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
        self.ifd_parent.deinit(self.allocator);
        self.pending_subifds.deinit(self.allocator);
        self.presence_deferred_list.deinit(self.allocator);
        self.allocator.destroy(self.budget);
    }

    pub fn ifdCount(self: *const Decoder) usize {
        return self.ifds.items.len;
    }

    /// Get an IFD by index. Lazily walks the next-IFD chain, then tag 330
    /// children of directories already materialized. A consumer that only
    /// touches IFD0 pays nothing for either. The codec-free parser does not
    /// do this walk.
    pub fn ifd(self: *Decoder, index: usize) errors.Error!*const Ifd {
        while (index >= self.ifds.items.len) {
            if (self.next_ifd_offset == 0) {
                try self.queueUnscannedSubifds();
                const child = try self.nextQueuedSubifd() orelse return error.InvalidArgument;
                try self.materializeLinkedIfd(child.offset, child.parent);
                continue;
            }
            // A next pointer that revisits a parsed IFD does not terminate.
            // TIFF 6.0 ends the chain with zero. Linear scan is enough:
            // max_ifds caps the list.
            if (self.offsetAlreadyMaterialized(self.next_ifd_offset)) {
                self.noteDiscrepancy(.@"error", self.next_ifd_offset, "IfdChainCycle");
                return error.IfdChainCycle;
            }
            const chain_parent: ?usize = self.ifds.items.len - 1;
            try self.materializeLinkedIfd(self.next_ifd_offset, chain_parent);
        }
        return &self.ifds.items[index];
    }

    /// Depth of a directory whose parent index is `parent`. IFD0 (no parent) is 1.
    fn linkedDepth(self: *const Decoder, parent: ?usize) u32 {
        var depth: u32 = 1;
        var cursor = parent;
        var guard: usize = 0;
        while (cursor) |idx| {
            depth += 1;
            guard += 1;
            if (guard > self.ifd_parent.items.len) break;
            if (idx >= self.ifd_parent.items.len) break;
            cursor = self.ifd_parent.items[idx];
        }
        return depth;
    }

    fn progressIfdIndex(self: *const Decoder) u64 {
        if (self.ifds.items.len == 0) return 0;
        return @intCast(self.ifds.items.len - 1);
    }

    /// Record the first limit site. A later backfill must not overwrite it.
    /// A chunk over the compressed-bytes cap is a limit only when the file
    /// holds it; one that runs past the end of the file is SourceShortRead
    /// (validate, 2026-11-05: a declared extent past the file is not a limit).
    /// Finding 23, kind 3: strip or tile `offset` + `byte_count` runs past the
    /// end of the file. Emits the record, anchored on the offset array's entry
    /// (validate, 2026-11-07), and returns SourceShortRead.
    fn chunkPastEnd(self: *Decoder, dir: *const Ifd, ifd_index: usize, layout: ChunkLayout, offset: u64, byte_count: u64) errors.Error {
        const entry = dir.get(layout.offsets_tag) orelse return error.SourceShortRead;
        const entry_index: u32 = @intCast((@intFromPtr(entry) - @intFromPtr(dir.entries.ptr)) / @sizeOf(ifd_mod.Entry));
        const ifd_offset = self.ifdFileOffset(ifd_index) orelse return error.SourceShortRead;
        self.emitExtentPastEof(@intCast(ifd_index), .{
            .kind = .chunk,
            .tag = layout.offsets_tag,
            .start = offset,
            .length = byte_count,
            .file_size = self.source.sizeOf() catch 0,
            .entry_offset = conformance.entryOffset(ifd_offset, entry_index, dir.offset_width),
        });
        return error.SourceShortRead;
    }

    fn compressedChunkTooLarge(self: *const Decoder, offset: u64, byte_count: u64) errors.Error {
        if (ifd_mod.endsPastFile(self.source, offset, byte_count)) return error.SourceShortRead;
        return error.LimitExceededCompressedStripBytes;
    }

    fn noteLimit(self: *Decoder, err: errors.Error, offset: u64, ifd_index: u64) errors.Error {
        if (self.limit_progress == null) {
            self.limit_progress = .{
                .offset = offset,
                .ifd_index = ifd_index,
                .bytes = self.budget.bytes,
            };
        }
        return err;
    }

    /// Record a validation discrepancy. The first error wins. An error
    /// replaces a warning. A warning does not replace an error. Limits
    /// are reach and are not recorded here.
    fn noteDiscrepancy(self: *Decoder, class: ReportClass, offset: ?u64, type_name: [:0]const u8) void {
        if (self.discrepancy) |existing| {
            if (existing.class == .@"error") return;
            if (class != .@"error") return;
        }
        self.discrepancy = .{
            .class = class,
            .offset = offset,
            .type_name = type_name,
        };
    }

    fn noteFileClaim(self: *Decoder, err: errors.Error, offset: ?u64) void {
        if (errors.isLimit(err)) return;
        self.noteDiscrepancy(.@"error", offset, @errorName(err));
    }

    fn ifdFileOffset(self: *const Decoder, ifd_index: usize) ?u64 {
        if (ifd_index >= self.ifd_offsets.items.len) return null;
        return self.ifd_offsets.items[ifd_index];
    }

    fn chunkFileOffset(self: *Decoder, dir: *const Ifd, layout: ChunkLayout, chunk_index: u32) ?u64 {
        return dir.arrayElementU64(layout.offsets_tag, chunk_index, self.endian, self.source) catch null;
    }

    /// Parse one IFD and remember its next-link and parent. Findings for
    /// that page fire here, before the caller decodes strips.
    fn materializeLinkedIfd(self: *Decoder, offset: u64, parent: ?usize) errors.Error!void {
        const prospective: u64 = @intCast(self.ifds.items.len);
        if (self.ifds.items.len >= self.limits.max_ifds) return self.noteLimit(error.LimitExceededIfdCount, offset, prospective);
        const depth = linkedDepth(self, parent);
        if (depth > self.limits.max_ifd_depth) return self.noteLimit(error.LimitExceededIfdDepth, offset, prospective);
        const offset_width: ifd_mod.OffsetWidth = if (self.bigtiff) .big else .classic;
        var extent: ?ifd_mod.ExtentPastEof = null;
        var parsed = ifd_mod.parseExtent(
            self.allocator,
            self.source,
            self.endian,
            offset,
            self.limits,
            offset_width,
            &extent,
        ) catch |err| {
            if (extent) |e| self.emitExtentPastEof(@intCast(prospective), e);
            if (errors.isLimit(err)) return self.noteLimit(err, self.budget.last_offset, prospective);
            self.noteFileClaim(err, offset);
            return err;
        };
        errdefer parsed.deinit();
        const next_offset = parsed.next_offset;
        self.ifds.append(self.allocator, parsed) catch return error.OutOfMemory;
        self.ifd_offsets.append(self.allocator, offset) catch return error.OutOfMemory;
        self.ifd_parent.append(self.allocator, parent) catch return error.OutOfMemory;
        self.next_ifd_offset = next_offset;
        const new_index = self.ifds.items.len - 1;
        self.scanIfdForFindings(&self.ifds.items[new_index], new_index);
    }

    fn offsetAlreadyMaterialized(self: *const Decoder, offset: u64) bool {
        for (self.ifd_offsets.items) |seen| {
            if (seen == offset) return true;
        }
        return false;
    }

    /// Queue tag 330 offsets from directories parsed since the last call.
    /// Count 0 is an empty array. The drain classifies each offset.
    fn queueUnscannedSubifds(self: *Decoder) errors.Error!void {
        while (self.subifd_scan < self.ifds.items.len) {
            const parent = self.subifd_scan;
            self.subifd_scan += 1;
            const dir = &self.ifds.items[parent];
            const entry = dir.get(tags.sub_ifds) orelse continue;
            if (entry.count > std.math.maxInt(u32)) return error.Malformed;
            var index: u32 = 0;
            while (index < @as(u32, @intCast(entry.count))) : (index += 1) {
                const offset = try dir.arrayElementU64(tags.sub_ifds, index, self.endian, self.source);
                self.pending_subifds.append(self.allocator, .{
                    .offset = offset,
                    .parent = parent,
                }) catch return error.OutOfMemory;
            }
        }
    }

    /// A tag 330 value that names the queuing directory or one of its
    /// ancestors is a cycle. TIFF 6.0 ends a chain with a zero next
    /// pointer, and this pointer does not name a new image. A value that
    /// names some other already-parsed directory is that same page again.
    fn nextQueuedSubifd(self: *Decoder) errors.Error!?SubIfdJob {
        while (self.pending_subifd_read < self.pending_subifds.items.len) {
            const job = self.pending_subifds.items[self.pending_subifd_read];
            self.pending_subifd_read += 1;
            if (self.offsetIsAncestor(job.parent, job.offset)) {
                self.noteDiscrepancy(.@"error", job.offset, "IfdChainCycle");
                return error.IfdChainCycle;
            }
            if (self.offsetAlreadyMaterialized(job.offset)) continue;
            return job;
        }
        return null;
    }

    fn offsetIsAncestor(self: *const Decoder, start: usize, offset: u64) bool {
        var cursor: ?usize = start;
        while (cursor) |idx| {
            if (self.ifd_offsets.items[idx] == offset) return true;
            cursor = self.ifd_parent.items[idx];
        }
        return false;
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
        try self.applyPredictorTile(ifd_index, tile_index, dest[0..written]);
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
        self.validatePages(workspace) catch |err| {
            const result = if (errors.isLimit(err)) self.noteLimit(err, self.budget.last_offset, self.progressIfdIndex()) else err;
            // A decode, graph or limit stop leaves every parsed IFD checkable:
            // the directory rules read only parsed entries. Their faults
            // follow the stopping error, which is still the one returned and
            // reported first (validate, 2026-11-04; reach-gap.md). A limit is
            // a claim about tiffz and a corrupt record one about the file, so
            // a limit never hides the records (validate, 2026-11-05).
            // OutOfMemory and Bug stop everything.
            if (err != error.OutOfMemory and err != error.Bug) self.checkUnreachedConformance();
            return result;
        };
    }

    /// What the file declares about DNG (IFD 0's DNGVersion), with the raw
    /// IFD's ColorPlanes from every parsed IFD; null when it is not DNG.
    fn dngContext(self: *const Decoder) ?conformance.Dng {
        if (self.ifds.items.len == 0) return null;
        var d = conformance.Dng.fromIfd0(&self.ifds.items[0], self.endian) orelse return null;
        d.color_planes = conformance.colorPlanes(self.ifds.items, self.endian);
        return d;
    }

    /// After a stopping error, check the directory rules of every parsed IFD
    /// the walk did not reach, in walk order. Best effort: running out of
    /// memory here ends the pass and keeps the original error. Its records
    /// carry `MetadataFlags.after_stop` (owner, option B; validate
    /// numbered the bit 2026-11-06), so a matcher can scope a signature to
    /// the walk that was reached.
    fn checkUnreachedConformance(self: *Decoder) void {
        if (self.ifds.items.len == 0) return;
        self.after_stop_pass = true;
        defer self.after_stop_pass = false;
        defer self.presence_deferred_ifd = false;
        const dng = self.dngContext();
        var i = self.rules_checked;
        while (i < self.ifds.items.len) : (i += 1) {
            self.presence_deferred_ifd = presence.deferred(&self.ifds.items[i]);
            if (self.presence_deferred_ifd) self.noteDeferredPresence(i) catch return;
            _ = self.checkIfdConformance(&self.ifds.items[i], i, dng) catch return;
            _ = self.checkJpegGeometry(&self.ifds.items[i], i, dng) catch return;
        }
        self.rules_checked = self.ifds.items.len;
    }

    /// IFDs whose presence check did not run (finding 20), in walk order,
    /// from the last `validateAllStripsAndTiles`, including IFDs the post-stop
    /// pass checked. Reach, not a record (validate, 2026-11-07).
    pub fn presenceDeferred(self: *const Decoder) []const presence.DeferredPresence {
        return self.presence_deferred_list.items;
    }

    /// Record IFD `ifd_index` as deferred once: the post-stop pass can revisit
    /// the IFD the walk stopped in.
    fn noteDeferredPresence(self: *Decoder, ifd_index: usize) error{OutOfMemory}!void {
        const items = self.presence_deferred_list.items;
        if (items.len > 0 and items[items.len - 1].ifd_index == ifd_index) return;
        try self.presence_deferred_list.append(self.allocator, .{ .ifd_index = @intCast(ifd_index), .reason = .jpeg_interchange_format_only });
    }

    fn validatePages(self: *Decoder, workspace: *Workspace) errors.Error!void {
        self.rules_checked = 0;
        defer self.presence_deferred_ifd = false;
        self.presence_deferred_list.clearRetainingCapacity();
        const max_dest_bytes: usize = self.limits.max_decompressed_strip_bytes;
        const initial: usize = @min(@as(usize, 1024 * 1024), max_dest_bytes);
        var dest_buf = self.allocator.alloc(u8, initial) catch return error.OutOfMemory;
        defer self.allocator.free(dest_buf);

        // Materialize the next-IFD chain and tag 330 children so the loop
        // sees every page. ifdCount() reflects only what's been parsed so
        // far. End of that graph is InvalidArgument. Any other error is
        // structural and must fail the walk; swallowing it reported a
        // later corrupt page as fully validated.
        var probe: usize = 1;
        while (true) : (probe += 1) {
            _ = self.ifd(probe) catch |err| switch (err) {
                error.InvalidArgument => break,
                else => {
                    self.noteFileClaim(err, null);
                    return err;
                },
            };
        }

        // A directory-rule fault fails validation only after the walk, so
        // later pages still get decoded and their findings reported.
        var nonconforming = false;
        // DNG rows and restrictions apply to every IFD of a file whose IFD 0
        // declares DNGVersion.
        const dng = self.dngContext();

        var ifd_index: usize = 0;
        while (ifd_index < self.ifdCount()) : (ifd_index += 1) {
            const dir = self.ifd(ifd_index) catch |err| {
                self.noteFileClaim(err, self.ifdFileOffset(ifd_index));
                return err;
            };
            self.presence_deferred_ifd = presence.deferred(dir);
            if (self.presence_deferred_ifd) try self.noteDeferredPresence(ifd_index);
            if (try self.checkIfdConformance(dir, ifd_index, dng)) nonconforming = true;
            if (try self.checkJpegGeometry(dir, ifd_index, dng)) nonconforming = true;
            self.rules_checked = ifd_index + 1;
            // No strip/tile arrays. A JPEGInterchangeFormat thumbnail (CR2
            // IFD1) is still a known page with nothing for this walk to
            // decode. Any other main-chain IFD in that shape is not an
            // image page: validate must not report it as fully checked.
            const layout = (self.chunkLayout(dir) catch |err| {
                self.noteFileClaim(err, self.ifdFileOffset(ifd_index));
                return err;
            }) orelse {
                if (dir.get(tags.jpeg_interchange_format) != null) continue;
                self.noteFileClaim(error.Malformed, self.ifdFileOffset(ifd_index));
                return error.Malformed;
            };
            // Partial-coverage skip (Peter's 2026-08-27 ruling; finding code 16,
            // Einstein-approved): an otherwise well-formed IFD whose compression
            // tiffz deliberately never supports is not Malformed and must not
            // fail the walk — skip its chunks and name the uncovered portion.
            // Applies ONLY to never-supported codes (`compressionSupported` is
            // the same list the codec dispatch enforces); a supported codec's
            // decode failure keeps its native error and never becomes code 16.
            {
                const comp = (try readScalarU16(dir.*, tags.compression, self.endian)) orelse tags.compression_none;
                if (!compressionSupported(comp)) {
                    var payload: [8]u8 = undefined;
                    std.mem.writeInt(u32, payload[0..4], @intCast(ifd_index), .little);
                    std.mem.writeInt(u32, payload[4..8], comp, .little);
                    self.emit(.unsupported_compression_skipped, &payload);
                    continue;
                }
            }
            if (layout.tolerated_tiled_tags and !self.tiled_via_strip_tags_fired) {
                self.tiled_via_strip_tags_fired = true;
                self.emit(.tiled_geometry_via_strip_tags, &.{});
                self.noteDiscrepancy(.warning, self.ifdFileOffset(ifd_index), "tiled_geometry_via_strip_tags");
            }

            var chunk_index: u32 = 0;
            while (chunk_index < layout.count) : (chunk_index += 1) {
                self.active_chunk_offset = self.chunkFileOffset(dir, layout, chunk_index);
                const ext = self.expectedChunkBytes(dir, layout.kind, chunk_index, layout.count) catch |err| {
                    self.noteFileClaim(err, self.active_chunk_offset);
                    return err;
                };
                const written = self.runWithGrowingDest(
                    &dest_buf,
                    max_dest_bytes,
                    layout.kind,
                    ifd_index,
                    chunk_index,
                    workspace,
                ) catch |err| {
                    if (err == error.SourceTooShort) {
                        const eod_before = self.lzw_missing_eod_fired;
                        if (try self.validateMissingLzwEod(
                            dir,
                            ifd_index,
                            layout,
                            chunk_index,
                            ext,
                            workspace,
                        )) |compat_written| {
                            if (!eod_before and self.lzw_missing_eod_fired) {
                                self.noteDiscrepancy(.warning, self.active_chunk_offset, "lzw_missing_eod_tolerated");
                            }
                            self.acceptDecodedExtent(ext, compat_written) catch |extent_err| {
                                self.noteFileClaim(extent_err, self.active_chunk_offset);
                                return extent_err;
                            };
                            continue;
                        }
                    }
                    self.noteFileClaim(err, self.active_chunk_offset);
                    return err;
                };
                self.acceptDecodedExtent(ext, written) catch |err| {
                    self.noteFileClaim(err, self.active_chunk_offset);
                    return err;
                };
            }
        }
        if (nonconforming) return error.Malformed;
    }

    /// The fields finding 19 checks one Compression 7 IFD's segments against,
    /// with the absolute offset of each entry a record cites. A field whose
    /// own encoding is malformed (finding 18's business) disables the rules
    /// that need it rather than standing in with a guess.
    fn jpegGeometryFields(self: *Decoder, dir: *const Ifd, ifd_index: usize, layout: ChunkLayout) errors.Error!jpeg_geometry.Fields {
        const length = readScalarU32(dir.*, tags.image_length, self.endian) catch null;
        const rows = readScalarU32(dir.*, tags.rows_per_strip, self.endian) catch null;
        const photometric = readScalarU16(dir.*, tags.photometric, self.endian) catch null;
        const planar = (readScalarU16(dir.*, tags.planar_configuration, self.endian) catch null) orelse 1;
        const subsampling: ?[2]u16 = readYCbCrSubSampling(dir.*, self.endian) catch null;
        const photometric_entry = self.tagEntryOffset(dir, ifd_index, tags.photometric);
        return .{
            .tiled = layout.kind == .tile,
            // An absent or unreadable RowsPerStrip or ImageLength leaves one
            // strip per plane as far as rule 1 can tell.
            .multi_strip = if (rows) |r| if (length) |l| r < l else false else false,
            .rows_per_strip = rows orelse 0,
            .tile_width = (readScalarU32(dir.*, tags.tile_width, self.endian) catch null) orelse 0,
            .tile_length = (readScalarU32(dir.*, tags.tile_length, self.endian) catch null) orelse 0,
            .planar = planar,
            .photometric = photometric,
            .subsampling = subsampling orelse .{ 2, 2 },
            .sampling_known = subsampling != null,
            .rows_entry = self.tagEntryOffset(dir, ifd_index, tags.rows_per_strip),
            .tile_width_entry = self.tagEntryOffset(dir, ifd_index, tags.tile_width),
            .tile_length_entry = self.tagEntryOffset(dir, ifd_index, tags.tile_length),
            .sampling_entry = if (photometric == tags.photometric_ycbcr and dir.get(tags.ycbcr_subsampling) != null)
                self.tagEntryOffset(dir, ifd_index, tags.ycbcr_subsampling)
            else
                photometric_entry,
            .planar_entry = self.tagEntryOffset(dir, ifd_index, tags.planar_configuration),
            .compression_entry = self.tagEntryOffset(dir, ifd_index, tags.compression),
        };
    }

    /// Absolute offset of `tag`'s entry in IFD `ifd_index`, or 0 when absent.
    fn tagEntryOffset(self: *Decoder, dir: *const Ifd, ifd_index: usize, tag: u16) u64 {
        const base = self.ifdFileOffset(ifd_index) orelse return 0;
        for (dir.entries, 0..) |entry, i| {
            if (entry.tag == tag) return conformance.entryOffset(base, @intCast(i), dir.offset_width);
        }
        return 0;
    }

    /// Finding 19 over one IFD (owner-approved 2026-11-04; reach per
    /// validate, 2026-11-05): a structural check of each Compression 7
    /// segment's marker stream up to its frame header, with no entropy
    /// decoding, so it applies whether or not the segment decodes and, like
    /// the directory rules, to IFDs a stopping error left unreached. A
    /// segment whose markers do not parse (jpegz `frameHeader` fails), or
    /// that cannot be read, contributes nothing and is not examined. Reads
    /// grow from 4 KiB, never past the segment's byte count or
    /// `max_compressed_strip_bytes`. True if any record was emitted.
    fn checkJpegGeometry(self: *Decoder, dir: *const Ifd, ifd_index: usize, dng: ?conformance.Dng) errors.Error!bool {
        const compression = (readScalarU16(dir.*, tags.compression, self.endian) catch return false) orelse tags.compression_none;
        if (compression != tags.compression_jpeg) return false;
        const layout = (self.chunkLayout(dir) catch return false) orelse return false;
        var fields = self.jpegGeometryFields(dir, ifd_index, layout) catch |err| {
            if (err == error.OutOfMemory) return err;
            return false;
        };
        fields.dng_baseline = conformance.dngBaselineJpeg(dir, self.endian, dng);
        var acc = jpeg_geometry.Accumulator{ .fields = fields };
        var buf: []u8 = &.{};
        defer self.allocator.free(buf);
        var segment: u32 = 0;
        while (segment < layout.count) : (segment += 1) {
            const offset = dir.arrayElementU64(layout.offsets_tag, segment, self.endian, self.source) catch continue;
            const count = dir.arrayElementU64(layout.counts_tag, segment, self.endian, self.source) catch continue;
            const cap: u64 = @min(count, self.limits.max_compressed_strip_bytes);
            var want: u64 = @min(cap, 4096);
            while (want > 0) {
                if (buf.len < want) {
                    const grown = self.allocator.realloc(buf, @intCast(want)) catch return error.OutOfMemory;
                    buf = grown;
                }
                // A read failure leaves the segment unexamined; the decode
                // reports it. Running out of the byte budget is a limit, as
                // anywhere else.
                const got = self.source.readAt(buf[0..@intCast(want)], offset) catch |raw| {
                    const err = parser.source.preserveReadError(raw);
                    if (errors.isLimit(err)) return self.noteLimit(err, self.budget.last_offset, ifd_index);
                    break;
                };
                if (compressions_jpeg.jpegz.frameHeader(buf[0..got])) |frame| {
                    acc.add(segment, offset + frame.sof_offset, &frame);
                    break;
                } else |err| {
                    // Only a header cut off by the read itself earns a longer read.
                    if (err != error.Truncated or got < want or want >= cap) break;
                    want = @min(cap, want * 2);
                }
            }
        }
        return self.emitJpegGeometry(&acc, ifd_index);
    }

    /// Emit one corrupt finding 19 per rule `acc` saw violated; true if any.
    fn emitJpegGeometry(self: *Decoder, acc: *const jpeg_geometry.Accumulator, ifd_index: usize) bool {
        var any = false;
        inline for (@typeInfo(jpeg_geometry.Rule).@"enum".fields) |field| {
            if (acc.record(@enumFromInt(field.value))) |r| {
                any = true;
                self.noteDiscrepancy(.@"error", r.sof_offset, "jpeg_segment_geometry_invalid");
                var buf: [jpeg_geometry.payload_len]u8 = undefined;
                self.emitDetailed(
                    .tiffz,
                    @intCast(@intFromEnum(findings_mod.InfoFinding.jpeg_segment_geometry_invalid)),
                    null,
                    .corrupt,
                    r.sof_offset,
                    null,
                    true,
                    jpeg_geometry.encodePayload(r, @intCast(ifd_index), &buf),
                );
            }
        }
        return any;
    }

    const ChunkLayout = struct {
        kind: ChunkKind,
        offsets_tag: u16,
        counts_tag: u16,
        count: u32,
        tolerated_tiled_tags: bool,
    };

    /// Resolve one unambiguous chunk layout. Canonical tile arrays always win;
    /// the compatibility route requires complete tile geometry, no canonical
    /// tile arrays, and both complete strip arrays.
    fn chunkLayout(self: *Decoder, dir: *const Ifd) errors.Error!?ChunkLayout {
        const tile_offsets = dir.get(tags.tile_offsets);
        const tile_counts = dir.get(tags.tile_byte_counts);
        if (tile_offsets != null or tile_counts != null) {
            const offsets = tile_offsets orelse return error.Malformed;
            const counts = tile_counts orelse return error.Malformed;
            if (offsets.count != counts.count) return error.Malformed;
            if (offsets.count > self.limits.max_strips_or_tiles) return error.LimitExceededStripCount;
            return .{
                .kind = .tile,
                .offsets_tag = tags.tile_offsets,
                .counts_tag = tags.tile_byte_counts,
                .count = @intCast(offsets.count),
                .tolerated_tiled_tags = false,
            };
        }

        const tile_width = dir.get(tags.tile_width);
        const tile_length = dir.get(tags.tile_length);
        const strip_offsets = dir.get(tags.strip_offsets);
        const strip_counts = dir.get(tags.strip_byte_counts);
        if (tile_width != null or tile_length != null) {
            if (tile_width == null or tile_length == null) return error.Malformed;
            const offsets = strip_offsets orelse return error.Malformed;
            const counts = strip_counts orelse return error.Malformed;
            if (offsets.count != counts.count) return error.Malformed;
            if (offsets.count > self.limits.max_strips_or_tiles) return error.LimitExceededStripCount;
            return .{
                .kind = .tile,
                .offsets_tag = tags.strip_offsets,
                .counts_tag = tags.strip_byte_counts,
                .count = @intCast(offsets.count),
                .tolerated_tiled_tags = true,
            };
        }

        if (strip_offsets != null or strip_counts != null) {
            const offsets = strip_offsets orelse return error.Malformed;
            const counts = strip_counts orelse return error.Malformed;
            if (offsets.count != counts.count) return error.Malformed;
            if (offsets.count > self.limits.max_strips_or_tiles) return error.LimitExceededStripCount;
            return .{
                .kind = .strip,
                .offsets_tag = tags.strip_offsets,
                .counts_tag = tags.strip_byte_counts,
                .count = @intCast(offsets.count),
                .tolerated_tiled_tags = false,
            };
        }
        return null;
    }

    /// Enforce the declared decoded extent and emit the bounded-padding warning
    /// only when a short final strip stays within one full RowsPerStrip chunk.
    fn acceptDecodedExtent(self: *Decoder, ext: ExpectedExtent, written: usize) errors.Error!void {
        if (written < ext.min or written > ext.max) return error.Malformed;
        if (ext.warn_if_above_min and written > ext.min and !self.final_strip_padding_fired) {
            self.final_strip_padding_fired = true;
            // Payload: excess bytes (written − logical) as LE u32, so callers can render
            // "final strip padded by N bytes". `written > ext.min` is guaranteed above;
            // saturate the (bounded) difference into u32 defensively.
            const excess: u32 = std.math.cast(u32, written - ext.min) orelse std.math.maxInt(u32);
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, excess, .little);
            self.emitDetailed(
                .tiffz,
                @intFromEnum(findings_mod.InfoFinding.final_strip_padding_tolerated),
                null,
                .valid,
                self.active_chunk_offset,
                null,
                self.active_chunk_offset != null,
                &buf,
            );
            self.noteDiscrepancy(.warning, self.active_chunk_offset, "final_strip_padding_tolerated");
        }
    }

    /// Reclassify strict LZW `SourceTooShort` only when the shared core proves
    /// a clean EOF at one exact container-approved extent.
    fn validateMissingLzwEod(
        self: *Decoder,
        dir: *const Ifd,
        ifd_index: usize,
        layout: ChunkLayout,
        chunk_index: u32,
        ext: ExpectedExtent,
        workspace: *Workspace,
    ) errors.Error!?usize {
        const compression = (try readScalarU16(dir.*, tags.compression, self.endian)) orelse tags.compression_none;
        if (compression != tags.compression_lzw) return null;

        const offset = try dir.arrayElementU64(layout.offsets_tag, chunk_index, self.endian, self.source);
        const byte_count_u64 = try dir.arrayElementU64(layout.counts_tag, chunk_index, self.endian, self.source);
        if (byte_count_u64 > self.limits.max_compressed_strip_bytes or byte_count_u64 > std.math.maxInt(usize)) {
            return self.compressedChunkTooLarge(offset, byte_count_u64);
        }
        const byte_count: usize = @intCast(byte_count_u64);
        const compressed = workspace.ensureScratch(byte_count) catch return error.OutOfMemory;
        const got = self.source.readAt(compressed, offset) catch |err| return parser.source.preserveReadError(err);
        if (got < byte_count) return error.SourceShortRead;

        const src = compressed[0..byte_count];
        const accepted = compatibleLzwExtent(lzwz.Profile.tiff6(), src, ext) catch |first_err| switch (first_err) {
            // Preserve the decoder's existing legacy fallback boundary: only
            // a malformed TIFF-6 code stream is retried as old-style LZW.
            error.MalformedCode => compatibleLzwExtent(lzwz.Profile.tiffLegacy(), src, ext) catch |legacy_err| switch (legacy_err) {
                error.IncompleteSource => return error.SourceTooShort,
                error.MalformedCode, error.DecodedLengthMismatch, error.DestTooSmall => return error.Malformed,
            },
            error.IncompleteSource => return error.SourceTooShort,
            error.DecodedLengthMismatch, error.DestTooSmall => return error.Malformed,
        };
        const expected = accepted orelse return null;
        _ = try self.readPredictorMeta(ifd_index, try self.chunkPlane(dir, layout.kind, chunk_index));
        if (!self.lzw_missing_eod_fired) {
            self.lzw_missing_eod_fired = true;
            self.emitDetailed(
                .tiffz,
                @intFromEnum(findings_mod.InfoFinding.lzw_missing_eod_tolerated),
                null,
                .valid,
                self.active_chunk_offset,
                null,
                self.active_chunk_offset != null,
                &.{},
            );
        }
        return expected;
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
        try enforceRasterLimits(self, image_width, image_length, samples);
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
                if (tile_width > self.limits.max_dim or tile_length > self.limits.max_dim) return error.LimitExceededDimension;
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
        return boundedFinalStripExtent(
            bytes_per_row,
            @as(usize, shape.rows),
            if (kind == .strip) @as(usize, shape.full_rows) else @as(usize, shape.rows),
            self.limits.max_decompressed_strip_bytes,
        );
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

    /// The one BitsPerSample every sample shares, for a codec whose output has
    /// a single depth (a JPEG frame has one precision). Absent means 1 (TIFF
    /// 6.0 p. 29). Mixed depths are UnsupportedBitDepth, and a depth above 16
    /// cannot hold a JPEG sample, so it is UnsupportedBitDepth too.
    fn uniformBitsPerSample(self: *Decoder, dir: *const Ifd, samples: u16) errors.Error!u16 {
        const entry = dir.get(tags.bits_per_sample) orelse return 1;
        if (entry.field_type != .short) return error.UnsupportedTagType;
        if (entry.count != 1 and entry.count != samples) return error.Malformed;
        const first = try dir.arrayElementU64(tags.bits_per_sample, 0, self.endian, self.source);
        var index: u16 = 1;
        while (index < entry.count) : (index += 1) {
            if (try dir.arrayElementU64(tags.bits_per_sample, index, self.endian, self.source) != first) {
                return error.UnsupportedBitDepth;
            }
        }
        if (first == 0) return error.Malformed;
        if (first > 16) return error.UnsupportedBitDepth;
        return @intCast(first);
    }

    /// Common shared per-IFD metadata that both strip and tile
    /// predictors need. Read once per call.
    const PredictorMeta = struct {
        predictor: predictors_mod.Predictor,
        samples: u16,
        bps: u16,
        planar: predictors_mod.PlanarConfig,
    };

    fn readPredictorMeta(self: *Decoder, ifd_index: usize, plane_index: u16) errors.Error!?PredictorMeta {
        const dir = try self.ifd(ifd_index);
        const pred_raw = (try readScalarU16(dir.*, tags.predictor, self.endian)) orelse 1;
        if (pred_raw == 1) return null; // no-op fast path

        const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
        const planar_raw = (try readScalarU16(dir.*, tags.planar_configuration, self.endian)) orelse 1;
        const planar: predictors_mod.PlanarConfig = @enumFromInt(planar_raw);

        // Chunky rows interleave every sample, and both predictors take one
        // width for them: TIFF 6.0 p. 65 ("We require that BitsPerSample be
        // the same for all 3 components") and TN3's single bytesPerSample.
        // Mixed widths there are refused before decoding rather than decoded
        // at the first width (validate, 2026-11-05); ifd_conformance names
        // the fault on Predictor. A planar-separate chunk holds one plane,
        // which "works the same as it does for grayscale data" (p. 65), so
        // it is differenced at its own plane's width.
        var bps: u16 = 8;
        if (dir.get(tags.bits_per_sample)) |bps_entry| {
            var buf: [16]u8 = undefined;
            const stride: usize = bps_entry.field_type.elementBytes();
            const need: usize = stride * @as(usize, bps_entry.count);
            if (need > buf.len) return error.Malformed;
            try dir.readEntryValueCached(tags.bits_per_sample, self.endian, self.source, buf[0..need]);
            bps = header_mod.readU16(buf[0..2], self.endian);
            if (stride == 2) {
                var uniform = true;
                var i: usize = 1;
                while (i < bps_entry.count) : (i += 1) {
                    if (header_mod.readU16(buf[i * 2 ..][0..2], self.endian) != bps) uniform = false;
                }
                if (!uniform) {
                    if (planar_raw != tags.planar_separate) return error.UnsupportedBitDepth;
                    if (plane_index >= bps_entry.count) return error.Malformed;
                    bps = header_mod.readU16(buf[@as(usize, plane_index) * 2 ..][0..2], self.endian);
                }
            }
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
        const dir = try self.ifd(ifd_index);
        const meta = (try self.readPredictorMeta(ifd_index, try self.chunkPlane(dir, .strip, strip_index))) orelse return;
        const width = (try readScalarU32(dir.*, tags.image_width, self.endian)) orelse return error.Malformed;
        const length = (try readScalarU32(dir.*, tags.image_length, self.endian)) orelse return error.Malformed;
        const rps_raw = (try readScalarU32(dir.*, tags.rows_per_strip, self.endian)) orelse length;
        const rps: u32 = if (rps_raw > length) length else rps_raw;
        // Same planar-separate band reduction as decodeStripRaw (see stripRowSpan).
        const this_rows: u32 = stripRowSpan(length, rps, strip_index);
        try predictors_mod.applyInverse(bytes, meta.predictor, width, this_rows, meta.samples, meta.bps, meta.planar, self.endian, self.allocator);
    }

    /// Run the inverse Predictor transform over a just-decoded tile.
    /// Tile rows = TileLength regardless of image edge — the encoder
    /// pads tile data past the image edge to the full tile dimensions,
    /// so the predictor reverses across the FULL tile.
    fn applyPredictorTile(self: *Decoder, ifd_index: usize, tile_index: u32, bytes: []u8) errors.Error!void {
        const dir = try self.ifd(ifd_index);
        const meta = (try self.readPredictorMeta(ifd_index, try self.chunkPlane(dir, .tile, tile_index))) orelse return;
        const tile_w = (try readScalarU32(dir.*, tags.tile_width, self.endian)) orelse return error.Malformed;
        const tile_h = (try readScalarU32(dir.*, tags.tile_length, self.endian)) orelse return error.Malformed;
        try predictors_mod.applyInverse(bytes, meta.predictor, tile_w, tile_h, meta.samples, meta.bps, meta.planar, self.endian, self.allocator);
    }

    /// The plane a chunk belongs to. Planar-separate chunks are stored plane
    /// by plane, each plane a full set of strips or tiles (TIFF 6.0 pp. 38
    /// and 68); chunky data is one plane. The geometry is the same that
    /// stripRowSpan and the decoded-extent check use.
    fn chunkPlane(self: *Decoder, dir: *const Ifd, kind: ChunkKind, chunk_index: u32) errors.Error!u16 {
        const planar_raw = (try readScalarU16(dir.*, tags.planar_configuration, self.endian)) orelse 1;
        if (planar_raw != tags.planar_separate) return 0;
        const image_width = (try readScalarU32(dir.*, tags.image_width, self.endian)) orelse return error.Malformed;
        const image_length = (try readScalarU32(dir.*, tags.image_length, self.endian)) orelse return error.Malformed;
        const per_plane: u32 = switch (kind) {
            .strip => blk: {
                const rps_raw = (try readScalarU32(dir.*, tags.rows_per_strip, self.endian)) orelse image_length;
                break :blk try ceilDivU32(image_length, @min(rps_raw, image_length));
            },
            .tile => blk: {
                const tile_w = (try readScalarU32(dir.*, tags.tile_width, self.endian)) orelse return error.Malformed;
                const tile_h = (try readScalarU32(dir.*, tags.tile_length, self.endian)) orelse return error.Malformed;
                const across = try ceilDivU32(image_width, tile_w);
                const down = try ceilDivU32(image_length, tile_h);
                break :blk std.math.mul(u32, across, down) catch return error.Malformed;
            },
        };
        if (per_plane == 0) return error.Malformed;
        return std.math.cast(u16, chunk_index / per_plane) orelse error.Malformed;
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
        const layout = (try self.chunkLayout(dir)) orelse return error.Malformed;
        if (layout.kind != .strip) return error.UnsupportedTagType;
        if (strip_index >= layout.count) return error.InvalidArgument;

        const offset = try dir.arrayElementU64(layout.offsets_tag, strip_index, self.endian, self.source);
        const byte_count_u64 = try dir.arrayElementU64(layout.counts_tag, strip_index, self.endian, self.source);
        if (ifd_mod.endsPastFile(self.source, offset, byte_count_u64)) return self.chunkPastEnd(dir, ifd_index, layout, offset, byte_count_u64);
        if (byte_count_u64 > self.limits.max_compressed_strip_bytes) {
            return self.compressedChunkTooLarge(offset, byte_count_u64);
        }
        const byte_count: u32 = @intCast(byte_count_u64);

        // CCITT needs to know the per-chunk row+width. For strips
        // these come from ImageWidth + clamped RowsPerStrip × strip_index.
        const width = (try readScalarU32(dir.*, tags.image_width, self.endian)) orelse return error.Malformed;
        const length = (try readScalarU32(dir.*, tags.image_length, self.endian)) orelse return error.Malformed;
        const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
        if (samples == 0) return error.Malformed;
        try enforceRasterLimits(self, width, length, samples);
        const rps_raw = (try readScalarU32(dir.*, tags.rows_per_strip, self.endian)) orelse length;
        const rps: u32 = if (rps_raw > length) length else rps_raw;
        // Resolve the planar-separate plane band before the row math (see
        // stripRowSpan) — a naive length - strip_index*rps underflows on the
        // 2nd+ plane when StripOffsets spans all sample planes.
        const this_rows: u32 = stripRowSpan(length, rps, strip_index);

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
        const layout = (try self.chunkLayout(dir)) orelse return error.Malformed;
        if (layout.kind != .tile) return error.UnsupportedTagType;
        if (tile_index >= layout.count) return error.InvalidArgument;

        const offset = try dir.arrayElementU64(layout.offsets_tag, tile_index, self.endian, self.source);
        const byte_count_u64 = try dir.arrayElementU64(layout.counts_tag, tile_index, self.endian, self.source);
        if (ifd_mod.endsPastFile(self.source, offset, byte_count_u64)) return self.chunkPastEnd(dir, ifd_index, layout, offset, byte_count_u64);
        if (byte_count_u64 > self.limits.max_compressed_strip_bytes) {
            return self.compressedChunkTooLarge(offset, byte_count_u64);
        }
        const byte_count: u32 = @intCast(byte_count_u64);

        const image_width = (try readScalarU32(dir.*, tags.image_width, self.endian)) orelse return error.Malformed;
        const image_length = (try readScalarU32(dir.*, tags.image_length, self.endian)) orelse return error.Malformed;
        const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
        if (samples == 0) return error.Malformed;
        try enforceRasterLimits(self, image_width, image_length, samples);
        const tile_w = (try readScalarU32(dir.*, tags.tile_width, self.endian)) orelse return error.Malformed;
        const tile_h = (try readScalarU32(dir.*, tags.tile_length, self.endian)) orelse return error.Malformed;
        if (tile_w == 0 or tile_h == 0) return error.Malformed;
        if (tile_w > self.limits.max_dim or tile_h > self.limits.max_dim) return error.LimitExceededDimension;

        return self.decodeBytes(dir, .{
            .offset = offset,
            .byte_count = byte_count,
            .width = tile_w,
            .rows = tile_h,
        }, dest, workspace);
    }

    /// Single source of truth for which Compression codes tiffz decodes.
    /// Drives BOTH the `decodeBytes` dispatch guard below AND the walk's
    /// code-16 partial-coverage skip (`unsupported_compression_skipped`), so
    /// the two can never classify a code differently. Old-style JPEG (6) is
    /// deliberately absent forever (SPEC §3; Peter re-affirmed 2026-08-27).
    pub const supported_compressions = [_]u16{
        tags.compression_none,
        tags.compression_ccitt_rle,
        tags.compression_next,
        tags.compression_thunderscan,
        tags.compression_sgilog,
        tags.compression_sgilog24,
        tags.compression_ccitt_t4,
        tags.compression_ccitt_t6,
        tags.compression_lzw,
        tags.compression_jpeg,
        tags.compression_deflate,
        tags.compression_deflate_adobe,
        tags.compression_packbits,
        tags.compression_zstd,
        tags.compression_lerc,
        tags.compression_dng_lossy_jpeg,
        tags.compression_jpegxl,
        tags.compression_dng_jpegxl,
    };

    /// True iff `decodeBytes` has a real codec for this Compression code.
    /// Doc-search terms: unsupported compression, OJPEG, coverage skip.
    pub fn compressionSupported(comp: u16) bool {
        inline for (supported_compressions) |c| {
            if (comp == c) return true;
        }
        return false;
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
            return self.compressedChunkTooLarge(offset, byte_count);
        }

        // Predicate/dispatch agreement guard: if `supported_compressions`
        // claims support the switch below MUST have an arm, and vice versa.
        // A code missing from the list never reaches its arm (loud
        // UnsupportedCompression from a codec's own fixture test); a listed
        // code with no arm falls to the `else` (same loud error). Either
        // drift direction fails a committed test rather than silently
        // widening the walk's code-16 skip.
        if (!compressionSupported(comp)) return error.UnsupportedCompression;

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
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
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
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
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
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
                if (got < byte_count) break :blk error.SourceShortRead;

                var rows_done: u32 = 0;
                const written = compressions_ccitt_t6.decode(
                    self.allocator,
                    scratch,
                    dest,
                    ext.width,
                    ext.rows,
                    fill,
                    &rows_done,
                ) catch |e| {
                    if (e == error.EndOfFacsimileBlock) self.facsimile_rows = rows_done;
                    break :blk e;
                };
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
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
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
            tags.compression_sgilog, tags.compression_sgilog24 => blk: {
                // SGILog (34676) and SGILog24 (34677) decoded to the 16-bit
                // signed samples the directory declares: LogL with one sample
                // (34676 only) or LogLuv with three, chunky. Other layouts (a
                // float or 8-bit RGB reading, or planes) are not decoded.
                const photo = (try readScalarU16(dir.*, tags.photometric, self.endian)) orelse return error.Malformed;
                const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
                const planar = (try readScalarU16(dir.*, tags.planar_configuration, self.endian)) orelse tags.planar_chunky;
                const kind: compressions_sgilog.Kind = if (comp == tags.compression_sgilog and photo == tags.photometric_log_l and samples == 1)
                    .log_l
                else if (photo == tags.photometric_log_luv and samples == 3)
                    if (comp == tags.compression_sgilog24) .log_luv24 else .log_luv
                else
                    break :blk error.UnsupportedCompression;
                if (planar != tags.planar_chunky) break :blk error.UnsupportedCompression;
                if ((self.uniformBitsPerSample(dir, samples) catch |e| break :blk e) != 16) break :blk error.UnsupportedBitDepth;
                const format_entry = dir.get(tags.sample_format) orelse break :blk error.UnsupportedBitDepth;
                var index: u16 = 0;
                while (index < format_entry.count) : (index += 1) {
                    const format = dir.arrayElementU64(tags.sample_format, index, self.endian, self.source) catch |e| break :blk e;
                    if (format != 2) break :blk error.UnsupportedBitDepth;
                }
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = compressions_sgilog.decode(scratch, dest, ext.width, ext.rows, kind, self.endian) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_next, tags.compression_thunderscan => blk: {
                // NeXT (32766) and ThunderScan (32809): one-sample gray at a
                // single depth each, 2 and 4 bits. Neither has a published
                // specification; see the codec modules.
                const depth: u16 = if (comp == tags.compression_next) 2 else 4;
                const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
                if (samples != 1 or (self.uniformBitsPerSample(dir, samples) catch |e| break :blk e) != depth) {
                    break :blk error.UnsupportedBitDepth;
                }
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = (if (comp == tags.compression_next)
                    compressions_next.decode(scratch, dest, ext.width, ext.rows)
                else
                    compressions_thunderscan.decode(scratch, dest, ext.width, ext.rows)) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_ccitt_rle => blk: {
                // CCITT modified Huffman (Compression 2, TIFF 6.0 section 10):
                // T.4 one-dimensional codes, no EOL, rows byte-aligned. It has
                // no options tag; FillOrder applies as for Compression 3.
                const fill_raw = (try readScalarU16(dir.*, tags.fill_order, self.endian)) orelse 1;
                const fill: compressions_ccitt_t4.FillOrder = switch (fill_raw) {
                    1 => .msb_first,
                    2 => .lsb_first,
                    else => break :blk error.Malformed,
                };
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
                if (got < byte_count) break :blk error.SourceShortRead;
                const written = compressions_ccitt_t4.decodeModifiedHuffman(scratch, dest, ext.width, ext.rows, fill) catch |e| break :blk e;
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
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
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
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
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
                const got = self.source.readAt(src_buf, offset) catch |err| break :blk parser.source.preserveReadError(err);
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
            tags.compression_jpeg, tags.compression_dng_lossy_jpeg => blk: {
                // JPEG-in-TIFF (Compression=7, TIFF Tech Note 2), and DNG's
                // Lossy JPEG (34892, DNG 1.4.0.0; DNG 1.6.0.0 p. 20).
                // Supports photometric=RGB (2), YCbCr (6), and the single-
                // component BlackIsZero (1) and CFA (32803).
                // CAVEAT: the cleanroom JPEG codec (jpegz.decode)
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
                // DNG's raw photometrics, CFA and LinearRaw, store sensor or
                // linear samples. BlackIsZero is grayscale JPEG-in-TIFF, what
                // libtiff and GDAL write for gray pages. All three take the
                // checked stored-sample path: the JPEG samples are the chunk's
                // samples, unchanged.
                //
                // Lossy JPEG (34892) "is allowed for IFDs that use 8-bit integer
                // data and one of the following PhotometricInterpretation values:
                // 34892 (LinearRaw), 52527 (PhotometricMask)" (DNG 1.6.0.0 p. 20).
                // It is a baseline JPEG read with a lossy decoder, so LinearRaw
                // takes the color-converting path RGB and YCbCr take, and a mask
                // is a one-component gray decode. Another photometric under
                // 34892 is not decoded.
                const lossy_dng = comp == tags.compression_dng_lossy_jpeg;
                if (lossy_dng and photo != tags.photometric_linear_raw and photo != tags.photometric_mask) {
                    break :blk error.UnsupportedCompression;
                }
                const raw_samples = !lossy_dng and (photo == tags.photometric_color_filter_array or
                    photo == tags.photometric_linear_raw);
                const gray = photo == tags.photometric_black_is_zero or (lossy_dng and photo == tags.photometric_mask);
                const stored_samples = raw_samples or gray;
                const converted = photo == tags.photometric_rgb or photo == tags.photometric_ycbcr or
                    (lossy_dng and photo == tags.photometric_linear_raw);
                if (!converted and !stored_samples) {
                    break :blk error.UnsupportedCompression;
                }

                // Read strip bytes into scratch.
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
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

                var prepared = compressions_jpeg.prepareStream(self.allocator, scratch, tables_slice) catch |e| break :blk e;
                defer prepared.deinit(self.allocator);

                var validation = compressions_jpeg.jpegz.validate(self.allocator, prepared.bytes) catch break :blk error.OutOfMemory;
                defer validation.deinit(self.allocator);
                var corrupt = false;
                for (validation.findings.items) |finding| {
                    const verdict = findings_mod.classicFindingVerdict(finding.code, finding.severity);
                    if (verdict == .corrupt) corrupt = true;
                    const host_offset = if (finding.offset) |leaf_offset|
                        prepared.hostOffset(leaf_offset, offset)
                    else
                        null;
                    self.emitDetailed(
                        .jpegz,
                        @intCast(@intFromEnum(finding.code)),
                        null,
                        verdict,
                        finding.offset,
                        host_offset,
                        host_offset != null,
                        finding.detail orelse &.{},
                    );
                }
                if (corrupt or !validation.isValid()) break :blk error.JpegInTiffPayload;

                if (stored_samples) {
                    // Only a checked decode is stored samples. An unchecked
                    // variant keeps jpegz's reach finding and does not become RGB.
                    if (validation.codec_check != .decoded) break :blk error.UnsupportedCompression;
                    const img = compressions_jpeg.jpegz.decode(self.allocator, prepared.bytes) catch |e| switch (e) {
                        error.OutOfMemory => break :blk error.OutOfMemory,
                        // jpegz validated the stream but has no decoder for its
                        // variant: a limit of the checker, not a defect.
                        error.NotImplemented => break :blk error.UnsupportedCompression,
                        else => break :blk error.JpegInTiffPayload,
                    };
                    defer self.allocator.free(img.pixels);
                    // A gray page is one component. A raw IFD's lossless stream
                    // may have another width, length or component count, "Only
                    // the total sample counts need to match" (DNG 1.6.0.0 p. 20),
                    // which storeSamples enforces row by row. Several components
                    // must be lossless Huffman (the same page): a lossy decode of
                    // several components may be color-converted, so it is not
                    // stored samples.
                    if (gray and (img.layout != .grayscale or img.channels != 1)) break :blk error.UnsupportedCompression;
                    if (img.channels != 1 and validation.variant != .lossless_huffman) break :blk error.UnsupportedCompression;
                    const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
                    const planar = (try readScalarU16(dir.*, tags.planar_configuration, self.endian)) orelse tags.planar_chunky;
                    const bps = self.uniformBitsPerSample(dir, samples) catch |e| break :blk e;
                    const row_samples: usize = if (planar == tags.planar_separate)
                        ext.width
                    else
                        @as(usize, ext.width) * samples;
                    const written = compressions_jpeg.storeSamples(img, bps, row_samples, self.endian, dest) catch |e| break :blk e;
                    if (written > self.limits.max_decompressed_strip_bytes) {
                        break :blk error.LimitExceededDecompressedStripBytes;
                    }
                    break :blk written;
                }

                // jpegz returns RGB (YCbCr converted), so a chunk row holds
                // three samples per pixel. The depth is read only for a decode
                // wider than 8 bits, which jpegz returns as host-order u16.
                const wide: compressions_jpeg.WideLayout = .{
                    .bps = self.uniformBitsPerSample(dir, (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1),
                    .row_samples = @as(usize, ext.width) * 3,
                    .endian = self.endian,
                };
                const written = compressions_jpeg.decodePrepared(self.allocator, prepared.bytes, wide, dest) catch |e| break :blk e;
                if (written > self.limits.max_decompressed_strip_bytes) {
                    break :blk error.LimitExceededDecompressedStripBytes;
                }
                break :blk written;
            },
            tags.compression_jpegxl, tags.compression_dng_jpegxl => blk: {
                // JPEG XL (50002, GDAL and libtiff; 52546, DNG 1.7): each strip
                // or tile is one JPEG XL stream holding the chunk's samples.
                // libjxlz validates it, its findings are forwarded, then the
                // first frame is decoded and stored as an uncompressed chunk
                // holds it. The frame must have the chunk's width, length,
                // sample count and depth. Float samples, extra channels the
                // decoder cannot return, and a build without JPEG XL are reach.
                const scratch = workspace.ensureScratch(byte_count) catch break :blk error.OutOfMemory;
                const got = self.source.readAt(scratch, offset) catch |err| break :blk parser.source.preserveReadError(err);
                if (got < byte_count) break :blk error.SourceShortRead;

                var validation = compressions_jpeg.jpegz.jpegxl.validate(self.allocator, scratch, compressions_jpeg.jpegz.jpegxl.default_options) catch break :blk error.OutOfMemory;
                defer validation.deinit(self.allocator);
                var corrupt = false;
                for (validation.findings.items) |finding| {
                    const verdict = findings_mod.strictFindingVerdict(finding);
                    if (verdict == .corrupt) corrupt = true;
                    const source: findings_mod.SourceDecoder = switch (finding.source) {
                        .jpegz => .jpegz,
                        .jp2z => .jp2z,
                        .libjxlz => .libjxlz,
                    };
                    const host_offset = if (finding.offset) |leaf| offset +| leaf else null;
                    self.emitDetailed(
                        source,
                        @intCast(finding.leaf_code),
                        if (finding.code) |code| @intCast(@intFromEnum(code)) else null,
                        verdict,
                        finding.offset,
                        host_offset,
                        finding.offset_is_exact and host_offset != null,
                        finding.detail orelse &.{},
                    );
                }
                if (corrupt) break :blk error.JpegInTiffPayload;

                var decoded = compressions_jpeg.jpegz.jpegxl.decode(self.allocator, scratch) catch |e| switch (e) {
                    error.OutOfMemory => break :blk error.OutOfMemory,
                    error.NotImplemented, error.UnsupportedPrecision => break :blk error.UnsupportedCompression,
                    error.TruncatedStream, error.BackendError => break :blk error.JpegInTiffPayload,
                };
                defer decoded.deinit(self.allocator);
                if (decoded.extra_channels_dropped != 0) break :blk error.UnsupportedCompression;
                const img = decoded.image;
                const samples = (try readScalarU16(dir.*, tags.samples_per_pixel, self.endian)) orelse 1;
                const planar = (try readScalarU16(dir.*, tags.planar_configuration, self.endian)) orelse tags.planar_chunky;
                const chunk_samples: u16 = if (planar == tags.planar_separate) 1 else samples;
                const bps = self.uniformBitsPerSample(dir, samples) catch |e| break :blk e;
                if (img.width != ext.width or img.height != ext.rows or img.channels != chunk_samples or img.bits_per_sample != bps) {
                    break :blk error.Malformed;
                }
                const written = compressions_jpeg.storeSamples(img, bps, @as(usize, ext.width) * chunk_samples, self.endian, dest) catch |e| break :blk e;
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
/// bounded trailing padding (e.g. a final strip padded up to a full
/// RowsPerStrip). `warn_if_above_min` distinguishes tolerated nonconformance
/// from spec-defined subsampled extents.
const ExpectedExtent = struct {
    min: usize,
    max: usize,
    warn_if_above_min: bool = false,
};

/// Bound a strip between its logical rows and the stored padding TIFF allows.
/// A short final strip may reach one full RowsPerStrip chunk. A complete
/// chunk may carry one further row of trailing bytes: StripByteCounts is
/// the stored length, and the sample grid stays `min`. Bytes past that row
/// stay Malformed.
fn boundedFinalStripExtent(
    bytes_per_row: usize,
    logical_rows: usize,
    full_rows: usize,
    max_bytes: usize,
) errors.Error!ExpectedExtent {
    if (logical_rows > full_rows) return error.Malformed;
    const min = try checkedMul(bytes_per_row, logical_rows);
    const full = try checkedMul(bytes_per_row, full_rows);
    if (logical_rows == full_rows) {
        if (full_rows == std.math.maxInt(usize)) return error.Malformed;
        const max = try checkedMul(bytes_per_row, full_rows + 1);
        if (max > max_bytes) return error.LimitExceededDecompressedStripBytes;
        return .{ .min = min, .max = max, .warn_if_above_min = true };
    }
    if (full > max_bytes) return error.LimitExceededDecompressedStripBytes;
    return .{
        .min = min,
        .max = full,
        .warn_if_above_min = true,
    };
}

/// Classify a missing LZW end marker over the complete bounded extent set.
/// A clean EOF at neither exact bound returns null; entropy errors remain
/// errors so an adapter cannot turn malformed data into a warning.
fn compatibleLzwExtent(
    profile: lzwz.Profile,
    src: []const u8,
    ext: ExpectedExtent,
) lzwz.DecodeError!?usize {
    const candidates = [_]usize{ ext.min, ext.max };
    for (candidates, 0..) |expected, index| {
        if (index == 1 and ext.max == ext.min) continue;
        const result = lzwz.decodeExactExtentAllowMissingEnd(profile, src, expected) catch |err| switch (err) {
            error.DecodedLengthMismatch => continue,
            else => return err,
        };
        if (result.end_status != .clean_eof_without_end) return error.MalformedCode;
        return expected;
    }
    return null;
}

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

/// Stop a declared width, height, or sample count before a later
/// multiply can wrap. `max_dim` and `max_total_samples` are inclusive caps.
fn enforceRasterLimits(self: *Decoder, width: u32, length: u32, samples: u16) errors.Error!void {
    if (width == 0 or length == 0 or samples == 0) return error.Malformed;
    if (width > self.limits.max_dim or length > self.limits.max_dim) return error.LimitExceededDimension;
    const width_u: u64 = width;
    const length_u: u64 = length;
    if (length_u > std.math.maxInt(u64) / width_u) return error.LimitExceededTotalSamples;
    const area = width_u * length_u;
    const samples_u: u64 = samples;
    if (samples_u > std.math.maxInt(u64) / area) return error.LimitExceededTotalSamples;
    if (area * samples_u > self.limits.max_total_samples) return error.LimitExceededTotalSamples;
}

/// Scan-lines contributed by one strip, correct for both PlanarConfiguration
/// values. For planar=separate, StripOffsets spans every sample plane
/// (total strips = ceil(length/rps) × SamplesPerPixel), so a raw
/// `length - strip_index*rps` runs off the end of the image on the 2nd+ plane —
/// a u32 underflow (the ReleaseSafe-only crasher Einstein caught 2026-07-29;
/// under ReleaseFast it wrapped huge and the very next @min clamp masked it into
/// the right answer by accident). Reducing the index into its own plane band via
/// `strip_index % strips_per_plane` fixes it; for chunky, strips_per_plane ==
/// total strips so the modulo is a no-op. The plane count is `ceil(length/rps)`
/// via division, not `length + rps - 1`, which wraps when both are near u32 max
/// and then divides by zero. rps==0 / length==0 yield 0 rows.
fn stripRowSpan(length: u32, rps: u32, strip_index: u32) u32 {
    if (rps == 0 or length == 0) return 0;
    // ceil(length / rps) without `length + rps - 1`, which wraps at u32 max
    // and then divides by zero.
    const strips_per_plane = length / rps + @intFromBool(length % rps != 0);
    const band = strip_index % strips_per_plane;
    const remaining_rows = length - band * rps; // > 0: band*rps < length by ceil
    return @min(rps, remaining_rows);
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

const BufferHandle = parser.source.BufferHandle;

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

// MFIC: the supported-compression predicate as a classifier over a SET of
// codes, not a presence check — every code the decodeBytes dispatch owns must
// classify supported; the deliberately-never-supported and unknown codes must
// classify unsupported. Oracles are hand-derived from the dispatch switch, so
// adding a codec to one side without the other fails here.
test "compressionSupported: classifier over supported / never-supported / unknown codes" {
    const supported = [_]u16{ 1, 2, 3, 4, 5, 7, 8, 32946, 32773, 32766, 32809, 34676, 34677, 50000, 50002, 52546, 34887, 34892 };
    for (supported) |c| {
        try std.testing.expect(Decoder.compressionSupported(c));
    }
    const unsupported = [_]u16{
        0, // not a legal Compression value
        6, // old-style JPEG (OJPEG) — deliberately never supported, SPEC §3
        9, 10, // T.85 / T.43 reserved
        34712, // JPEG2000-in-TIFF
        34925, // LZMA2
        50001, // WebP
        0xFFFF,
    };
    for (unsupported) |c| {
        try std.testing.expect(!Decoder.compressionSupported(c));
    }
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

/// One uncompressed gray strip. Dimensions above 65535 are stored as LONG
/// so the declared raster, not the on-disk payload, is what the limit sees.
fn writeGrayStrip(buf: []u8, width: u32, length: u32, payload_len: usize) usize {
    const ntags: usize = 7;
    const strip_at: u32 = @intCast(8 + 2 + ntags * 12 + 4);
    @memset(buf, 0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);
    std.mem.writeInt(u16, buf[8..10], @intCast(ntags), .little);
    const dimType = struct {
        fn of(v: u32) u16 {
            return if (v > 65535) 4 else 3;
        }
    }.of;
    const entries = [_]struct { tag: u16, typ: u16, val: u32 }{
        .{ .tag = 256, .typ = dimType(width), .val = width },
        .{ .tag = 257, .typ = dimType(length), .val = length },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 262, .typ = 3, .val = 1 },
        .{ .tag = 273, .typ = 4, .val = strip_at },
        .{ .tag = 279, .typ = 4, .val = @intCast(payload_len) },
    };
    for (entries, 0..) |entry, i| {
        const at = 10 + i * 12;
        std.mem.writeInt(u16, buf[at..][0..2], entry.tag, .little);
        std.mem.writeInt(u16, buf[at + 2 ..][0..2], entry.typ, .little);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u32, buf[at + 8 ..][0..4], entry.val, .little);
    }
    @memset(buf[strip_at..][0..payload_len], 0x5A);
    return strip_at + payload_len;
}

/// One uncompressed 8-bit gray tile. Image size and tile size are independent
/// so the tile-dimension cap can reject a padded tile while the page stays inside it.
fn writeGrayTile(buf: []u8, image_w: u32, image_h: u32, tile_w: u32, tile_h: u32, payload_len: usize) usize {
    const ntags: usize = 9;
    const tile_at: u32 = @intCast(8 + 2 + ntags * 12 + 4);
    @memset(buf, 0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);
    std.mem.writeInt(u16, buf[8..10], @intCast(ntags), .little);
    const entries = [_]struct { tag: u16, typ: u16, val: u32 }{
        .{ .tag = 256, .typ = 3, .val = image_w },
        .{ .tag = 257, .typ = 3, .val = image_h },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 262, .typ = 3, .val = 1 },
        .{ .tag = 322, .typ = 3, .val = tile_w },
        .{ .tag = 323, .typ = 3, .val = tile_h },
        .{ .tag = 324, .typ = 4, .val = tile_at },
        .{ .tag = 325, .typ = 4, .val = @intCast(payload_len) },
    };
    for (entries, 0..) |entry, i| {
        const at = 10 + i * 12;
        std.mem.writeInt(u16, buf[at..][0..2], entry.tag, .little);
        std.mem.writeInt(u16, buf[at + 2 ..][0..2], entry.typ, .little);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u32, buf[at + 8 ..][0..4], entry.val, .little);
    }
    @memset(buf[tile_at..][0..payload_len], 0x5A);
    return tile_at + payload_len;
}

/// Classic TIFF whose next-IFD link is zero and whose tag 330 (LONG) names a
/// nested 1×1 gray page. `child_stored` is that child's strip length: one byte
/// matches the declared pixel, zero is short of it. The child is not on the chain.
fn writeGrayParentAndChild(buf: []u8, child_stored: u32) usize {
    const parent_bytes: u32 = 2 + 8 * 12 + 4;
    const child_bytes: u32 = 2 + 7 * 12 + 4;
    const parent_ifd: u32 = 8;
    const parent_strip: u32 = parent_ifd + parent_bytes;
    const child_ifd: u32 = parent_strip + 1;
    const child_strip: u32 = child_ifd + child_bytes;
    const total: usize = @as(usize, child_strip) + @as(usize, child_stored);
    @memset(buf[0..total], 0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], parent_ifd, .little);

    const Entry = struct { tag: u16, typ: u16, val: u32 };
    const parent_entries = [_]Entry{
        .{ .tag = 256, .typ = 3, .val = 1 },
        .{ .tag = 257, .typ = 3, .val = 1 },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 262, .typ = 3, .val = 1 },
        .{ .tag = 273, .typ = 4, .val = parent_strip },
        .{ .tag = 279, .typ = 4, .val = 1 },
        .{ .tag = 330, .typ = 4, .val = child_ifd },
    };
    std.mem.writeInt(u16, buf[parent_ifd..][0..2], @intCast(parent_entries.len), .little);
    for (parent_entries, 0..) |entry, i| {
        const at: usize = @as(usize, parent_ifd) + 2 + i * 12;
        std.mem.writeInt(u16, buf[at..][0..2], entry.tag, .little);
        std.mem.writeInt(u16, buf[at + 2 ..][0..2], entry.typ, .little);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u32, buf[at + 8 ..][0..4], entry.val, .little);
    }
    buf[parent_strip] = 0x5A;

    const child_entries = [_]Entry{
        .{ .tag = 256, .typ = 3, .val = 1 },
        .{ .tag = 257, .typ = 3, .val = 1 },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 262, .typ = 3, .val = 1 },
        .{ .tag = 273, .typ = 4, .val = child_strip },
        .{ .tag = 279, .typ = 4, .val = child_stored },
    };
    std.mem.writeInt(u16, buf[child_ifd..][0..2], @intCast(child_entries.len), .little);
    for (child_entries, 0..) |entry, i| {
        const at: usize = @as(usize, child_ifd) + 2 + i * 12;
        std.mem.writeInt(u16, buf[at..][0..2], entry.tag, .little);
        std.mem.writeInt(u16, buf[at + 2 ..][0..2], entry.typ, .little);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u32, buf[at + 8 ..][0..4], entry.val, .little);
    }
    if (child_stored > 0) @memset(buf[child_strip..][0..child_stored], 0x5A);
    return total;
}

fn writeClassicEntry(buf: []u8, at: usize, tag: u16, typ: u16, count: u32, val: u32) void {
    std.mem.writeInt(u16, buf[at..][0..2], tag, .little);
    std.mem.writeInt(u16, buf[at + 2 ..][0..2], typ, .little);
    std.mem.writeInt(u32, buf[at + 4 ..][0..4], count, .little);
    std.mem.writeInt(u32, buf[at + 8 ..][0..4], val, .little);
}

/// IFD0 is a valid 1×1 gray page. Tag 330 has `sub_count` values and, when
/// the count is 1, its inline LONG is `sub_off`. No child directory is written.
fn writeGrayParentPointingAt(buf: []u8, sub_off: u32, sub_count: u32) usize {
    const ifd: u32 = 8;
    const strip: u32 = ifd + 2 + 8 * 12 + 4;
    const total: usize = @as(usize, strip) + 1;
    @memset(buf[0..total], 0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], ifd, .little);
    std.mem.writeInt(u16, buf[ifd..][0..2], 8, .little);
    const rows = [_]struct { tag: u16, typ: u16, count: u32, val: u32 }{
        .{ .tag = 256, .typ = 3, .count = 1, .val = 1 },
        .{ .tag = 257, .typ = 3, .count = 1, .val = 1 },
        .{ .tag = 258, .typ = 3, .count = 1, .val = 8 },
        .{ .tag = 259, .typ = 3, .count = 1, .val = 1 },
        .{ .tag = 262, .typ = 3, .count = 1, .val = 1 },
        .{ .tag = 273, .typ = 4, .count = 1, .val = strip },
        .{ .tag = 279, .typ = 4, .count = 1, .val = 1 },
        .{ .tag = 330, .typ = 4, .count = sub_count, .val = sub_off },
    };
    for (rows, 0..) |row, i| {
        writeClassicEntry(buf, @as(usize, ifd) + 2 + i * 12, row.tag, row.typ, row.count, row.val);
    }
    buf[strip] = 0x5A;
    return total;
}

/// IFD0 and IFD1 are chained. Both tag 330 values name one child page.
fn writeTwoParentsSharingChild(buf: []u8) usize {
    const ifd_bytes: u32 = 2 + 8 * 12 + 4;
    const child_bytes: u32 = 2 + 7 * 12 + 4;
    const ifd0: u32 = 8;
    const ifd1: u32 = ifd0 + ifd_bytes;
    const child: u32 = ifd1 + ifd_bytes;
    const strip0: u32 = child + child_bytes;
    const strip1: u32 = strip0 + 1;
    const stripc: u32 = strip1 + 1;
    const total: usize = @as(usize, stripc) + 1;
    @memset(buf[0..total], 0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], ifd0, .little);

    std.mem.writeInt(u16, buf[ifd0..][0..2], 8, .little);
    const parent_rows = [_]struct { tag: u16, val: u32 }{
        .{ .tag = 256, .val = 1 },
        .{ .tag = 257, .val = 1 },
        .{ .tag = 258, .val = 8 },
        .{ .tag = 259, .val = 1 },
        .{ .tag = 262, .val = 1 },
    };
    for (parent_rows, 0..) |row, i| {
        const typ: u16 = if (row.tag == 273 or row.tag == 279 or row.tag == 330) 4 else 3;
        writeClassicEntry(buf, @as(usize, ifd0) + 2 + i * 12, row.tag, typ, 1, row.val);
    }
    writeClassicEntry(buf, @as(usize, ifd0) + 2 + 5 * 12, 273, 4, 1, strip0);
    writeClassicEntry(buf, @as(usize, ifd0) + 2 + 6 * 12, 279, 4, 1, 1);
    writeClassicEntry(buf, @as(usize, ifd0) + 2 + 7 * 12, 330, 4, 1, child);
    std.mem.writeInt(u32, buf[@as(usize, ifd0) + 2 + 8 * 12 ..][0..4], ifd1, .little);

    std.mem.writeInt(u16, buf[ifd1..][0..2], 8, .little);
    for (parent_rows, 0..) |row, i| {
        const typ: u16 = if (row.tag == 273 or row.tag == 279 or row.tag == 330) 4 else 3;
        writeClassicEntry(buf, @as(usize, ifd1) + 2 + i * 12, row.tag, typ, 1, row.val);
    }
    writeClassicEntry(buf, @as(usize, ifd1) + 2 + 5 * 12, 273, 4, 1, strip1);
    writeClassicEntry(buf, @as(usize, ifd1) + 2 + 6 * 12, 279, 4, 1, 1);
    writeClassicEntry(buf, @as(usize, ifd1) + 2 + 7 * 12, 330, 4, 1, child);

    std.mem.writeInt(u16, buf[child..][0..2], 7, .little);
    for (parent_rows, 0..) |row, i| {
        const typ: u16 = if (row.tag == 273 or row.tag == 279 or row.tag == 330) 4 else 3;
        writeClassicEntry(buf, @as(usize, child) + 2 + i * 12, row.tag, typ, 1, row.val);
    }
    writeClassicEntry(buf, @as(usize, child) + 2 + 5 * 12, 273, 4, 1, stripc);
    writeClassicEntry(buf, @as(usize, child) + 2 + 6 * 12, 279, 4, 1, 1);
    buf[strip0] = 0x11;
    buf[strip1] = 0x22;
    buf[stripc] = 0x5A;
    return total;
}

/// The child page is intact and its tag 330 points back at IFD0.
fn writeChildPointingAtParent(buf: []u8) usize {
    const ifd0: u32 = 8;
    const dir_bytes: u32 = 2 + 7 * 12 + 4;
    const strip0: u32 = ifd0 + dir_bytes;
    const child: u32 = strip0 + 1;
    const stripc: u32 = child + dir_bytes;
    const total: usize = @as(usize, stripc) + 1;
    @memset(buf[0..total], 0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], ifd0, .little);
    const rows = [_]struct { tag: u16, typ: u16, val: u32 }{
        .{ .tag = 256, .typ = 3, .val = 1 },
        .{ .tag = 257, .typ = 3, .val = 1 },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 273, .typ = 4, .val = strip0 },
        .{ .tag = 279, .typ = 4, .val = 1 },
        .{ .tag = 330, .typ = 4, .val = child },
    };
    std.mem.writeInt(u16, buf[ifd0..][0..2], 7, .little);
    for (rows, 0..) |row, i| {
        writeClassicEntry(buf, @as(usize, ifd0) + 2 + i * 12, row.tag, row.typ, 1, row.val);
    }
    buf[strip0] = 0x5A;
    const child_rows = [_]struct { tag: u16, typ: u16, val: u32 }{
        .{ .tag = 256, .typ = 3, .val = 1 },
        .{ .tag = 257, .typ = 3, .val = 1 },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 273, .typ = 4, .val = stripc },
        .{ .tag = 279, .typ = 4, .val = 1 },
        .{ .tag = 330, .typ = 4, .val = ifd0 },
    };
    std.mem.writeInt(u16, buf[child..][0..2], 7, .little);
    for (child_rows, 0..) |row, i| {
        writeClassicEntry(buf, @as(usize, child) + 2 + i * 12, row.tag, row.typ, 1, row.val);
    }
    buf[stripc] = 0x5A;
    return total;
}

test "raster limit: ImageLength at u32 max is LimitExceededDimension on decode and validate" {
    // RowsPerStrip is absent, so the row span is the declared length.
    // length + rows-per-strip overflows u32; the pre-limit decode path
    // divided by a wrapped strip count (0) and aborted.
    var storage: [128]u8 = undefined;
    const n = writeGrayStrip(&storage, 1, 0xFFFFFFFF, 1);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    var dest: [1]u8 = undefined;
    try std.testing.expectError(error.LimitExceededDimension, dec.decodeStrip(0, 0, &dest, &ws));
    try std.testing.expectError(error.LimitExceededDimension, dec.validateAllStripsAndTiles(&ws));
}

test "raster limit: ImageWidth above the default max_dim is LimitExceededDimension" {
    var storage: [128]u8 = undefined;
    const n = writeGrayStrip(&storage, (1 << 30) + 1, 1, 1);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    var dest: [1]u8 = undefined;
    try std.testing.expectError(error.LimitExceededDimension, dec.decodeStrip(0, 0, &dest, &ws));
    try std.testing.expectError(error.LimitExceededDimension, dec.validateAllStripsAndTiles(&ws));
}

test "raster limit: sample count above max_total_samples is rejected, and the cap itself still decodes" {
    var limits = Limits.default;
    limits.max_dim = 8;
    limits.max_total_samples = 4;

    var over: [128]u8 = undefined;
    const over_n = writeGrayStrip(&over, 3, 2, 6);
    var over_handle = BufferHandle.init(over[0..over_n]);
    const over_src = Source.fromBuffer(&over_handle);
    var over_dec = try Decoder.openWithLimits(std.testing.allocator, over_src, limits);
    defer over_dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    var dest: [8]u8 = undefined;
    try std.testing.expectError(error.LimitExceededTotalSamples, over_dec.decodeStrip(0, 0, &dest, &ws));
    try std.testing.expectError(error.LimitExceededTotalSamples, over_dec.validateAllStripsAndTiles(&ws));

    var at_cap: [128]u8 = undefined;
    const cap_n = writeGrayStrip(&at_cap, 2, 2, 4);
    var cap_handle = BufferHandle.init(at_cap[0..cap_n]);
    const cap_src = Source.fromBuffer(&cap_handle);
    var cap_dec = try Decoder.openWithLimits(std.testing.allocator, cap_src, limits);
    defer cap_dec.deinit();
    const written = try cap_dec.decodeStrip(0, 0, &dest, &ws);
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqualSlices(u8, &.{ 0x5A, 0x5A, 0x5A, 0x5A }, dest[0..written]);
    try cap_dec.validateAllStripsAndTiles(&ws);
}

test "raster limit: max_dim is inclusive on both axes for strips and tiles" {
    // Custom cap 32 keeps every accepted page small. Strips probe one below,
    // at and one past the cap with the other axis 1. Tiles must be multiples
    // of 16 on both axes (TIFF 6.0 pp. 67-68), so they probe 16, 32 and 48
    // with the other axis 16, on a 1x1 page so that TileWidth/TileLength,
    // not ImageWidth, is the value compared with the cap. Past the cap is
    // LimitExceededDimension before any pixel buffer is required, and within
    // it the page decodes and validates cleanly.
    const cap: u32 = 32;
    var limits = Limits.default;
    limits.max_dim = cap;
    const Axis = enum { width, length };
    const Point = struct { dim: u32, over: bool };
    const strip_points = [_]Point{
        .{ .dim = cap - 1, .over = false },
        .{ .dim = cap, .over = false },
        .{ .dim = cap + 1, .over = true },
    };
    const tile_points = [_]Point{
        .{ .dim = cap - 16, .over = false },
        .{ .dim = cap, .over = false },
        .{ .dim = cap + 16, .over = true },
    };

    var storage: [768]u8 = undefined;
    var dest: [cap * 16]u8 = undefined;
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();

    for ([_]bool{ false, true }) |tiled| {
        const points: []const Point = if (tiled) &tile_points else &strip_points;
        const across: u32 = if (tiled) 16 else 1;
        for ([_]Axis{ .width, .length }) |axis| {
            for (points) |point| {
                const width: u32 = if (axis == .width) point.dim else across;
                const length: u32 = if (axis == .length) point.dim else across;
                const payload: usize = if (point.over) 1 else @as(usize, width) * length;
                const n: usize = if (tiled)
                    writeGrayTile(&storage, 1, 1, width, length, payload)
                else
                    writeGrayStrip(&storage, width, length, payload);
                var handle = BufferHandle.init(storage[0..n]);
                const src = Source.fromBuffer(&handle);
                var dec = try Decoder.openWithLimits(std.testing.allocator, src, limits);
                defer dec.deinit();
                const decoded = if (tiled)
                    dec.decodeTile(0, 0, &dest, &ws)
                else
                    dec.decodeStrip(0, 0, &dest, &ws);
                if (point.over) {
                    try std.testing.expectError(error.LimitExceededDimension, decoded);
                    try std.testing.expectError(error.LimitExceededDimension, dec.validateAllStripsAndTiles(&ws));
                    continue;
                }
                const written = try decoded;
                try std.testing.expectEqual(payload, written);
                for (dest[0..written]) |byte| try std.testing.expectEqual(@as(u8, 0x5A), byte);
                try dec.validateAllStripsAndTiles(&ws);
            }
        }
    }
}

test "tiles that are not multiples of 16 decode, and validation reports them" {
    // TileWidth and TileLength "must be a multiple of 16" (TIFF 6.0 pp. 67-68).
    // A 5x1 tile still decodes; validation fails Malformed after the walk.
    var storage: [160]u8 = undefined;
    var dest: [8]u8 = undefined;
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    const n = writeGrayTile(&storage, 1, 1, 5, 1, 5);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    try std.testing.expectEqual(@as(usize, 5), try dec.decodeTile(0, 0, &dest, &ws));
    try std.testing.expectError(error.Malformed, dec.validateAllStripsAndTiles(&ws));
}

test "SubIFD: an intact uncompressed child decodes to its byte and validates" {
    // Tag 330 is not a next-IFD link. Index 0 stays the parent; index 1 is the child.
    var storage: [224]u8 = undefined;
    const n = writeGrayParentAndChild(&storage, 1);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    var dest: [1]u8 = undefined;
    const parent_n = try dec.decodeStrip(0, 0, &dest, &ws);
    try std.testing.expectEqual(@as(usize, 1), parent_n);
    try std.testing.expectEqual(@as(u8, 0x5A), dest[0]);
    const child_n = try dec.decodeStrip(1, 0, &dest, &ws);
    try std.testing.expectEqual(@as(usize, 1), child_n);
    try std.testing.expectEqual(@as(u8, 0x5A), dest[0]);
    try std.testing.expectEqual(@as(usize, 2), dec.ifdCount());
    try std.testing.expectError(error.InvalidArgument, dec.ifd(2));
    try dec.validateAllStripsAndTiles(&ws);
}

test "SubIFD depth cap: one level keeps the parent and refuses the child" {
    var storage: [224]u8 = undefined;
    const n = writeGrayParentAndChild(&storage, 1);
    var handle = BufferHandle.init(storage[0..n]);
    var limits = Limits.default;
    limits.max_ifd_depth = 1;
    var dec = try Decoder.openWithLimits(std.testing.allocator, Source.fromBuffer(&handle), limits);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectError(error.LimitExceededIfdDepth, dec.validateAllStripsAndTiles(&ws));
    try std.testing.expect(dec.discrepancy == null);
    const progress = dec.limit_progress orelse return error.Bug;
    try std.testing.expectEqual(@as(u64, 111), progress.offset);
    try std.testing.expectEqual(@as(u64, 1), progress.ifd_index);
    try std.testing.expect(progress.bytes > 0);
    var dest: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try dec.decodeStrip(0, 0, &dest, &ws));
    try std.testing.expectEqual(@as(u8, 0x5A), dest[0]);
}

test "bytes-visited cap: the next read after open is a limit, with progress" {
    var storage: [224]u8 = undefined;
    const n = writeGrayParentAndChild(&storage, 1);
    var handle = BufferHandle.init(storage[0..n]);
    var probe = try Decoder.open(std.testing.allocator, Source.fromBuffer(&handle));
    const opened = probe.budget.bytes;
    probe.deinit();

    var limits = Limits.default;
    limits.max_bytes_visited = opened;
    var dec = try Decoder.openWithLimits(std.testing.allocator, Source.fromBuffer(&handle), limits);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectError(error.LimitExceededBytesVisited, dec.validateAllStripsAndTiles(&ws));
    try std.testing.expect(dec.discrepancy == null);
    const progress = dec.limit_progress orelse return error.Bug;
    try std.testing.expectEqual(opened, progress.bytes);
    try std.testing.expectEqual(@as(u64, 111), progress.offset);
    try std.testing.expectEqual(@as(u64, 1), progress.ifd_index);
}

test "depth cap of zero refuses to open" {
    var storage: [224]u8 = undefined;
    const n = writeGrayParentAndChild(&storage, 1);
    var handle = BufferHandle.init(storage[0..n]);
    var limits = Limits.default;
    limits.max_ifd_depth = 0;
    try std.testing.expectError(
        error.LimitExceededIfdDepth,
        Decoder.openWithLimits(std.testing.allocator, Source.fromBuffer(&handle), limits),
    );
}

test "CCITT T.6 early EOFB surfaces EndOfFacsimileBlock and the row count" {
    var storage: [128]u8 = undefined;
    const payload = [_]u8{ 0xC0, 0x04, 0x00, 0x40 };
    const n = writeGrayStrip(&storage, 8, 4, payload.len);
    const bits_at = 10 + 2 * 12 + 8;
    const comp_at = 10 + 3 * 12 + 8;
    std.mem.writeInt(u16, storage[bits_at..][0..2], 1, .little);
    std.mem.writeInt(u16, storage[comp_at..][0..2], 4, .little);
    const strip_at: usize = 8 + 2 + 7 * 12 + 4;
    @memcpy(storage[strip_at..][0..payload.len], &payload);

    var handle = BufferHandle.init(storage[0..n]);
    var dec = try Decoder.open(std.testing.allocator, Source.fromBuffer(&handle));
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    var dest: [4]u8 = undefined;
    try std.testing.expectError(error.EndOfFacsimileBlock, dec.decodeStrip(0, 0, &dest, &ws));
    try std.testing.expectEqual(@as(?u32, 2), dec.facsimile_rows);
    try std.testing.expectError(error.EndOfFacsimileBlock, dec.validateAllStripsAndTiles(&ws));
    const found = dec.discrepancy orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ReportClass.@"error", found.class);
    try std.testing.expectEqualStrings("EndOfFacsimileBlock", found.type_name);
    try std.testing.expectEqual(@as(?u64, strip_at), found.offset);
}

test "SubIFD: a short uncompressed child is Malformed" {
    // The parent strip is a real pixel. The child declares 1×1 and stores nothing.
    var storage: [224]u8 = undefined;
    const n = writeGrayParentAndChild(&storage, 0);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    var dest: [1]u8 = undefined;
    const parent_n = try dec.decodeStrip(0, 0, &dest, &ws);
    try std.testing.expectEqual(@as(usize, 1), parent_n);
    try std.testing.expectEqual(@as(u8, 0x5A), dest[0]);
    try std.testing.expectError(error.Malformed, dec.validateAllStripsAndTiles(&ws));
}

test "SubIFD: tag 330 count 0 adds no page" {
    var storage: [128]u8 = undefined;
    const n = writeGrayParentPointingAt(&storage, 0, 0);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    try dec.validateAllStripsAndTiles(&ws);
    try std.testing.expectEqual(@as(usize, 1), dec.ifdCount());
    try std.testing.expectError(error.InvalidArgument, dec.ifd(1));
}

test "SubIFD: an offset past the file is SourceTooShort" {
    var storage: [128]u8 = undefined;
    const n = writeGrayParentPointingAt(&storage, 0x00FF0000, 1);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectError(error.SourceTooShort, dec.validateAllStripsAndTiles(&ws));
}

test "SubIFD: two parents sharing one child materialize that child once" {
    var storage: [320]u8 = undefined;
    const n = writeTwoParentsSharingChild(&storage);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    var dest: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try dec.decodeStrip(0, 0, &dest, &ws));
    try std.testing.expectEqual(@as(u8, 0x11), dest[0]);
    try std.testing.expectEqual(@as(usize, 1), try dec.decodeStrip(1, 0, &dest, &ws));
    try std.testing.expectEqual(@as(u8, 0x22), dest[0]);
    try std.testing.expectEqual(@as(usize, 1), try dec.decodeStrip(2, 0, &dest, &ws));
    try std.testing.expectEqual(@as(u8, 0x5A), dest[0]);
    try std.testing.expectEqual(@as(usize, 3), dec.ifdCount());
    try std.testing.expectError(error.InvalidArgument, dec.ifd(3));
    try dec.validateAllStripsAndTiles(&ws);
}

test "SubIFD: a pointer at the directory itself is IfdChainCycle" {
    // TIFF 6.0 terminates a chain with a zero next pointer. Tag 330 naming
    // the same directory does not name a new image and does not terminate.
    var storage: [128]u8 = undefined;
    const n = writeGrayParentPointingAt(&storage, 8, 1);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectError(error.IfdChainCycle, dec.validateAllStripsAndTiles(&ws));
}

test "SubIFD: a child pointing back at its parent is IfdChainCycle" {
    var storage: [256]u8 = undefined;
    const n = writeChildPointingAtParent(&storage);
    var handle = BufferHandle.init(storage[0..n]);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectError(error.IfdChainCycle, dec.validateAllStripsAndTiles(&ws));
}

test "stripRowSpan: u32-max length and rows-per-strip stay one full band" {
    // Independent of the implementation's old `length + rps - 1` sum,
    // which wraps to 0 at this corner and then divides by zero.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), stripRowSpan(0xFFFFFFFF, 0xFFFFFFFF, 0));
    // ceil(max / (max-1)) is 2 bands: a full rows-per-strip, then the 1-row remainder.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFE), stripRowSpan(0xFFFFFFFF, 0xFFFFFFFE, 0));
    try std.testing.expectEqual(@as(u32, 1), stripRowSpan(0xFFFFFFFF, 0xFFFFFFFE, 1));
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

test "complete strip tolerates at most one trailing row past the sample grid" {
    // RowsPerStrip equals the image, so the sample grid has no short-strip
    // slack. TIFF 6.0 records StripByteCounts as the stored length. Up to
    // one extra row of trailing bytes is padding. One byte past that row
    // is still a damaged extent.
    const ext = try boundedFinalStripExtent(2, 2, 2, 64 * 1024);
    try std.testing.expectEqual(@as(usize, 4), ext.min);
    try std.testing.expectEqual(@as(usize, 6), ext.max);
    try std.testing.expect(ext.warn_if_above_min);

    const members = [_]struct { written: usize, accepted: bool, warns: bool }{
        .{ .written = 3, .accepted = false, .warns = false },
        .{ .written = 4, .accepted = true, .warns = false },
        .{ .written = 5, .accepted = true, .warns = true },
        .{ .written = 6, .accepted = true, .warns = true },
        .{ .written = 7, .accepted = false, .warns = false },
    };
    for (members) |member| {
        const accepted = member.written >= ext.min and member.written <= ext.max;
        try std.testing.expectEqual(member.accepted, accepted);
        try std.testing.expectEqual(member.warns, accepted and member.written > ext.min);
    }
}

test "uncompressed complete strip: 1 trailing byte warns, one row plus a byte is Malformed" {
    // 2×2 gray is 4 sample bytes, one row is 2 bytes. The stored lengths
    // 5 and 6 stay inside that row. 7 does not. This is the Nikon NRW
    // shape: a full SubIFD strip whose byte count is past the sample grid
    // by less than a row.
    const cases = [_]struct { stored: usize, malformed: bool, excess: u32 }{
        .{ .stored = 4, .malformed = false, .excess = 0 },
        .{ .stored = 5, .malformed = false, .excess = 1 },
        .{ .stored = 6, .malformed = false, .excess = 2 },
        .{ .stored = 7, .malformed = true, .excess = 0 },
    };
    for (cases) |case| {
        var storage: [128]u8 = undefined;
        const n = writeGrayStrip(&storage, 2, 2, case.stored);
        var handle = BufferHandle.init(storage[0..n]);
        const src = Source.fromBuffer(&handle);
        var dec = try Decoder.open(std.testing.allocator, src);
        defer dec.deinit();
        var ws = Workspace.init(std.testing.allocator);
        defer ws.deinit();
        if (case.malformed) {
            try std.testing.expectError(error.Malformed, dec.validateAllStripsAndTiles(&ws));
            try std.testing.expect(dec.discrepancy != null);
            try std.testing.expectEqual(ReportClass.@"error", dec.discrepancy.?.class);
        } else {
            try dec.validateAllStripsAndTiles(&ws);
            if (case.excess == 0) {
                try std.testing.expect(dec.discrepancy == null);
            } else {
                const found = dec.discrepancy orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(ReportClass.warning, found.class);
                try std.testing.expectEqualStrings("final_strip_padding_tolerated", found.type_name);
                try std.testing.expectEqual(@as(?u64, 98), found.offset);
            }
        }
    }
}

test "boundedFinalStripExtent classifies logical exact padded and beyond-max lengths" {
    const ext = try boundedFinalStripExtent(500, 4, 16, 64 * 1024);
    try std.testing.expectEqual(@as(usize, 2000), ext.min);
    try std.testing.expectEqual(@as(usize, 8000), ext.max);
    try std.testing.expect(ext.warn_if_above_min);

    const members = [_]struct { written: usize, accepted: bool, warns: bool }{
        .{ .written = 1999, .accepted = false, .warns = false },
        .{ .written = 2000, .accepted = true, .warns = false },
        .{ .written = 2001, .accepted = true, .warns = true },
        .{ .written = 8000, .accepted = true, .warns = true },
        .{ .written = 8001, .accepted = false, .warns = false },
    };
    for (members) |member| {
        const accepted = member.written >= ext.min and member.written <= ext.max;
        try std.testing.expectEqual(member.accepted, accepted);
        try std.testing.expectEqual(member.warns, accepted and member.written > ext.min);
    }
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

test "stripRowSpan: classifier over chunky/separate × single/multi-strip × short-last band" {
    // Hand-derived oracle (MFIC — independent of the implementation formula).
    // Bites in BOTH build modes: several separate-plane cases below produce a
    // WRONG this_rows under the pre-fix `length - strip_index*rps` even under
    // ReleaseFast (not merely a ReleaseSafe panic), because the @min clamp does
    // not always mask the wrap back to the correct answer.
    const S = struct {
        len: u32,
        rps: u32,
        idx: u32,
        want: u32,
    };
    const cases = [_]S{
        // chunky single strip: one full strip.
        .{ .len = 16, .rps = 16, .idx = 0, .want = 16 },
        // chunky multi-strip, length divisible by rps.
        .{ .len = 32, .rps = 16, .idx = 0, .want = 16 },
        .{ .len = 32, .rps = 16, .idx = 1, .want = 16 },
        // chunky multi-strip, short final band (length % rps != 0).
        .{ .len = 20, .rps = 16, .idx = 0, .want = 16 },
        .{ .len = 20, .rps = 16, .idx = 1, .want = 4 },
        // planar=separate, 3 planes × 2 strips/plane over length=20, rps=16.
        // strips_per_plane = ceil(20/16) = 2, total StripOffsets = 6.
        // The odd indices on the 2nd/3rd plane are the killers: pre-fix they
        // underflow (idx 3,5) and clamp to a wrong 16 instead of 4.
        .{ .len = 20, .rps = 16, .idx = 2, .want = 16 }, // plane1 band0
        .{ .len = 20, .rps = 16, .idx = 3, .want = 4 }, // plane1 band1  (pre-fix: 16, WRONG)
        .{ .len = 20, .rps = 16, .idx = 4, .want = 16 }, // plane2 band0
        .{ .len = 20, .rps = 16, .idx = 5, .want = 4 }, // plane2 band1  (pre-fix: 16, WRONG)
        // degenerate guards: no divide-by-zero, yields 0 rows.
        .{ .len = 16, .rps = 0, .idx = 0, .want = 0 },
        .{ .len = 0, .rps = 16, .idx = 5, .want = 0 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.want, stripRowSpan(c.len, c.rps, c.idx));
    }
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

// Validate's 131-byte repro: a real 1x1 LZW page chained to an IFD whose
// only entry has field type 0 and no image geometry. Both the type and the
// missing page tags must fail closed. The walk must not treat that failure
// as the end of the chain. Since 2026-11-05 the type-0 entry parses as an
// unknown field (TIFF 6.0 p. 16: readers skip it) and is named by a finding
// 18 reason 1 record, instead of the IFD failing to parse with no record.
/// IFD 0 is a one-pixel image; IFD 1 at 0x71 has one entry, ImageWidth with
/// field type 0. IFD 1's next pointer is at 127.
const chained_type_zero = [_]u8{
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x08, 0x00,
    0x00, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x01, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x02, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x03, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
    0x06, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x11, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x6E, 0x00, 0x00, 0x00,
    0x16, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x17, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
    0x71, 0x00, 0x00, 0x00,
    0x80, 0x2A, 0x80,
    0x01, 0x00,
    0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
};

/// Counts corrupt type records for `chained_type_zero`'s IFD 1, entry 0.
const ChainedTypeZeroRecords = struct {
    count: usize = 0,
    fn callback(userdata: ?*anyopaque, source_decoder: i32, code: i32, mapped: i32, verdict: i32, offset: u64, host: u64, flags: u32, payload: ?[*]const u8, len: usize) callconv(.c) void {
        _ = .{ source_decoder, mapped, host, flags };
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        if (code != @intFromEnum(findings_mod.InfoFinding.tag_field_invalid) or verdict != @intFromEnum(findings_mod.Verdict.corrupt)) return;
        const p = (payload orelse return)[0..len];
        // IFD 1, entry 0 at offset 0x71 + 2: ImageWidth, reason 1, raw type 0.
        if (std.mem.readInt(u32, p[0..4], .little) != 1 or offset != 0x73) return;
        if (std.mem.readInt(u16, p[16..18], .little) != 256 or std.mem.readInt(u16, p[18..20], .little) != 1 or std.mem.readInt(u16, p[20..22], .little) != 0) return;
        self.count += 1;
    }
};

test "validateAllStripsAndTiles: a limit never hides a corrupt record, and an IFD past the end is not a limit" {
    // IFD 1 (type 0) links to an IFD 2 of 9 entries, over a cap of 8
    // (validate, 2026-11-05). When IFD 2 fits in the file the walk stops on
    // the limit, and IFD 1's type record is still reported, so the file is
    // invalid; when it runs past the end of the file it is SourceShortRead.
    inline for (.{ true, false }) |fits| {
        const tail = if (fits) [_]u8{ 0x09, 0x00 } ++ [_]u8{0} ** (9 * 12 + 4) else [_]u8{ 0x09, 0x00 };
        var bytes = chained_type_zero ++ tail;
        std.mem.writeInt(u32, bytes[127..131], chained_type_zero.len, .little);
        var handle = BufferHandle.init(&bytes);
        var dec = try Decoder.openWithLimits(std.testing.allocator, Source.fromBuffer(&handle), .{ .max_tags_per_ifd = 8 });
        defer dec.deinit();
        var records: ChainedTypeZeroRecords = .{};
        dec.setFindingCallback(&ChainedTypeZeroRecords.callback, @ptrCast(&records));
        var ws = Workspace.init(std.testing.allocator);
        defer ws.deinit();
        const want: errors.Error = if (fits) error.LimitExceededTagCount else error.SourceShortRead;
        try std.testing.expectError(want, dec.validateAllStripsAndTiles(&ws));
        try std.testing.expectEqual(@as(usize, 1), records.count);
    }
}

test "validateAllStripsAndTiles: a strip over the compressed cap is a limit only when the file holds it" {
    // validate, 2026-11-05: a declared extent past the end of the file is
    // not a limit. A 1x1 gray page, its strip at 0xF0 of a 256-byte file,
    // under a 4-byte cap: 8 declared bytes fit, 0x20 run past the end.
    const w_entry: [12]u8 = .{ 0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const h_entry: [12]u8 = .{ 0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const bps_entry: [12]u8 = .{ 0x02, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00 };
    const comp_entry: [12]u8 = .{ 0x03, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const photo_entry: [12]u8 = .{ 0x06, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const so_entry: [12]u8 = .{ 0x11, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0xF0, 0x00, 0x00, 0x00 };
    const rps_entry: [12]u8 = .{ 0x16, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const strip = [_]u8{0x7F};
    inline for (.{ .{ 0x08, error.LimitExceededCompressedStripBytes }, .{ 0x20, error.SourceShortRead } }) |case| {
        const sbc_entry: [12]u8 = .{ 0x17, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, case[0], 0x00, 0x00, 0x00 };
        const bytes = synthesize(8, .{ w_entry, h_entry, bps_entry, comp_entry, photo_entry, so_entry, rps_entry, sbc_entry }, &strip, 0xF0);
        var handle = BufferHandle.init(&bytes);
        var dec = try Decoder.openWithLimits(std.testing.allocator, Source.fromBuffer(&handle), .{ .max_compressed_strip_bytes = 4 });
        defer dec.deinit();
        var ws = Workspace.init(std.testing.allocator);
        defer ws.deinit();
        try std.testing.expectError(case[1], dec.validateAllStripsAndTiles(&ws));
    }
}

test "validateAllStripsAndTiles: chained IFD with field type 0 is Malformed" {
    var handle = BufferHandle.init(&chained_type_zero);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    var records: ChainedTypeZeroRecords = .{};
    dec.setFindingCallback(&ChainedTypeZeroRecords.callback, @ptrCast(&records));
    const second = try dec.ifd(1);
    try std.testing.expectEqual(ifd_mod.FieldType.unknown, second.entries[0].field_type);
    try std.testing.expectEqual(@as(u16, 0), second.entries[0].raw_type);
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectError(error.Malformed, dec.validateAllStripsAndTiles(&ws));
    try std.testing.expectEqual(@as(usize, 1), records.count);
}

// Same shape as the type-0 chain, but IFD1's single entry is a legal ASCII
// tag and still carries no ImageWidth, ImageLength, or strip/tile offsets.
test "validateAllStripsAndTiles: main-chain IFD without image tags is Malformed" {
    const w_entry: [12]u8 = .{ 0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const h_entry: [12]u8 = .{ 0x01, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const bps_entry: [12]u8 = .{ 0x02, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00 };
    const comp_entry: [12]u8 = .{ 0x03, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const photo_entry: [12]u8 = .{ 0x06, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const so_entry: [12]u8 = .{ 0x11, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x6E, 0x00, 0x00, 0x00 };
    const rps_entry: [12]u8 = .{ 0x16, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const sbc_entry: [12]u8 = .{ 0x17, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const strip = [_]u8{0x7F};
    var bytes = synthesize(8, .{ w_entry, h_entry, bps_entry, comp_entry, photo_entry, so_entry, rps_entry, sbc_entry }, &strip, 0x6E);
    // next IFD at 116. synthesize leaves the pointer at 0.
    bytes[106] = 116;
    bytes[116] = 1;
    // ImageDescription, ASCII, count 1, inline 'A'.
    const desc = [_]u8{ 0x0E, 0x01, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00 };
    @memcpy(bytes[118..130], &desc);

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);
    var dec = try Decoder.open(std.testing.allocator, src);
    defer dec.deinit();
    _ = try dec.ifd(1);
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    try std.testing.expectError(error.Malformed, dec.validateAllStripsAndTiles(&ws));
}
