const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Default to ReleaseFast per project convention. Debug builds
    // must announce themselves on stderr (see CLI startup) so
    // benchmarks don't accidentally measure an unoptimized build.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // Parser-only public module for container classifiers such as rawz. This
    // target deliberately receives no codec imports or linked libraries.
    const parser_module = b.addModule("tiffz-parser", .{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A real downstream executable keeps the parser boundary independently
    // buildable and gives the Nix closure gate an artifact to inspect.
    const parser_consumer = b.addExecutable(.{
        .name = "tiffz-parser-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/parser_consumer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tiffz-parser", .module = parser_module }},
        }),
    });
    const install_parser_consumer = b.addInstallArtifact(parser_consumer, .{});
    const parser_consumer_step = b.step(
        "parser-consumer",
        "Build the codec-free tiffz-parser consumer artifact",
    );
    parser_consumer_step.dependOn(&install_parser_consumer.step);

    // --- Zig core library (static, with C FFI) ---
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_module.addImport("tiffz-parser", parser_module);

    // lzwz is shared with Validate's PDF and GIF adapters. Keep one module
    // instance rooted in tiffz and re-export it from src/lib.zig; a downstream
    // second b.dependency call would make Zig 0.16 reject duplicate roots.
    const lzwz_dep = b.dependency("lzwz", .{
        .target = target,
        .optimize = optimize,
    });
    const lzwz_mod = lzwz_dep.module("lzwz");
    lib_module.addImport("lzwz", lzwz_mod);

    // zlib for compression=8 / compression=32946 (Deflate / AdobeDeflate).
    // Use the system zlib (provided via flake.nix buildInputs) rather
    // than the allyourcodebase/zlib Zig-builds-the-C-source wrapper.
    // The wrapper's build.zig doesn't add the upstream source dir as
    // an include path, and Zig 0.16's `addCSourceFiles({.root, .files})`
    // doesn't fall back to file-directory for quoted `#include`s on
    // some target triples — the result is `zconf.h not found` errors.
    // System zlib is universal, much smaller, and side-steps the
    // problem entirely.
    const opt_zlib_inc = b.option(
        []const u8,
        "zlib-include",
        "Path to zlib headers",
    ) orelse "";
    const opt_zlib_lib_path = b.option(
        []const u8,
        "zlib-lib",
        "Path to zlib library directory",
    ) orelse "";
    if (opt_zlib_inc.len > 0) lib_module.addIncludePath(.{ .cwd_relative = opt_zlib_inc });
    if (opt_zlib_lib_path.len > 0) lib_module.addLibraryPath(.{ .cwd_relative = opt_zlib_lib_path });
    lib_module.linkSystemLibrary("z", .{});

    // jpegz for compression=7 (JPEG-in-TIFF) at M9.5 and lossless JPEG
    // (DNG raw) at M8. Peter's sibling project — Phase 1 wraps
    // libjpeg-turbo + openjpeg via system libraries; Phase 2 (cleanroom)
    // will remove the C deps. Skip charls (JPEG-LS) — not needed for
    // any TIFF compression scheme.
    //
    // openjpeg.h is nested under `include/openjpeg-2.5/` in nixpkgs;
    // pass the versioned path through to the dep build so Zig's
    // bundled clang finds the header at @cImport time. The OPENJPEG_INC
    // env var is set by the flake.nix devShell (and explicitly by the
    // nix sandbox buildPhase via -Dopenjpeg-include); native non-Nix
    // builds expect openjpeg to be on the system include path
    // (Homebrew etc.) — leave the option unset in that case.
    // Forward these jpegz build options when our consumer (the Nix
    // sandbox buildPhase) passes them on the command line, OR when
    // the dev shell sets the matching env var. Native non-Nix builds
    // leave them unset and Zig finds the C libs via the system include
    // / library path.
    const opt_openjpeg_inc = b.option(
        []const u8,
        "openjpeg-include",
        "Path to openjpeg headers (incl. version subdir)",
    ) orelse b.graph.environ_map.get("OPENJPEG_INC") orelse "";
    const opt_openjpeg_lib = b.option(
        []const u8,
        "openjpeg-lib",
        "Path to openjpeg library directory",
    ) orelse "";
    const opt_libjpeg_inc = b.option(
        []const u8,
        "libjpeg-include",
        "Path to libjpeg-turbo headers",
    ) orelse "";
    const opt_libjpeg_lib = b.option(
        []const u8,
        "libjpeg-lib",
        "Path to libjpeg-turbo library directory",
    ) orelse "";

    const jpegz_dep = blk: {
        // Build the dependency args struct dynamically — Zig's b.dependency
        // wants known fields, so branch on whether each path is set.
        if (opt_openjpeg_inc.len > 0 and opt_openjpeg_lib.len > 0 and
            opt_libjpeg_inc.len > 0 and opt_libjpeg_lib.len > 0)
        {
            break :blk b.dependency("jpegz", .{
                .target = target,
                .optimize = optimize,
                .@"with-charls" = false,
                .@"with-libjpeg-oracle" = false,
                .@"openjpeg-include" = opt_openjpeg_inc,
                .@"openjpeg-lib" = opt_openjpeg_lib,
                .@"libjpeg-include" = opt_libjpeg_inc,
                .@"libjpeg-lib" = opt_libjpeg_lib,
            });
        }
        if (opt_openjpeg_inc.len > 0) {
            break :blk b.dependency("jpegz", .{
                .target = target,
                .optimize = optimize,
                .@"with-charls" = false,
                .@"with-libjpeg-oracle" = false,
                .@"openjpeg-include" = opt_openjpeg_inc,
            });
        }
        break :blk b.dependency("jpegz", .{
            .target = target,
            .optimize = optimize,
            .@"with-charls" = false,
            .@"with-libjpeg-oracle" = false,
        });
    };
    const jpegz_mod = jpegz_dep.module("jpegz");
    lib_module.addImport("jpegz", jpegz_mod);

    // zstdz — pmarreck's fork of facebook/zstd, vendored C library
    // built by zstdz itself (no system zstd dep). Provides the codec
    // for Compression=50000 (ZSTD-in-TIFF, GDAL/libtiff extension).
    const zstdz_dep = b.dependency("zstdz", .{
        .target = target,
        .optimize = optimize,
    });
    const zstdz_mod = zstdz_dep.module("zstd");
    lib_module.addImport("zstd", zstdz_mod);

    // lercz — pmarreck's Zig-wrap fork of Esri/lerc (Apache-2.0),
    // C++ sources built by lercz itself. Provides the codec for
    // Compression=34887 (LERC, GDAL/libtiff extension).
    const lercz_dep = b.dependency("lercz", .{
        .target = target,
        .optimize = optimize,
    });
    const lercz_mod = lercz_dep.module("lercz");
    lib_module.addImport("lercz", lercz_mod);
    const lib = b.addLibrary(.{
        .name = "tiffz",
        .linkage = .static,
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Expose a named module for downstream Zig consumers:
    //     dep.module("tiffz") — full Zig API surface.
    const tiffz_named_module = b.addModule("tiffz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tiffz_named_module.addImport("tiffz-parser", parser_module);
    if (opt_zlib_inc.len > 0) tiffz_named_module.addIncludePath(.{ .cwd_relative = opt_zlib_inc });
    if (opt_zlib_lib_path.len > 0) tiffz_named_module.addLibraryPath(.{ .cwd_relative = opt_zlib_lib_path });
    tiffz_named_module.linkSystemLibrary("z", .{});
    tiffz_named_module.addImport("lzwz", lzwz_mod);
    tiffz_named_module.addImport("jpegz", jpegz_mod);
    tiffz_named_module.addImport("zstd", zstdz_mod);
    tiffz_named_module.addImport("lercz", lercz_mod);

    // --- C CLI executable (dogfoods the C FFI per project convention) ---
    const cli = b.addExecutable(.{
        .name = "tiffz",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    cli.root_module.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{ "-std=gnu11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    cli.root_module.addIncludePath(b.path("include"));
    // Propagate system-library search paths so the linker can find
    // -lz, -ljpeg, -lopenjp2 referenced transitively through lib.
    if (opt_zlib_lib_path.len > 0) cli.root_module.addLibraryPath(.{ .cwd_relative = opt_zlib_lib_path });
    if (opt_libjpeg_lib.len > 0) cli.root_module.addLibraryPath(.{ .cwd_relative = opt_libjpeg_lib });
    if (opt_openjpeg_lib.len > 0) cli.root_module.addLibraryPath(.{ .cwd_relative = opt_openjpeg_lib });
    cli.root_module.linkLibrary(lib);
    b.installArtifact(cli);
    const install_cli = b.addInstallArtifact(cli, .{});

    // --- Header install (so downstream C consumers can `#include <tiffz.h>`) ---
    b.installFile("include/tiffz.h", "include/tiffz.h");

    // --- Unit tests ---
    const unit_tests_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_tests_module.addImport("tiffz-parser", parser_module);
    if (opt_zlib_inc.len > 0) unit_tests_module.addIncludePath(.{ .cwd_relative = opt_zlib_inc });
    if (opt_zlib_lib_path.len > 0) unit_tests_module.addLibraryPath(.{ .cwd_relative = opt_zlib_lib_path });
    unit_tests_module.linkSystemLibrary("z", .{});
    unit_tests_module.addImport("lzwz", lzwz_mod);
    unit_tests_module.addImport("jpegz", jpegz_mod);
    unit_tests_module.addImport("zstd", zstdz_mod);
    unit_tests_module.addImport("lercz", lercz_mod);
    const unit_tests = b.addTest(.{ .root_module = unit_tests_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // --- CLI integration tests (spawn the CLI binary, assert output) ---
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/cli_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    run_cli_tests.step.dependOn(&install_cli.step);

    // --- Fixture tests (decode real TIFFs from tests/fixtures/) ---
    // Imports the tiffz module directly; no CLI binary needed.
    const fixture_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/fixture_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fixture_tests_module.addImport("tiffz", lib_module);
    if (opt_zlib_inc.len > 0) fixture_tests_module.addIncludePath(.{ .cwd_relative = opt_zlib_inc });
    if (opt_zlib_lib_path.len > 0) fixture_tests_module.addLibraryPath(.{ .cwd_relative = opt_zlib_lib_path });
    fixture_tests_module.linkSystemLibrary("z", .{});
    const fixture_tests = b.addTest(.{ .root_module = fixture_tests_module });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);

    const parser_consumer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/parser_consumer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tiffz-parser", .module = parser_module }},
        }),
    });
    const run_parser_consumer_tests = b.addRunArtifact(parser_consumer_tests);
    const parser_test_step = b.step(
        "parser-test",
        "Run codec-free tiffz-parser consumer tests",
    );
    parser_test_step.dependOn(&run_parser_consumer_tests.step);

    const dual_module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dual_module_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tiffz", .module = tiffz_named_module },
                .{ .name = "tiffz-parser", .module = parser_module },
            },
        }),
    });
    const run_dual_module_tests = b.addRunArtifact(dual_module_tests);
    const dual_module_test_step = b.step(
        "dual-module-test",
        "Run the full-plus-parser Zig module ownership gate",
    );
    dual_module_test_step.dependOn(&run_dual_module_tests.step);

    const test_step = b.step("test", "Run unit, CLI, and fixture tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_fixture_tests.step);
    test_step.dependOn(&run_parser_consumer_tests.step);
    test_step.dependOn(&run_dual_module_tests.step);
}
