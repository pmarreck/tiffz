const std = @import("std");
const tiffz = @import("tiffz-parser");

const classic_empty = [_]u8{
    'I',  'I',  0x2a, 0x00,
    0x08, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00,
};

const classic_two_ifds = [_]u8{
    'I',  'I',  0x2a, 0x00,
    0x08, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x0e, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
};

const classic_self_cycle = [_]u8{
    'I',  'I',  0x2a, 0x00,
    0x08, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x08, 0x00,
    0x00, 0x00,
};

const bigtiff_ifd8 = [_]u8{
    'I',  'I',  0x2b, 0x00,
    0x08, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x4a, 0x01, 0x12, 0x00,
    0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x40, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
};

/// Exercise the exact parser surface a downstream RAW classifier consumes.
fn parseEmpty(allocator: std.mem.Allocator) !void {
    var handle = tiffz.source.BufferHandle.init(&classic_empty);
    const source = tiffz.Source.fromBuffer(&handle);
    var decoder = try tiffz.Decoder.open(allocator, source);
    defer decoder.deinit();

    try std.testing.expectEqual(tiffz.header.Endian.little, decoder.endian);
    try std.testing.expect(!decoder.bigtiff);
    try std.testing.expectEqual(tiffz.Limits.default.max_ifds, decoder.limits.max_ifds);
    try std.testing.expectEqual(@as(usize, 1), decoder.ifd_offsets.items.len);
    try std.testing.expectEqual(@as(u64, 8), decoder.ifd_offsets.items[0]);
    try std.testing.expectEqual(@as(usize, 1), decoder.ifdCount());
    const dir = try decoder.ifd(0);
    try std.testing.expectEqual(@as(usize, 0), dir.entries.len);
    try std.testing.expectEqual(@as(?*const tiffz.ifd.Entry, null), dir.get(tiffz.tags.image_width));
}

/// Exercise ownership transfers across both eager IFD0 and lazy IFD1 parsing.
fn traverseTwoIfds(allocator: std.mem.Allocator) !void {
    var handle = tiffz.source.BufferHandle.init(&classic_two_ifds);
    var decoder = try tiffz.Decoder.open(
        allocator,
        tiffz.Source.fromBuffer(&handle),
    );
    defer decoder.deinit();
    _ = try decoder.ifd(1);
}

pub fn main() !void {
    try parseEmpty(std.heap.page_allocator);
}

test "parser-only consumer can parse and inspect an IFD chain" {
    try parseEmpty(std.testing.allocator);
}

test "parser-only IFD traversal classifies chain, cycle, and limit behavior" {
    {
        var handle = tiffz.source.BufferHandle.init(&classic_two_ifds);
        var decoder = try tiffz.Decoder.open(
            std.testing.allocator,
            tiffz.Source.fromBuffer(&handle),
        );
        defer decoder.deinit();
        _ = try decoder.ifd(1);
        try std.testing.expectEqual(@as(usize, 2), decoder.ifdCount());
        try std.testing.expectEqualSlices(u64, &.{ 8, 14 }, decoder.ifd_offsets.items);
    }
    {
        var handle = tiffz.source.BufferHandle.init(&classic_self_cycle);
        var decoder = try tiffz.Decoder.open(
            std.testing.allocator,
            tiffz.Source.fromBuffer(&handle),
        );
        defer decoder.deinit();
        try std.testing.expectError(error.IfdChainCycle, decoder.ifd(1));
    }
    {
        var handle = tiffz.source.BufferHandle.init(&classic_two_ifds);
        var decoder = try tiffz.Decoder.openWithLimits(
            std.testing.allocator,
            tiffz.Source.fromBuffer(&handle),
            .{ .max_ifds = 1 },
        );
        defer decoder.deinit();
        try std.testing.expectError(error.LimitExceededIfdCount, decoder.ifd(1));
    }
}

test "parser-only consumer preserves BigTIFF IFD8 facts" {
    var handle = tiffz.source.BufferHandle.init(&bigtiff_ifd8);
    const source = tiffz.Source.fromBuffer(&handle);
    var decoder = try tiffz.Decoder.open(std.testing.allocator, source);
    defer decoder.deinit();
    try std.testing.expect(decoder.bigtiff);
    const dir = try decoder.ifd(0);
    try std.testing.expectEqual(
        @as(u64, 0x40),
        try dir.arrayElementU64(330, 0, decoder.endian, source),
    );
}

test "parser-only decoder releases every allocation failure point" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        traverseTwoIfds,
        .{},
    );
}

test "parser-only module declarations remain independently analyzable" {
    std.testing.refAllDecls(tiffz);
}
