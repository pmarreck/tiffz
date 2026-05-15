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

    // --- Zig core library (static, with C FFI) ---
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // zlib for compression=8 / compression=32946 (Deflate / AdobeDeflate).
    // allyourcodebase/zlib is a Zig-built wrapper around upstream C zlib;
    // produces a static archive we link into tiffz's static lib.
    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });
    const zlib_lib = zlib_dep.artifact("z");
    lib_module.addIncludePath(zlib_lib.getEmittedIncludeTree());

    lib_module.linkLibrary(zlib_lib);

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
                .@"openjpeg-include" = opt_openjpeg_inc,
            });
        }
        break :blk b.dependency("jpegz", .{
            .target = target,
            .optimize = optimize,
            .@"with-charls" = false,
        });
    };
    const jpegz_mod = jpegz_dep.module("jpegz");
    lib_module.addImport("jpegz", jpegz_mod);
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
    tiffz_named_module.addIncludePath(zlib_lib.getEmittedIncludeTree());
    tiffz_named_module.addImport("jpegz", jpegz_mod);

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
    unit_tests_module.addIncludePath(zlib_lib.getEmittedIncludeTree());
    unit_tests_module.linkLibrary(zlib_lib);
    unit_tests_module.addImport("jpegz", jpegz_mod);
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
    fixture_tests_module.addIncludePath(zlib_lib.getEmittedIncludeTree());
    fixture_tests_module.linkLibrary(zlib_lib);
    const fixture_tests = b.addTest(.{ .root_module = fixture_tests_module });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);

    const test_step = b.step("test", "Run unit, CLI, and fixture tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_fixture_tests.step);
}
