//! GeoTIFF metadata parsing (M11).
//!
//! Parses the OGC GeoTIFF 1.1 tag surface into an in-memory
//! `Metadata` struct. This is METADATA ONLY — no coordinate
//! transforms, no CRS resolution, no reprojection. The caller
//! (typically validate) walks the parsed `keys` and dereferences
//! into `double_params` / `ascii_params` per the GeoTIFF spec.
//!
//! Tags handled:
//! - ModelPixelScale (33550): 3 DOUBLEs [Sx, Sy, Sz]
//! - ModelTiepoint (33922):   6N DOUBLEs, N × [I, J, K, X, Y, Z]
//! - ModelTransformation (34264): 16 DOUBLEs, 4×4 affine matrix
//! - GeoKeyDirectory (34735): 4 + 4N SHORTs
//!     - Header:  [KeyDirectoryVersion, KeyRevision, MinorRevision, NumberOfKeys]
//!     - Each Key: [KeyID, TIFFTagLocation, Count, Value_Offset]
//!       - TIFFTagLocation = 0    → Value_Offset is the u16 value inline
//!       - TIFFTagLocation = 34736 → GeoDoubleParams[Value_Offset..Value_Offset+Count]
//!       - TIFFTagLocation = 34737 → GeoAsciiParams[Value_Offset..Value_Offset+Count]
//! - GeoDoubleParams (34736): array of DOUBLE values
//! - GeoAsciiParams (34737):  '|'-terminated string entries
//!
//! Strict-parse posture (fleet policy): the GeoKeyDirectory header
//! MUST have length 4 + 4×NumberOfKeys shorts; any mismatch → error.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("tiffz-parser");
const errors = parser.errors;
const tags = parser.tags;
const ifd_mod = parser.ifd;
const header_mod = parser.header;

const Ifd = ifd_mod.Ifd;
const Endian = header_mod.Endian;

/// One GeoKey entry from the KeyDirectory. Semantics match GeoTIFF
/// 1.1 §7.1: `tag_location=0` means `value_offset` holds a SHORT
/// value directly; otherwise `tag_location` is a TIFF tag ID
/// (34736 or 34737) and `[value_offset .. value_offset+count]`
/// indexes into the corresponding params array.
pub const GeoKey = struct {
	id: u16,
	tag_location: u16,
	count: u16,
	value_offset: u16,
};

/// Parsed GeoTIFF metadata surface. Owns any heap-allocated slices
/// (tiepoints, keys, double_params, ascii_params). Call `deinit` to
/// free.
pub const Metadata = struct {
	pixel_scale: ?[3]f64,
	tiepoints: []const [6]f64,
	transformation: ?[16]f64,

	key_directory_version: u16,
	key_revision: u16,
	minor_revision: u16,
	keys: []const GeoKey,
	double_params: []const f64,
	ascii_params: []const u8,

	pub fn deinit(self: Metadata, allocator: Allocator) void {
		if (self.tiepoints.len > 0) allocator.free(self.tiepoints);
		if (self.keys.len > 0) allocator.free(self.keys);
		if (self.double_params.len > 0) allocator.free(self.double_params);
		if (self.ascii_params.len > 0) allocator.free(self.ascii_params);
	}
};

/// Parse GeoTIFF metadata for the given IFD. Returns `null` when the
/// IFD has NO GeoTIFF tags at all (a plain TIFF). Returns an error
/// only for structurally-malformed GeoTIFF payloads (spec violation
/// — e.g. GeoKeyDirectory whose header disagrees with its actual key
/// count). On success the returned `Metadata` owns heap allocations
/// and must be freed via `Metadata.deinit`.
pub fn parseFromIfd(
	dir: Ifd,
	source: anytype,
	endian: Endian,
	allocator: Allocator,
) errors.Error!?Metadata {
	// Presence check: any of the six GeoTIFF tags is enough to enter
	// parse mode. Nothing present → not a GeoTIFF, return null.
	const geo_tag_ids = [_]u16{
		tags.model_pixel_scale,
		tags.model_tiepoint,
		tags.model_transformation,
		tags.geo_key_directory,
		tags.geo_double_params,
		tags.geo_ascii_params,
	};
	var any_present = false;
	for (geo_tag_ids) |t| {
		if (dir.get(t) != null) {
			any_present = true;
			break;
		}
	}
	if (!any_present) return null;

	// --- Fixed-shape geometry tags ---
	const pixel_scale = try readOptionalTripleDouble(dir, tags.model_pixel_scale, endian);

	const tiepoints = try readTiepoints(dir, endian, allocator);
	errdefer if (tiepoints.len > 0) allocator.free(tiepoints);

	const transformation = try readOptionalTransformation(dir, endian);

	// --- GeoKeyDirectory: header + keys ---
	var key_directory_version: u16 = 0;
	var key_revision: u16 = 0;
	var minor_revision: u16 = 0;
	var keys: []GeoKey = &.{};
	errdefer if (keys.len > 0) allocator.free(keys);

	if (dir.get(tags.geo_key_directory)) |e| {
		if (e.field_type != .short) return error.Malformed;
		// A well-formed GeoKeyDirectory has `4 + 4*N` shorts where
		// header[3] = N.
		if (e.count < 4 or (e.count % 4) != 0) return error.Malformed;

		const declared_n_keys: usize =
			@intCast(try dir.arrayElementU64(tags.geo_key_directory, 3, endian, source));
		if (@as(usize, e.count) != 4 + 4 * declared_n_keys) return error.Malformed;

		key_directory_version = @intCast(try dir.arrayElementU64(tags.geo_key_directory, 0, endian, source));
		key_revision = @intCast(try dir.arrayElementU64(tags.geo_key_directory, 1, endian, source));
		minor_revision = @intCast(try dir.arrayElementU64(tags.geo_key_directory, 2, endian, source));

		const allocated = try allocator.alloc(GeoKey, declared_n_keys);
		var i: usize = 0;
		while (i < declared_n_keys) : (i += 1) {
			const base: u32 = @intCast(4 + i * 4);
			allocated[i] = .{
				.id = @intCast(try dir.arrayElementU64(tags.geo_key_directory, base + 0, endian, source)),
				.tag_location = @intCast(try dir.arrayElementU64(tags.geo_key_directory, base + 1, endian, source)),
				.count = @intCast(try dir.arrayElementU64(tags.geo_key_directory, base + 2, endian, source)),
				.value_offset = @intCast(try dir.arrayElementU64(tags.geo_key_directory, base + 3, endian, source)),
			};
		}
		keys = allocated;
	}

	// --- Params arrays ---
	const double_params = try readAllDoubles(dir, tags.geo_double_params, endian, allocator);
	errdefer if (double_params.len > 0) allocator.free(double_params);
	const ascii_params = try readAscii(dir, tags.geo_ascii_params, source, allocator);

	return Metadata{
		.pixel_scale = pixel_scale,
		.tiepoints = tiepoints,
		.transformation = transformation,
		.key_directory_version = key_directory_version,
		.key_revision = key_revision,
		.minor_revision = minor_revision,
		.keys = keys,
		.double_params = double_params,
		.ascii_params = ascii_params,
	};
}

