//! Calls the LERC C ABI through tiffz's exported `lerc` artifact — the exact
//! two symbols validate's core archive failed to link (`lerc_getBlobInfo`,
//! `lerc_decode`). Declared extern here (no header include) so the proof is
//! pure link-level: if the artifact doesn't carry the symbols, this does not
//! build. At runtime both calls get garbage and MUST reject it (nonzero
//! status) — proving the calls really entered LERC, not a stub. Silent on
//! success (tests run clean); nonzero exit on any failure.
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

pub fn main() !void {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03 };
    var info: [16]c_uint = undefined;
    var range: [3]f64 = undefined;

    const info_status = lerc_getBlobInfo(&garbage, garbage.len, &info, &range, info.len, range.len);
    if (info_status == 0) return error.LercAcceptedGarbageBlobInfo;

    var out: [16]u8 = undefined;
    const decode_status = lerc_decode(&garbage, garbage.len, 0, null, 1, 2, 2, 1, 0, &out);
    if (decode_status == 0) return error.LercAcceptedGarbageDecode;
}
