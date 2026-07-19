//! LERC compression (TIFF compression=34887, Esri / GDAL / libtiff extension).
//!
//! Each strip/tile is either a bare LERC blob or a LERC blob wrapped by
//! an optional post-filter (Deflate or Zstd), selected by the
//! LercParameters tag (50674) `[codec_version, add_compression]` where
//! add_compression ∈ {0=none, 1=Deflate, 2=Zstd}.
//!
//! Strict decode: unknown/out-of-spec `codec_version` (must be 2..6) or
//! `add_compression` (must be 0/1/2) reject as `error.Malformed` — no
//! silent fallback, consistent with the fleet strictness policy.
//!
//! Backed by pmarreck/lercz, a Zig-wrap fork of Esri's LERC C++ library
//! (Apache-2.0). The C ABI in Lerc_c_api.h is reached via `lerc.c.*`.

const std = @import("std");
const lerc = @import("lercz");

const errors = @import("../errors.zig");
const deflate = @import("deflate.zig");
const zstd = @import("zstd.zig");

/// Post-filter selector from LercParameters tag[1].
pub const AddCompression = enum(u32) {
	none = 0,
	deflate = 1,
	zstd = 2,
};

/// LercParameters payload. The TIFF fixture is `[codec_version,
/// add_compression]`; both fields are strictly bounded.
pub const Parameters = struct {
	codec_version: u32,
	add_compression: AddCompression,
};

/// Parse the two-u32 LercParameters payload strictly. Rejects any
/// codec_version outside 2..=6 (LERC2 v2.2..v2.6) and any
/// add_compression outside 0..=2.
pub fn parseParameters(raw: [2]u32) errors.Error!Parameters {
	if (raw[0] < 2 or raw[0] > 6) return error.Malformed;
	const add: AddCompression = switch (raw[1]) {
		0 => .none,
		1 => .deflate,
		2 => .zstd,
		else => return error.Malformed,
	};
	return .{ .codec_version = raw[0], .add_compression = add };
}

/// Indices into the LERC blob-info array (matches Lerc_types.h::InfoArrOrder).
const info_version = 0;
const info_data_type = 1;
const info_n_depth_v1 = 2; // legacy alias (nDim in older headers)
const info_n_cols = 3;
const info_n_rows = 4;
const info_n_bands = 5;
const info_n_masks = 8;
const info_n_depth = 9; // canonical position in current headers
const info_array_size = 11;

/// Decode one LERC strip/tile into `dest`.
///
/// `src` is the raw on-disk compressed blob for this chunk. When
/// `params.add_compression != none`, the blob is first stripped of its
/// Deflate/Zstd wrapper into `scratch` (a caller-owned buffer at least
/// the size of the inner LERC blob).
///
/// Geometry is read from the LERC blob header itself via
/// `lerc_getBlobInfo`, then verified against `dest.len` before decode.
/// Anything inconsistent → `error.Malformed`.
pub fn decode(
	src: []const u8,
	dest: []u8,
	scratch: []u8,
	params: Parameters,
) errors.Error!usize {
	const lerc_blob: []const u8 = switch (params.add_compression) {
		.none => src,
		.deflate => blk: {
			const n = try deflate.decode(src, scratch);
			break :blk scratch[0..n];
		},
		.zstd => blk: {
			const n = try zstd.decode(src, scratch);
			break :blk scratch[0..n];
		},
	};

	if (lerc_blob.len > std.math.maxInt(c_uint)) return error.Malformed;

	var info: [info_array_size]c_uint = @splat(0);
	const info_status = lerc.c.lerc_getBlobInfo(
		lerc_blob.ptr,
		@intCast(lerc_blob.len),
		&info[0],
		null, // dataRangeArray — not needed for decode
		info_array_size,
		0,
	);
	if (info_status != lerc.err_ok) return error.Malformed;

	const data_type = info[info_data_type];
	const n_cols_u = info[info_n_cols];
	const n_rows_u = info[info_n_rows];
	const n_bands_u = info[info_n_bands];
	// Newer blobs write nDepth at index 9; older nDim-flavored blobs at
	// index 2. Prefer the modern slot but honor the legacy one if 9 is 0.
	const n_depth_u = if (info[info_n_depth] != 0) info[info_n_depth] else info[info_n_depth_v1];

	const bytes_per_sample: usize = switch (data_type) {
		lerc.dt_char, lerc.dt_uchar => 1,
		lerc.dt_short, lerc.dt_ushort => 2,
		lerc.dt_int, lerc.dt_uint, lerc.dt_float => 4,
		lerc.dt_double => 8,
		else => return error.Malformed,
	};

	// Overflow-safe multiplication for the total byte count.
	const total_samples: u64 = @as(u64, n_cols_u) * @as(u64, n_rows_u) *
		@as(u64, n_bands_u) * @as(u64, n_depth_u);
	const total_bytes: u64 = total_samples * @as(u64, bytes_per_sample);
	if (total_bytes == 0 or total_bytes > dest.len) return error.Malformed;

	const status = lerc.c.lerc_decode(
		lerc_blob.ptr,
		@intCast(lerc_blob.len),
		0, // nMasks = 0 → tiffz doesn't propagate nodata masks yet
		null, // pValidBytes
		@intCast(n_depth_u),
		@intCast(n_cols_u),
		@intCast(n_rows_u),
		@intCast(n_bands_u),
		data_type,
		dest.ptr,
	);
	if (status != lerc.err_ok) return error.Malformed;
	return @intCast(total_bytes);
}

