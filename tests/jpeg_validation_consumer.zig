const std = @import("std");
const tiffz = @import("tiffz");

/// Exercise the exact jpegz structural validator reached by tiffz's production
/// JPEG-in-TIFF path without decoding pixels or invoking an oracle.
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const malformed = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    var report = try tiffz.jpegz.validate(allocator, &malformed);
    defer report.deinit(allocator);
    if (report.overall != .fail or report.findings.items.len == 0) {
        return error.ValidationProofFailed;
    }
    const first = report.findings.items[0];
    if (first.code != .missing_soi or first.offset != 0) {
        return error.ValidationProofFailed;
    }
}

test "proof consumer observes a structured corrupt JPEG cause" {
    try main();
}
