//! External-consumer contract for tiffz's exported lercz artifact (Einstein
//! 2026-08-20). This package is EXACTLY the downstream shape that failed for
//! validate: an independent build that does `b.dependency("tiffz", ...)
//! .artifact("lerc")` and links the LERC C ABI through that artifact — not
//! through tiffz's module graph. If tiffz stops installing the artifact, the
//! dependency lookup here fails and the contract check goes red.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    const tiffz_dep = b.dependency("tiffz", .{
        .target = target,
        .optimize = optimize,
    });
    // THE contract under test: the artifact must be discoverable by name from
    // a downstream package. Same instance tiffz's own module links.
    const lerc = tiffz_dep.artifact("lerc");

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
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the LERC C ABI consumer proof");
    run_step.dependOn(&run.step);
}
