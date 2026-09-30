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

// An over-subscribed DHT must come back as a structured corrupt finding
// through the one jpegz instance tiffz ships. The 178-byte stream is the
// public September 26 reproduction: its second DHT asks for three 1-bit
// codes, which T.81 Annex C cannot assign without using the reserved
// all-ones code or writing past the 256-entry fast table.
test "oversubscribed DHT is corrupt through the tiffz jpegz instance" {
    const hex = "ffd8ffe000104a46494600010100000100010000ffdb00430003020203020203" ++
        "03030304030304050805050404050a070706080c0a0c0c0b0a0b0b0d0e12100d" ++
        "0e110e0b0b1016101113141515150c0f171816141812141514ffc0000b080010" ++
        "001001011100ffc400160001010100000000000000000000000000000809ffc4" ++
        "00171003000100000000000000000000000000001864a2ffda0008010100003f" ++
        "00921639321639326b5ac72642c7264fffd9";
    var bytes: [178]u8 = undefined;
    const data = try std.fmt.hexToBytes(&bytes, hex);
    try std.testing.expectEqual(@as(usize, 178), data.len);
    var report = try tiffz.jpegz.validate(std.testing.allocator, data);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.overall == .fail);
    var found = false;
    for (report.findings.items) |finding| {
        if (finding.code == .huffman_table_corrupt and finding.severity == .fail) found = true;
    }
    try std.testing.expect(found);
}
