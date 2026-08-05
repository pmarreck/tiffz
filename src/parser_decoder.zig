//! Codec-free TIFF header and IFD-chain decoder.
//!
//! This type intentionally stops at semantic container parsing. Pixel/strip
//! decoding remains on the full `tiffz.Decoder` surface in `decoder.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("errors.zig");
const Limits = @import("limits.zig").Limits;
const Source = @import("source.zig").Source;
const header_mod = @import("header.zig");
const ifd_mod = @import("ifd.zig");
const Ifd = ifd_mod.Ifd;

/// Parse TIFF headers and lazily materialize the linked IFD chain without
/// importing or dispatching any compression or image codec.
pub const Decoder = struct {
    allocator: Allocator,
    source: Source,
    limits: Limits,
    endian: header_mod.Endian,
    bigtiff: bool,
    ifds: std.ArrayListUnmanaged(Ifd),
    ifd_offsets: std.ArrayListUnmanaged(u64),
    next_ifd_offset: u64,

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

        var ifd0 = try ifd_mod.parse(
            allocator,
            source,
            h.endian,
            h.ifd0_offset,
            limits,
            offset_width,
        );
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

    pub fn deinit(self: *Decoder) void {
        for (self.ifds.items) |*dir| dir.deinit();
        self.ifds.deinit(self.allocator);
        self.ifd_offsets.deinit(self.allocator);
    }

    pub fn ifdCount(self: *const Decoder) usize {
        return self.ifds.items.len;
    }

    /// Return an IFD by index, lazily following and cycle-checking the linked
    /// chain until the requested directory has been materialized.
    pub fn ifd(self: *Decoder, index: usize) errors.Error!*const Ifd {
        while (index >= self.ifds.items.len) {
            if (self.next_ifd_offset == 0) return error.InvalidArgument;
            if (self.ifds.items.len >= self.limits.max_ifds) {
                return error.LimitExceededIfdCount;
            }
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
        }
        return &self.ifds.items[index];
    }
};
