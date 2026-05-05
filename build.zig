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

    const lib = b.addLibrary(.{
        .name = "tiffz",
        .linkage = .static,
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Expose a named module for downstream Zig consumers:
    //     dep.module("tiffz") — full Zig API surface.
    _ = b.addModule("tiffz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

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
    cli.linkLibrary(lib);
    b.installArtifact(cli);
    const install_cli = b.addInstallArtifact(cli, .{});

    // --- Header install (so downstream C consumers can `#include <tiffz.h>`) ---
    b.installFile("include/tiffz.h", "include/tiffz.h");

    // --- Unit tests ---
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
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
    const fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixture_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    fixture_tests.root_module.addImport("tiffz", lib_module);

    const run_fixture_tests = b.addRunArtifact(fixture_tests);

    const test_step = b.step("test", "Run unit, CLI, and fixture tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_fixture_tests.step);
}
