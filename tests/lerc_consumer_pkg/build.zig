//! External-consumer contract for tiffz's exported native codec artifacts.
//! This package is the downstream shape that failed for validate: an
//! independent build resolves artifacts from `b.dependency("tiffz", ...)` and
//! links their C ABIs without tiffz's module graph. If tiffz stops installing
//! either artifact, the dependency lookup here fails and the contract goes red.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    const tiffz_dep = b.dependency("tiffz", .{
        .target = target,
        .optimize = optimize,
    });
    // The contract under test: both artifacts must be discoverable by name
    // from a downstream package. Each must be the instance tiffz's module uses.
    const lerc = tiffz_dep.artifact("lerc");
    const zstd = tiffz_dep.artifact("zstd");

    const exe = b.addExecutable(.{
        .name = "lerc-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.linkLibrary(lerc);
    exe.root_module.linkLibrary(zstd);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the LERC and Zstandard C ABI consumer proof");
    run_step.dependOn(&run.step);
}
