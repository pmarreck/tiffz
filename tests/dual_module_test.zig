const std = @import("std");
const tiffz = @import("tiffz");
const parser = @import("tiffz-parser");

// Prove Validate can own the full decoder and rawz's parser dependency in one
// Zig compilation without duplicate source ownership or type drift.
test "full and parser modules coexist with shared parser types" {
    try std.testing.expect(tiffz.Error == parser.Error);
    try std.testing.expect(tiffz.Source == parser.Source);
    try std.testing.expect(tiffz.Limits == parser.Limits);
    try std.testing.expect(tiffz.header.Endian == parser.header.Endian);
    try std.testing.expect(tiffz.ifd.Ifd == parser.ifd.Ifd);
    try std.testing.expect(tiffz.tags.image_width == parser.tags.image_width);
    try std.testing.expect(tiffz.Decoder != parser.Decoder);
}
