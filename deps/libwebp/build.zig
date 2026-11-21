//! libwebp 1.6.0 (BSD-3-Clause) decoder as a static library and a Zig
//! module, for TIFF Compression 50001. Built from the pinned upstream
//! release tarball; nothing from libwebp is vendored into this repo.
//!
//! Sources are libwebp's own decoder set (makefile.unix DEC_OBJS,
//! DSP_DEC_OBJS and UTILS_DEC_OBJS). The SSE2, SSE4.1, NEON, MIPS and MSA
//! files compile to nothing on targets without those instructions, so one
//! list serves every platform. No encoder, no demuxer, no threads.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const src = b.dependency("libwebp_src", .{});

    const lib = b.addLibrary(.{
        .name = "webp",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const m = lib.root_module;
    m.addIncludePath(src.path(""));
    m.addIncludePath(src.path("src"));
    m.addCMacro("NDEBUG", "1");
    const flags = [_][]const u8{ "-fvisibility=hidden", "-fno-strict-aliasing" };
    m.addCSourceFiles(.{ .root = src.path("src"), .flags = &flags, .files = &.{
        "dec/alpha_dec.c",
        "dec/buffer_dec.c",
        "dec/frame_dec.c",
        "dec/idec_dec.c",
        "dec/io_dec.c",
        "dec/quant_dec.c",
        "dec/tree_dec.c",
        "dec/vp8_dec.c",
        "dec/vp8l_dec.c",
        "dec/webp_dec.c",
        "dsp/alpha_processing.c",
        "dsp/alpha_processing_mips_dsp_r2.c",
        "dsp/alpha_processing_neon.c",
        "dsp/alpha_processing_sse2.c",
        "dsp/alpha_processing_sse41.c",
        "dsp/cpu.c",
        "dsp/dec.c",
        "dsp/dec_clip_tables.c",
        "dsp/dec_mips32.c",
        "dsp/dec_mips_dsp_r2.c",
        "dsp/dec_msa.c",
        "dsp/dec_neon.c",
        "dsp/dec_sse2.c",
        "dsp/dec_sse41.c",
        "dsp/filters.c",
        "dsp/filters_mips_dsp_r2.c",
        "dsp/filters_msa.c",
        "dsp/filters_neon.c",
        "dsp/filters_sse2.c",
        "dsp/lossless.c",
        "dsp/lossless_mips_dsp_r2.c",
        "dsp/lossless_msa.c",
        "dsp/lossless_neon.c",
        "dsp/lossless_sse2.c",
        "dsp/lossless_sse41.c",
        "dsp/rescaler.c",
        "dsp/rescaler_mips32.c",
        "dsp/rescaler_mips_dsp_r2.c",
        "dsp/rescaler_msa.c",
        "dsp/rescaler_neon.c",
        "dsp/rescaler_sse2.c",
        "dsp/upsampling.c",
        "dsp/upsampling_mips_dsp_r2.c",
        "dsp/upsampling_msa.c",
        "dsp/upsampling_neon.c",
        "dsp/upsampling_sse2.c",
        "dsp/upsampling_sse41.c",
        "dsp/yuv.c",
        "dsp/yuv_mips32.c",
        "dsp/yuv_mips_dsp_r2.c",
        "dsp/yuv_neon.c",
        "dsp/yuv_sse2.c",
        "dsp/yuv_sse41.c",
        "utils/bit_reader_utils.c",
        "utils/color_cache_utils.c",
        "utils/filters_utils.c",
        "utils/huffman_utils.c",
        "utils/palette.c",
        "utils/quant_levels_dec_utils.c",
        "utils/random_utils.c",
        "utils/rescaler_utils.c",
        "utils/thread_utils.c",
        "utils/utils.c",
    } });
    lib.installHeadersDirectory(src.path("src/webp"), "webp", .{});
    b.installArtifact(lib);

    const mod = b.addModule("webp", .{
        .root_source_file = b.path("webp.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(src.path("src"));
    mod.linkLibrary(lib);
}