/// Read a single DOUBLE element from a tag's cached value bytes.
/// The IFD's eager cache holds the raw bytes; interpret each 8-byte
/// stride as a f64 in the file endian.
fn readDoubleFromCache(dir: Ifd, tag: u16, index: u32, endian: Endian) errors.Error!f64 {
	const buf = dir.cachedValueBytes(tag) orelse return error.Malformed;
	const off: usize = @as(usize, index) * 8;
	if (off + 8 > buf.len) return error.Malformed;
	const bits = header_mod.readU64(buf[off..][0..8], endian);
	return @bitCast(bits);
}

/// Read an optional exactly-3-DOUBLE tag (ModelPixelScale).
fn readOptionalTripleDouble(dir: Ifd, tag: u16, endian: Endian) errors.Error!?[3]f64 {
	const e = dir.get(tag) orelse return null;
	if (e.field_type != .double) return error.Malformed;
	if (e.count != 3) return error.Malformed;
	return .{
		try readDoubleFromCache(dir, tag, 0, endian),
		try readDoubleFromCache(dir, tag, 1, endian),
		try readDoubleFromCache(dir, tag, 2, endian),
	};
}

/// Read an optional exactly-16-DOUBLE tag (ModelTransformation).
fn readOptionalTransformation(dir: Ifd, endian: Endian) errors.Error!?[16]f64 {
	const e = dir.get(tags.model_transformation) orelse return null;
	if (e.field_type != .double) return error.Malformed;
	if (e.count != 16) return error.Malformed;
	var m: [16]f64 = undefined;
	var i: u32 = 0;
	while (i < 16) : (i += 1) m[i] = try readDoubleFromCache(dir, tags.model_transformation, i, endian);
	return m;
}

/// Read the ModelTiepoint tag (N × 6 DOUBLEs). Returns empty slice
/// when the tag is absent; heap-allocated when present.
fn readTiepoints(dir: Ifd, endian: Endian, allocator: Allocator) errors.Error![]const [6]f64 {
	const e = dir.get(tags.model_tiepoint) orelse return &.{};
	if (e.field_type != .double) return error.Malformed;
	if ((e.count % 6) != 0) return error.Malformed;
	const n_tuples: usize = @intCast(e.count / 6);
	const tuples = try allocator.alloc([6]f64, n_tuples);
	errdefer allocator.free(tuples);
	var i: usize = 0;
	while (i < n_tuples) : (i += 1) {
		const base: u32 = @intCast(i * 6);
		var t: [6]f64 = undefined;
		var j: u32 = 0;
		while (j < 6) : (j += 1) t[j] = try readDoubleFromCache(dir, tags.model_tiepoint, base + j, endian);
		tuples[i] = t;
	}
	return tuples;
}

fn readAllDoubles(dir: Ifd, tag: u16, endian: Endian, allocator: Allocator) errors.Error![]const f64 {
	const e = dir.get(tag) orelse return &.{};
	if (e.field_type != .double) return error.Malformed;
	const out = try allocator.alloc(f64, e.count);
	errdefer allocator.free(out);
	var i: u32 = 0;
	while (i < e.count) : (i += 1) out[i] = try readDoubleFromCache(dir, tag, i, endian);
	return out;
}

fn readAscii(dir: Ifd, tag: u16, source: anytype, allocator: Allocator) errors.Error![]const u8 {
	const e = dir.get(tag) orelse return &.{};
	if (e.field_type != .ascii) return error.Malformed;
	if (e.count == 0) return &.{};
	// ASCII values are cached via the eager IFD value cache. Use the
	// cached bytes directly.
	if (dir.cachedValueBytes(tag)) |buf| {
		const copy = try allocator.alloc(u8, buf.len);
		@memcpy(copy, buf);
		return copy;
	}
	// Fallback: read element-by-element (single-byte fetches). Rare
	// path — the cache is populated at parse time for out-of-line
	// values. Kept for defense.
	const buf = try allocator.alloc(u8, e.count);
	errdefer allocator.free(buf);
	var i: u32 = 0;
	while (i < e.count) : (i += 1) {
		buf[i] = @intCast(try dir.arrayElementU64(tag, i, .little, source));
	}
	return buf;
}
