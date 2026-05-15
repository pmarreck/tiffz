const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseFast default — see CLAUDE.md "Zig-Specific Notes"
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // ============================================================
    // Core Zig library: src/jpegz.zig
    // No I/O — pure decode logic. The C FFI (Phase 1 milestone 6)
    // and any consumer (validate, tiffz) will sit on top of this.
    // ============================================================
    const jpegz_mod = b.addModule("jpegz", .{
        .root_source_file = b.path("src/jpegz.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link C deps (system; provided by Nix flake's buildInputs):
    //   - libjpeg-turbo (jpeglib.h, used by src/ffi/libjpeg_wrapper.zig)
    //   - openjpeg     (openjpeg.h, used by src/ffi/openjpeg_wrapper.zig)
    //   - charls       (charls/charls.h, used by src/ffi/charls_wrapper.zig)
    //                   — VENDORED: compiled from source via -Dcharls-src
    //                   or CHARLS_SRC env, see the charls block below.
    jpegz_mod.linkSystemLibrary("jpeg", .{});
    jpegz_mod.linkSystemLibrary("openjp2", .{});
    jpegz_mod.link_libcpp = true;
    jpegz_mod.link_libc = true;

    // Optional explicit include / library paths from the flake. When
    // cross-targeting (musl on Linux), Zig's host NIX_CFLAGS / NIX_LDFLAGS
    // don't apply; the flake passes the right pkgsStatic paths via these
    // -D options. On native builds these are unset and Zig finds the
    // libraries via the host wrapper-cc as usual.
    const opt_libjpeg_inc = b.option([]const u8, "libjpeg-include", "Path to libjpeg headers");
    const opt_libjpeg_lib = b.option([]const u8, "libjpeg-lib", "Path to libjpeg library directory");
    const opt_openjpeg_inc = b.option([]const u8, "openjpeg-include", "Path to openjpeg headers (incl. version subdir)");
    const opt_openjpeg_lib = b.option([]const u8, "openjpeg-lib", "Path to openjpeg library directory");
    if (opt_libjpeg_inc) |p| jpegz_mod.addIncludePath(.{ .cwd_relative = p });
    if (opt_libjpeg_lib) |p| jpegz_mod.addLibraryPath(.{ .cwd_relative = p });
    if (opt_openjpeg_inc) |p| jpegz_mod.addIncludePath(.{ .cwd_relative = p });
    if (opt_openjpeg_lib) |p| jpegz_mod.addLibraryPath(.{ .cwd_relative = p });

    // ── charls — vendored, compiled by Zig ────────────────────
    //
    // We tried two paths through nixpkgs binaries first; both broke
    // (gcc/libstdc++ vs Zig's libc++ symbol mismatch on Linux musl,
    // then libcxxStdenv-on-musl missing libgcc_eh). Vendoring the
    // source and compiling via Zig's own clang+libc++ keeps the C++
    // stdlib consistent end-to-end. The 8 .cpp files take a few
    // seconds to compile; the resulting `libcharls.a` ships with us.
    //
    // Source path comes from `-Dcharls-src=...` (set by flake) or
    // `CHARLS_SRC` env var (set by dev shell).
    const charls_src_path: ?[]const u8 = b.option(
        []const u8, "charls-src",
        "Path to vendored charls source tree (with src/ + include/charls/)",
    ) orelse b.graph.environ_map.get("CHARLS_SRC");

    const charls_lib: *std.Build.Step.Compile = blk: {
        const path = charls_src_path orelse @panic(
            "charls source path required: pass -Dcharls-src=PATH or set CHARLS_SRC env. " ++
            "Inside the nix devShell or nix build, both are configured automatically.",
        );
        const charls_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        charls_mod.link_libcpp = true;
        charls_mod.addCSourceFiles(.{
            .root = .{ .cwd_relative = path },
            .files = &.{
                "src/charls_jpegls_decoder.cpp",
                "src/charls_jpegls_encoder.cpp",
                "src/jpeg_stream_reader.cpp",
                "src/jpeg_stream_writer.cpp",
                "src/jpegls_error.cpp",
                "src/jpegls.cpp",
                "src/validate_spiff_header.cpp",
                "src/version.cpp",
            },
            .flags = &.{
                "-std=c++17",
                "-fexceptions",
                "-Wno-unused-parameter",
            },
        });
        charls_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{path}) });
        charls_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/src", .{path}) });
        const lib = b.addLibrary(.{
            .name = "charls",
            .linkage = .static,
            .root_module = charls_mod,
        });
        break :blk lib;
    };
    jpegz_mod.linkLibrary(charls_lib);
    if (charls_src_path) |path| {
        jpegz_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{path}) });
    }

    const lib = b.addLibrary(.{
        .name = "jpegz",
        .linkage = .static,
        .root_module = jpegz_mod,
    });
    b.installArtifact(lib);

    // ============================================================
    // C ABI: install include/jpegz_core.h (curated) and generate
    // include/jpegz_errno.h (auto from src/core/errors.zig).
    // ============================================================
    const errors_mod = b.createModule(.{
        .root_source_file = b.path("src/core/errors.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const gen_header_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_c_header.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    gen_header_mod.addImport("errors", errors_mod);
    const gen_header_exe = b.addExecutable(.{
        .name = "jpegz-gen-header",
        .root_module = gen_header_mod,
    });
    const run_gen = b.addRunArtifact(gen_header_exe);
    const generated_errno_h = run_gen.addOutputFileArg("jpegz_errno.h");
    lib.step.dependOn(&run_gen.step);

    b.installFile("include/jpegz_core.h", "include/jpegz_core.h");
    const installed_errno = b.addInstallFileWithDir(
        generated_errno_h,
        .header,
        "jpegz_errno.h",
    );
    b.getInstallStep().dependOn(&installed_errno.step);

    // ============================================================
    // Test runner — three sources of tests:
    //   1. tests/unit/smoke.zig   — public-API wiring
    //   2. src/jpegz.zig          — inline tests (helpers, types)
    //   3. src/core/errors.zig    — inline tests (numeric stability)
    // The `test` step depends on all three; failure of any propagates.
    // ============================================================
    const test_step = b.step("test", "Run unit tests");

    // (1) Public smoke suite — imports `jpegz` like any consumer.
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_mod.addImport("jpegz", jpegz_mod);
    const smoke_tests = b.addTest(.{
        .name = "smoke",
        .root_module = smoke_mod,
    });
    test_step.dependOn(&b.addRunArtifact(smoke_tests).step);

    // (2) Inline tests in the core module itself.
    const jpegz_inline_tests = b.addTest(.{
        .name = "jpegz_inline",
        .root_module = jpegz_mod,
    });
    test_step.dependOn(&b.addRunArtifact(jpegz_inline_tests).step);

    // (2b) Cleanroom decode unit tests (each module owns its own tests).
    const bitstream_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/bitstream.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bitstream_tests = b.addTest(.{
        .name = "decode_bitstream",
        .root_module = bitstream_mod,
    });
    test_step.dependOn(&b.addRunArtifact(bitstream_tests).step);

    const huffman_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/huffman.zig"),
        .target = target,
        .optimize = optimize,
    });
    const huffman_tests = b.addTest(.{
        .name = "decode_huffman",
        .root_module = huffman_mod,
    });
    test_step.dependOn(&b.addRunArtifact(huffman_tests).step);

    const idct_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/idct.zig"),
        .target = target,
        .optimize = optimize,
    });
    const idct_tests = b.addTest(.{
        .name = "decode_idct",
        .root_module = idct_mod,
    });
    test_step.dependOn(&b.addRunArtifact(idct_tests).step);

    const last_error_mod = b.createModule(.{
        .root_source_file = b.path("src/core/last_error.zig"),
        .target = target,
        .optimize = optimize,
    });
    const last_error_tests = b.addTest(.{
        .name = "core_last_error",
        .root_module = last_error_mod,
    });
    test_step.dependOn(&b.addRunArtifact(last_error_tests).step);

    const arith_coder_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/arith_coder.zig"),
        .target = target,
        .optimize = optimize,
    });
    const arith_coder_tests = b.addTest(.{
        .name = "decode_arith_coder",
        .root_module = arith_coder_mod,
    });
    test_step.dependOn(&b.addRunArtifact(arith_coder_tests).step);

    const jpegls_bitstream_mod = b.createModule(.{
        .root_source_file = b.path("src/decode/jpegls_bitstream.zig"),
        .target = target,
        .optimize = optimize,
    });
    const jpegls_bitstream_tests = b.addTest(.{
        .name = "decode_jpegls_bitstream",
        .root_module = jpegls_bitstream_mod,
    });
    test_step.dependOn(&b.addRunArtifact(jpegls_bitstream_tests).step);

    // The jpegls cleanroom (`src/decode/jpegls.zig`) and its codec
    // helpers (`jpegls_codec.zig`) belong to jpegz_mod via relative
    // @imports from `src/jpegz.zig`'s dispatch. The codec module
    // pulls in the bit reader via the named import `"jpegls_bitstream"`,
    // which we wire on jpegz_mod here so it resolves transitively.
    // Their inline tests run via `jpegz_inline_tests` (no separate
    // test target — that would put their files in two modules and
    // Zig 0.16 rejects it).
    jpegz_mod.addImport("jpegls_bitstream", jpegls_bitstream_mod);

    // Cleanroom decoder modules (baseline.zig etc.) are tested
    // implicitly via the dispatch in src/jpegz.zig — when a fixture
    // matches the cleanroom's supported shape (8-bit, no subsampling,
    // no DRI), the dispatcher routes to it; otherwise falls back to
    // libjpeg_wrapper. Tier 1 fixture coverage is the indirect test
    // surface. (Direct tests would need a separate baseline_mod which
    // creates a module-cycle through jpegz.zig.)

    // (3) Decode test suite (M1.3 — baseline + progressive wrap).
    const decode_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_mod.addImport("jpegz", jpegz_mod);
    const decode_tests = b.addTest(.{
        .name = "decode",
        .root_module = decode_mod,
    });
    test_step.dependOn(&b.addRunArtifact(decode_tests).step);

    // (4) Validate test suite (M1.5 — hand-written marker walker).
    const validate_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/validate.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_mod.addImport("jpegz", jpegz_mod);
    const validate_tests = b.addTest(.{
        .name = "validate",
        .root_module = validate_mod,
    });
    test_step.dependOn(&b.addRunArtifact(validate_tests).step);

    // (5) JPEG 2000 decode test suite (M1.6 — openjpeg wrap).
    const decode_jp2_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/decode_jp2.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_jp2_mod.addImport("jpegz", jpegz_mod);
    const decode_jp2_tests = b.addTest(.{
        .name = "decode_jp2",
        .root_module = decode_jp2_mod,
    });
    test_step.dependOn(&b.addRunArtifact(decode_jp2_tests).step);

    // ============================================================
    // `zig build fuzz` — fuzz harnesses for jpegz.decode and
    // jpegz.validate. Wrapped by `./fuzz` Bash script. Distinct from
    // the `test` step so the long-running fuzz mode (`zig build fuzz
    // --fuzz`) doesn't bloat regular CI.
    //
    // Without `--fuzz` each test replays its seed corpus once — acts
    // as a smoke check that the harness compiles and the corpus is
    // wired correctly. With `--fuzz`, Zig's in-tree libfuzzer drives
    // coverage-guided mutation.
    // ============================================================
    const fuzz_step = b.step("fuzz", "Run fuzz harnesses (use --fuzz for coverage-guided mutation)");

    // Shared seed-corpus module lives next to tests/unit/fixtures/ so
    // its `@embedFile` calls resolve inside its own package. The fuzz
    // harnesses pull it in as `@import("seed")`.
    const seed_corpus_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/seed_corpus.zig"),
        .target = target,
        .optimize = optimize,
    });

    const decode_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/decode_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_fuzz_mod.addImport("jpegz", jpegz_mod);
    decode_fuzz_mod.addImport("seed", seed_corpus_mod);
    const decode_fuzz_tests = b.addTest(.{
        .name = "decode_fuzz",
        .root_module = decode_fuzz_mod,
    });
    fuzz_step.dependOn(&b.addRunArtifact(decode_fuzz_tests).step);

    const validate_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/validate_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_fuzz_mod.addImport("jpegz", jpegz_mod);
    validate_fuzz_mod.addImport("seed", seed_corpus_mod);
    const validate_fuzz_tests = b.addTest(.{
        .name = "validate_fuzz",
        .root_module = validate_fuzz_mod,
    });
    fuzz_step.dependOn(&b.addRunArtifact(validate_fuzz_tests).step);

    // ============================================================
    // C FFI smoke test (M1.7 — exercises include/jpegz_core.h via a
    // tiny C program that links against libjpegz.a). Same exec
    // dogfoods the public ABI the way validate / tiffz will.
    // ============================================================
    const c_smoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The c_smoke executable transitively pulls in libjpeg + openjp2
    // because libjpegz.a uses them. When cross-targeting (musl on
    // Linux), Zig's host NIX_LDFLAGS doesn't apply — we have to point
    // c_smoke at the same -Dlibjpeg-lib / -Dopenjpeg-lib paths the
    // library itself was given. Native builds: these options are
    // unset and Zig finds the libs via the host wrapper-cc.
    c_smoke_mod.linkSystemLibrary("jpeg", .{});
    c_smoke_mod.linkSystemLibrary("openjp2", .{});
    c_smoke_mod.link_libcpp = true; // libjpegz.a pulls in vendored charls (C++)
    if (opt_libjpeg_lib) |p| c_smoke_mod.addLibraryPath(.{ .cwd_relative = p });
    if (opt_openjpeg_lib) |p| c_smoke_mod.addLibraryPath(.{ .cwd_relative = p });
    const c_smoke = b.addExecutable(.{
        .name = "c_smoke",
        .root_module = c_smoke_mod,
    });
    c_smoke_mod.addCSourceFile(.{
        .file = b.path("tests/cli/smoke.c"),
        .flags = &.{ "-std=c23", "-Wall", "-Wextra", "-Wpedantic" },
    });
    c_smoke_mod.addIncludePath(b.path("include"));
    c_smoke_mod.addIncludePath(generated_errno_h.dirname());
    // C23 #embed needs to reach ../unit/fixtures/ relative to the .c file.
    c_smoke_mod.addIncludePath(b.path("tests"));
    c_smoke_mod.linkLibrary(lib);
    test_step.dependOn(&b.addRunArtifact(c_smoke).step);

    // ============================================================
    // `zig build cleanroom-diff` — non-committed analysis tool that
    // walks a directory of JPEGs and diffs cleanroom vs. wrapper
    // output per-file. Source lives in scratch/ (gitignored). Skip
    // if the file isn't present (so a fresh checkout doesn't fail).
    // ============================================================
    if (std.Io.Dir.cwd().access(b.graph.io,"scratch/cleanroom_diff.zig", .{})) {
        // The diff binary lives in scratch/ (gitignored) and consumes
        // jpegz's public test surface (jpegz.internal.cleanroomDecode +
        // jpegz.internal.wrapperDecode) so it doesn't need to load
        // baseline / libjpeg_wrapper as separate modules — the existing
        // jpegz module covers everything.
        const diff_mod = b.createModule(.{
            .root_source_file = b.path("scratch/cleanroom_diff.zig"),
            .target = target,
            .optimize = optimize,
        });
        diff_mod.addImport("jpegz", jpegz_mod);
        const diff_exe = b.addExecutable(.{
            .name = "cleanroom-diff",
            .root_module = diff_mod,
        });
        const diff_step = b.step("cleanroom-diff", "Build the scratch/ cleanroom-diff harness");
        diff_step.dependOn(&b.addInstallArtifact(diff_exe, .{}).step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io,"scratch/diag_one.zig", .{})) {
        const diag_mod = b.createModule(.{
            .root_source_file = b.path("scratch/diag_one.zig"),
            .target = target,
            .optimize = optimize,
        });
        diag_mod.addImport("jpegz", jpegz_mod);
        const diag_exe = b.addExecutable(.{
            .name = "diag-one",
            .root_module = diag_mod,
        });
        const diag_step = b.step("diag-one", "Single-file decoder diagnostic (scratch/diag_one.zig)");
        diag_step.dependOn(&b.addInstallArtifact(diag_exe, .{}).step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io,"scratch/pixel_diff.zig", .{})) {
        const pd_mod = b.createModule(.{
            .root_source_file = b.path("scratch/pixel_diff.zig"),
            .target = target,
            .optimize = optimize,
        });
        pd_mod.addImport("jpegz", jpegz_mod);
        const pd_exe = b.addExecutable(.{
            .name = "pixel-diff",
            .root_module = pd_mod,
        });
        const pd_step = b.step("pixel-diff", "Per-pixel cleanroom-vs-wrapper diff (scratch/pixel_diff.zig)");
        pd_step.dependOn(&b.addInstallArtifact(pd_exe, .{}).step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io,"scratch/dump_coefs_jpegz.zig", .{})) {
        const dc_mod = b.createModule(.{
            .root_source_file = b.path("scratch/dump_coefs_jpegz.zig"),
            .target = target,
            .optimize = optimize,
        });
        dc_mod.addImport("jpegz", jpegz_mod);
        const dc_exe = b.addExecutable(.{
            .name = "dump-coefs-jpegz",
            .root_module = dc_mod,
        });
        const dc_step = b.step("dump-coefs-jpegz", "Dump progressive cleanroom natural-order coefs (scratch/dump_coefs_jpegz.zig)");
        dc_step.dependOn(&b.addInstallArtifact(dc_exe, .{}).step);
    } else |_| {}

    if (std.Io.Dir.cwd().access(b.graph.io,"scratch/bench_one.zig", .{})) {
        const b1_mod = b.createModule(.{
            .root_source_file = b.path("scratch/bench_one.zig"),
            .target = target,
            .optimize = optimize,
        });
        b1_mod.addImport("jpegz", jpegz_mod);
        const b1_exe = b.addExecutable(.{
            .name = "bench-one",
            .root_module = b1_mod,
        });
        const b1_step = b.step("bench-one", "Single-file decode timing harness (scratch/bench_one.zig)");
        b1_step.dependOn(&b.addInstallArtifact(b1_exe, .{}).step);
    } else |_| {}
}
