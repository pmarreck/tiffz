//! liblzma (xz 5.8.3, 0BSD) decoder subset as a static library and a Zig
//! module, for TIFF Compression 34925. Built from the pinned upstream
//! release tarball; nothing from xz is vendored into this repo.
//!
//! Decoders: the .xz stream and block format, LZMA1/LZMA2 and Delta (the
//! chain libtiff's tif_lzma.c writes). Checks: CRC32, CRC64 and SHA-256, so
//! a damaged stream that still decodes fails its declared check. No encoder,
//! no threads, no BCJ filters (a stream that uses them reports
//! LZMA_OPTIONS_ERROR).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const xz = b.dependency("xz_src", .{});

    const lib = b.addLibrary(.{
        .name = "lzma",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const m = lib.root_module;
    inline for (.{
        "src/liblzma/api",   "src/liblzma/common", "src/liblzma/check",
        "src/liblzma/lz",    "src/liblzma/lzma",   "src/liblzma/rangecoder",
        "src/liblzma/delta", "src/liblzma/simple", "src/common",
    }) |dir| m.addIncludePath(xz.path(dir));

    const size_t_bytes = target.result.ptrBitWidth() / 8;
    const defines = [_][2][]const u8{
        .{ "HAVE_STDINT_H", "1" },
        .{ "HAVE_INTTYPES_H", "1" },
        .{ "HAVE_STDBOOL_H", "1" },
        .{ "HAVE__BOOL", "1" },
        .{ "HAVE_DECODERS", "1" },
        .{ "HAVE_DECODER_LZMA1", "1" },
        .{ "HAVE_DECODER_LZMA2", "1" },
        .{ "HAVE_DECODER_DELTA", "1" },
        .{ "HAVE_CHECK_CRC32", "1" },
        .{ "HAVE_CHECK_CRC64", "1" },
        .{ "HAVE_CHECK_SHA256", "1" },
        .{ "HAVE_INTERNAL_SHA256", "1" },
        .{ "TUKLIB_SYMBOL_PREFIX", "lzma_" },
        .{ "ASSUME_RAM", "128" },
        .{ "LZMA_API_STATIC", "1" },
        // Upstream release builds define NDEBUG. lzma_stream_buffer_decode
        // restores in_pos and out_pos before asserting on them, so with
        // asserts on, a truncated stream aborts instead of returning an error.
        .{ "NDEBUG", "1" },
    };
    for (defines) |d| m.addCMacro(d[0], d[1]);
    m.addCMacro("SIZEOF_SIZE_T", b.fmt("{d}", .{size_t_bytes}));

    // gnu99: mythread.h needs sigset_t and sigprocmask, which strict C99
    // hides (upstream defines the system-extension macros through autotools).
    const flags = [_][]const u8{ "-std=gnu99", "-fno-strict-aliasing" };
    m.addCSourceFiles(.{ .root = xz.path("src/liblzma"), .flags = &flags, .files = &.{
        "check/check.c",
        "check/crc32_fast.c",
        "check/crc64_fast.c",
        "check/sha256.c",
        "common/block_util.c",
        "common/common.c",
        "common/filter_common.c",
        "common/index.c",
        "common/stream_flags_common.c",
        "common/vli_size.c",
        "common/block_decoder.c",
        "common/block_header_decoder.c",
        "common/filter_decoder.c",
        "common/filter_flags_decoder.c",
        "common/index_hash.c",
        "common/stream_buffer_decoder.c",
        "common/stream_decoder.c",
        "common/stream_flags_decoder.c",
        "common/vli_decoder.c",
        "lz/lz_decoder.c",
        "lzma/lzma_decoder.c",
        "lzma/lzma2_decoder.c",
        "lzma/lzma_encoder_presets.c",
        "delta/delta_common.c",
        "delta/delta_decoder.c",
    } });
    lib.installHeadersDirectory(xz.path("src/liblzma/api"), "", .{});
    b.installArtifact(lib);

    const mod = b.addModule("lzma", .{
        .root_source_file = b.path("lzma.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(xz.path("src/liblzma/api"));
    mod.addCMacro("LZMA_API_STATIC", "1");
    mod.linkLibrary(lib);
}
