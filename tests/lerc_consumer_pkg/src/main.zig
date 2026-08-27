//! Calls the LERC and Zstandard C ABIs through tiffz's exported artifacts.
//! The extern declarations avoid module imports and headers, so missing
//! symbols fail at link time. Runtime calls reject garbage or satisfy stable
//! API invariants, proving these are callable libraries rather than empty
//! named artifacts. Silent on success; nonzero exit on any failure.
const std = @import("std");

// Signatures per Lerc_c_api.h (lerc_status = unsigned int).
extern fn lerc_getBlobInfo(
    blob: [*]const u8,
    blob_size: c_uint,
    info_array: [*]c_uint,
    data_range_array: [*]f64,
    info_array_size: c_int,
    data_range_array_size: c_int,
) c_uint;

extern fn lerc_decode(
    blob: [*]const u8,
    blob_size: c_uint,
    n_masks: c_int,
    valid_bytes: ?[*]u8,
    n_dim: c_int,
    n_cols: c_int,
    n_rows: c_int,
    n_bands: c_int,
    data_type: c_uint,
    data: ?*anyopaque,
) c_uint;

const ZstdContext = opaque {};

const ZstdInput = extern struct {
    src: ?*const anyopaque,
    size: usize,
    pos: usize,
};

const ZstdOutput = extern struct {
    dst: ?*anyopaque,
    size: usize,
    pos: usize,
};

extern fn ZSTD_decompress(dst: ?*anyopaque, dst_capacity: usize, src: ?*const anyopaque, compressed_size: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_createDCtx() ?*ZstdContext;
extern fn ZSTD_freeDCtx(dctx: ?*ZstdContext) usize;
extern fn ZSTD_DStreamInSize() usize;
extern fn ZSTD_DStreamOutSize() usize;
extern fn ZSTD_decompressStream(dctx: *ZstdContext, output: *ZstdOutput, input: *ZstdInput) usize;

pub fn main() !void {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03 };
    var info: [16]c_uint = undefined;
    var range: [3]f64 = undefined;

    const info_status = lerc_getBlobInfo(&garbage, garbage.len, &info, &range, info.len, range.len);
    if (info_status == 0) return error.LercAcceptedGarbageBlobInfo;

    var out: [16]u8 = undefined;
    const decode_status = lerc_decode(&garbage, garbage.len, 0, null, 1, 2, 2, 1, 0, &out);
    if (decode_status == 0) return error.LercAcceptedGarbageDecode;

    const decompressed = ZSTD_decompress(&out, out.len, &garbage, garbage.len);
    if (ZSTD_isError(decompressed) == 0) return error.ZstdAcceptedGarbageDecompress;

    const dctx = ZSTD_createDCtx() orelse return error.ZstdContextAllocationFailed;
    defer if (ZSTD_freeDCtx(dctx) != 0) @panic("ZSTD_freeDCtx failed");

    if (ZSTD_DStreamInSize() == 0) return error.ZstdInvalidInputBufferSize;
    if (ZSTD_DStreamOutSize() == 0) return error.ZstdInvalidOutputBufferSize;

    var input = ZstdInput{ .src = &garbage, .size = garbage.len, .pos = 0 };
    var output = ZstdOutput{ .dst = &out, .size = out.len, .pos = 0 };
    const streamed = ZSTD_decompressStream(dctx, &output, &input);
    if (ZSTD_isError(streamed) == 0) return error.ZstdAcceptedGarbageStream;
}