// ---- tests ----

test "lerc.parseParameters: accepts LERC2 v4 none/deflate/zstd" {
	{
		const p = try parseParameters(.{ 4, 0 });
		try std.testing.expectEqual(@as(u32, 4), p.codec_version);
		try std.testing.expectEqual(AddCompression.none, p.add_compression);
	}
	{
		const p = try parseParameters(.{ 4, 1 });
		try std.testing.expectEqual(AddCompression.deflate, p.add_compression);
	}
	{
		const p = try parseParameters(.{ 4, 2 });
		try std.testing.expectEqual(AddCompression.zstd, p.add_compression);
	}
}

test "lerc.parseParameters: rejects codec_version outside 2..6" {
	try std.testing.expectError(error.Malformed, parseParameters(.{ 1, 0 }));
	try std.testing.expectError(error.Malformed, parseParameters(.{ 7, 0 }));
	try std.testing.expectError(error.Malformed, parseParameters(.{ 0, 0 }));
}

test "lerc.parseParameters: rejects add_compression outside 0..2" {
	try std.testing.expectError(error.Malformed, parseParameters(.{ 4, 3 }));
	try std.testing.expectError(error.Malformed, parseParameters(.{ 4, 255 }));
}

test "lerc.decode: uint8 round-trip through a self-encoded blob" {
	const allocator = std.testing.allocator;

	// Encode 8x8 uint8 with the same lercz C ABI, then feed to decode().
	var src: [64]u8 = undefined;
	for (&src, 0..) |*p, i| p.* = @intCast((i * 3) & 0xFF);

	var blob_size: u32 = 0;
	try std.testing.expectEqual(@as(c_uint, lerc.err_ok), lerc.c.lerc_computeCompressedSizeForVersion(
		&src[0], 6, lerc.dt_uchar, 1, 8, 8, 1, 0, null, 0.0, &blob_size,
	));

	const blob = try allocator.alloc(u8, blob_size);
	defer allocator.free(blob);

	var written: u32 = 0;
	try std.testing.expectEqual(@as(c_uint, lerc.err_ok), lerc.c.lerc_encodeForVersion(
		&src[0], 6, lerc.dt_uchar, 1, 8, 8, 1, 0, null, 0.0,
		blob.ptr, blob_size, &written,
	));

	var decoded: [64]u8 = undefined;
	var scratch: [1]u8 = undefined; // unused for AddCompression.none
	const n = try decode(
		blob[0..written],
		&decoded,
		&scratch,
		.{ .codec_version = 6, .add_compression = .none },
	);
	try std.testing.expectEqual(@as(usize, 64), n);
	try std.testing.expectEqualSlices(u8, &src, &decoded);
}
