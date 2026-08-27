{
  description = "tiffz - cleanroom spec-complete TIFF reader (and eventually writer) in pure Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Pin Zig explicitly. zig-overlay exposes every release as a named
    # attribute. Update the version below when the whole portfolio moves.
    # tiffz upgraded to Zig 0.16.0 as part of the 2026-05-13 portfolio
    # 0.15 -> 0.16 sweep.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        isDarwin = pkgs.stdenv.isDarwin;
        isLinux = pkgs.stdenv.isLinux;
        zig = zig-overlay.packages.${system}."0.16.0";

        # On Linux, use a musl target explicitly. Two reasons:
        # (1) zig-overlay ships vanilla Zig (no Nix-sandbox patches),
        #     so its host-ABI detection fails inside Garnix's
        #     sandbox; the resulting glibc binary can't find its
        #     dynamic linker at runtime.
        # (2) musl produces fully static binaries — project
        #     portfolio convention (CLAUDE.md "Better static linking
        #     support").
        # macOS handles its own dynamic linker via apple-sdk and
        # doesn't have this issue.
        zigTarget =
          if system == "x86_64-linux"  then "x86_64-linux-musl"
          else if system == "aarch64-linux" then "aarch64-linux-musl"
          else null;
        zigTargetFlag = if zigTarget == null then "" else "-Dtarget=${zigTarget}";

        # On Linux, use pkgsStatic.{libjpeg,openjpeg,zlib} so the C
        # libs cross-link cleanly into the musl static binary. On
        # macOS / non-musl native targets, the regular pkgs builds work.
        jpegPkgs =
          if isLinux then {
            libjpeg = pkgs.pkgsStatic.libjpeg;
            openjpeg = pkgs.pkgsStatic.openjpeg;
            zlib = pkgs.pkgsStatic.zlib;
          } else {
            libjpeg = pkgs.libjpeg;
            openjpeg = pkgs.openjpeg;
            zlib = pkgs.zlib;
          };

        # GDAL's pytest suite segfaults on aarch64-darwin against
        # nixpkgs-unstable as of 2026-05-04 (Python 3.13 + GDAL 3.12.4
        # in gcore/hdf4multidim.py). We don't need GDAL's own tests,
        # only the binaries (gdal_translate, gdalinfo). Strip the
        # pytest-check-hook entirely — `doCheck = false` alone is
        # ineffective because the hook fires from nativeCheckInputs
        # regardless of the doCheck flag.
        gdalNoCheck = pkgs.gdal.overrideAttrs (old: {
          doCheck = false;
          dontCheck = true;
          doInstallCheck = false;
          checkPhase = "true";
          installCheckPhase = "true";
          nativeCheckInputs = [];
        });
        # Pre-fetched Zig dependencies (fixed-output derivation).
        # Update zigDepsHash when build.zig.zon changes:
        #   1. Set zigDepsHash = pkgs.lib.fakeHash;
        #   2. Run `nix build` — it fails with the correct hash;
        #   3. Replace zigDepsHash with that printed hash.
        zigDepsHash = "sha256-a7XUgcFojWJJptWv5ifyX9zGOy+i9eOdIjCQ9TZEGVI=";

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "tiffz-zig-deps";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = with pkgs; [ zig git cacert ];

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;

          # Capture the Zig global cache `p/` directory into $out/p/.
          # Mirrors the proven entropy_shield / validate pattern that
          # passes Garnix's stricter Linux sandbox — the project-local
          # `./zig-pkg/` capture seemed to work on macOS Garnix
          # builders but Linux builders demand the global-cache layout.
          # Consumer derivations rebuild the cache via
          # `cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/`.
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';

          installPhase = ''
            mkdir -p $out
            cp -r $TMPDIR/zig-cache/p $out/p
          '';

          dontFixup = true;
        };

        # Build the tiffz static lib + C CLI in a sandboxed Nix
        # derivation. Pre-fetched zlib dep is staged into the Zig
        # global cache before invoking zig build (the build itself
        # runs offline within the sandbox).
        tiffzPkg = pkgs.stdenv.mkDerivation {
          pname = "tiffz";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          # jpegz Phase 1 wraps libjpeg-turbo (baseline / progressive /
          # lossless JPEG for Compression=7 and DNG raw) + openjpeg (JPEG
          # 2000, currently unused by tiffz but linked unconditionally by
          # jpegz). charls (JPEG-LS) is gated off via -Dwith-charls=false
          # at the build.zig level since no TIFF compression scheme needs
          # JPEG-LS. zlib is for compression=8 / 32946 (Deflate /
          # AdobeDeflate); we use the system zlib (linked via
          # linkSystemLibrary("z")) rather than allyourcodebase/zlib,
          # which has a Zig 0.16 cross-compile quirk on Linux.
          buildInputs = [ jpegPkgs.libjpeg jpegPkgs.openjpeg jpegPkgs.zlib ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR

            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            ${pkgs.lib.optionalString isLinux ''
              # cross-musl: drop glibc-relative cc-wrapper flags so
              # they don't shadow musl headers from pkgsStatic.
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            ''}
            zig build --prefix $out -Doptimize=ReleaseFast ${zigTargetFlag} \
              -Dlibjpeg-include=${jpegPkgs.libjpeg.dev}/include \
              -Dlibjpeg-lib=${jpegPkgs.libjpeg.out}/lib \
              -Dopenjpeg-include=${jpegPkgs.openjpeg.dev}/include/openjpeg-2.5 \
              -Dopenjpeg-lib=${jpegPkgs.openjpeg.out}/lib \
              -Dzlib-include=${jpegPkgs.zlib.dev}/include \
              -Dzlib-lib=${jpegPkgs.zlib.out}/lib
          '';

          dontInstall = true;
          dontFixup = true;
        };

      in {
        packages.default = tiffzPkg;

        checks.parser-closure = pkgs.stdenv.mkDerivation {
          pname = "tiffz-parser-closure";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig pkgs.binutils ];

          # Nix itself rejects every store-path reference in the installed
          # parser artifact. This catches codec closure leakage even when a
          # future static link would leave no ELF NEEDED entry.
          allowedReferences = [];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            if ! zig build parser-consumer --verbose \
              -Doptimize=ReleaseSafe ${zigTargetFlag} \
              > parser-build.log 2>&1; then
              cat parser-build.log
              exit 1
            fi
            ${pkgs.bash}/bin/bash tests/parser_closure_test \
              zig-out/bin/tiffz-parser-consumer parser-build.log
          '';

          installPhase = ''
            mkdir -p $out
            cp zig-out/bin/tiffz-parser-consumer $out/
            ${pkgs.binutils}/bin/strip $out/tiffz-parser-consumer
            echo "parser closure passed" > $out/result
          '';

          dontFixup = true;
        };

        checks.jpeg-validation-closure = pkgs.stdenv.mkDerivation {
          pname = "tiffz-jpeg-validation-closure";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig pkgs.binutils pkgs.file pkgs.gnugrep ];
          buildInputs = [ jpegPkgs.openjpeg jpegPkgs.zlib ];

          # The installed proof is fully static and must retain no Nix store
          # reference, including any external JPEG-family decoder or oracle.
          allowedReferences = [];
          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            ${pkgs.lib.optionalString isLinux ''
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            ''}
            zig build jpeg-validation-consumer -Doptimize=ReleaseFast ${zigTargetFlag} \
              -Dopenjpeg-include=${jpegPkgs.openjpeg.dev}/include/openjpeg-2.5 \
              -Dopenjpeg-lib=${jpegPkgs.openjpeg.out}/lib \
              -Dzlib-include=${jpegPkgs.zlib.dev}/include \
              -Dzlib-lib=${jpegPkgs.zlib.out}/lib
            ${pkgs.bash}/bin/bash tests/jpeg_validation_closure_test \
              zig-out/bin/tiffz-jpeg-validation-proof
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/tiffz-jpeg-validation-proof $out/bin/
            ${pkgs.binutils}/bin/strip $out/bin/tiffz-jpeg-validation-proof
            echo "JPEG validation closure passed" > $out/result
          '';

          dontFixup = true;
        };

        # External-consumer contract for tiffz's exported native codec
        # artifacts: a separate package (tests/lerc_consumer_pkg, tiffz as a
        # path dependency) must resolve `artifact("lerc")` and
        # `artifact("zstd")`, then link and call both C ABIs. This is the
        # downstream static-archive shape that failed for validate; it goes red
        # if either installArtifact re-export is dropped.
        checks.lerc-artifact-export = pkgs.stdenv.mkDerivation {
          pname = "tiffz-native-codec-artifact-export";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            ${pkgs.lib.optionalString isLinux ''
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            ''}
            export TERM=dumb
            cd tests/lerc_consumer_pkg
            timeout 600 zig build run -Doptimize=ReleaseSafe ${zigTargetFlag} 2>&1 || {
              echo "native codec artifact export contract failed"
              exit 1
            }
          '';

          installPhase = ''
            mkdir -p $out
            echo "native codec artifact export contract passed" > $out/result
          '';
        };

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "tiffz-test";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          buildInputs = [ jpegPkgs.libjpeg jpegPkgs.openjpeg jpegPkgs.zlib ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            ${pkgs.lib.optionalString isLinux ''
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            ''}
            export TERM=dumb
            # FLEET FLOOR — tests run ReleaseSafe (fleet finding 2026-07-01).
            # ReleaseFast compiles OUT the runtime safety checks (integer
            # overflow, bounds, illegal cast), so a green ReleaseFast suite
            # cannot observe UB: it passes *because* the check that would have
            # failed it is gone. rarz was carrying three real crashers behind a
            # fully green ReleaseFast suite.
            #
            # Enforced HERE, not as a per-module `.optimize` in build.zig: Zig
            # honours per-module optimize, so pinning only the test module
            # would leave imported library code at ReleaseFast. The command
            # line flips the whole test compilation at once.
            #
            # Shipped artifact and benchmarks stay ReleaseFast.
            timeout 600 zig build test -Doptimize=ReleaseSafe ${zigTargetFlag} \
              -Dlibjpeg-include=${jpegPkgs.libjpeg.dev}/include \
              -Dlibjpeg-lib=${jpegPkgs.libjpeg.out}/lib \
              -Dopenjpeg-include=${jpegPkgs.openjpeg.dev}/include/openjpeg-2.5 \
              -Dopenjpeg-lib=${jpegPkgs.openjpeg.out}/lib \
              -Dzlib-include=${jpegPkgs.zlib.dev}/include \
              -Dzlib-lib=${jpegPkgs.zlib.out}/lib \
              2>&1 || {
              echo "Tests failed or timed out after 10 minutes"
              exit 1
            }
          '';

          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
          '';
        };

        # Deterministic mutation fuzzer (Einstein outcome 5). Same ReleaseSafe
        # UB floor as `checks.test`; a panic on any mutated input is a real bug.
        # Hermetic: mutates committed fixtures with a fixed seed, no external
        # tools (the libtiff/ImageMagick oracle diff lives in `./fuzz`, native).
        checks.fuzz = pkgs.stdenv.mkDerivation {
          pname = "tiffz-fuzz";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          buildInputs = [ jpegPkgs.libjpeg jpegPkgs.openjpeg jpegPkgs.zlib ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            ${pkgs.lib.optionalString isLinux ''
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            ''}
            export TERM=dumb
            timeout 600 zig build fuzz -Doptimize=ReleaseSafe ${zigTargetFlag} \
              -Dlibjpeg-include=${jpegPkgs.libjpeg.dev}/include \
              -Dlibjpeg-lib=${jpegPkgs.libjpeg.out}/lib \
              -Dopenjpeg-include=${jpegPkgs.openjpeg.dev}/include/openjpeg-2.5 \
              -Dopenjpeg-lib=${jpegPkgs.openjpeg.out}/lib \
              -Dzlib-include=${jpegPkgs.zlib.dev}/include \
              -Dzlib-lib=${jpegPkgs.zlib.out}/lib \
              2>&1 || {
              echo "Fuzz failed or timed out after 10 minutes"
              exit 1
            }
          '';

          installPhase = ''
            mkdir -p $out
            echo "fuzz passed" > $out/result
          '';
        };
        # devShell — provides Zig + the full TIFF fixture-generation toolchain
        # per SPEC.md Appendix A.
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # Core build (Zig 0.16.0 pinned via zig-overlay)
            zig
            pkgs.git

            # JPEG codec libraries (via jpegz Phase 1 wrapper)
            pkgs.libjpeg     # libjpeg-turbo: baseline / progressive / lossless
            pkgs.openjpeg    # JPEG 2000 (linked by jpegz but unused by tiffz)

            # TIFF fixture / oracle toolchain (SPEC §4 verification oracles + §A fixture recipes)
            pkgs.libtiff       # tiffcp, tiffinfo, tiff2rgba, tiffmedian, raw2tiff, tiffdump
            pkgs.imagemagick   # most flexible TIFF variant generator
            gdalNoCheck        # LERC, ZSTD-in-TIFF, JPEG2000, GeoTIFF, tiled
            pkgs.netpbm        # pnmtotiff / pamtotiff (lighter path for 1-bit)
            pkgs.vips          # alternative TIFF writer for cross-checking
            pkgs.exiftool      # TIFF/EP and DNG metadata inspection / injection

            # Benchmarking (project convention)
            pkgs.hyperfine

            # Dev quality-of-life
            pkgs.ripgrep
            pkgs.fd
            pkgs.jq
            pkgs.file
          ] ++ pkgs.lib.optionals isDarwin [
            pkgs.darwin.cctools
            pkgs.apple-sdk
          ];

          # openjpeg.h is nested under include/openjpeg-2.5/ in nixpkgs;
          # tiffz/build.zig reads OPENJPEG_INC and forwards it via
          # -Dopenjpeg-include to the jpegz dep so Zig's bundled clang
          # finds the header during native dev builds. Nix sandbox
          # buildPhase passes the same path explicitly, so dev + CI
          # stay symmetric.
          OPENJPEG_INC = "${pkgs.openjpeg.dev}/include/openjpeg-2.5";

          shellHook = ''
            echo "tiffz dev shell"
            echo "  zig:       $(zig version 2>/dev/null || echo 'not yet on PATH')"
            echo "  libtiff:   $(tiffinfo -h 2>&1 | head -1 | sed 's/^/  /')"
            echo "  magick:    $(magick --version 2>/dev/null | head -1)"
            echo "  gdal:      $(gdalinfo --version 2>/dev/null)"
          '';
        };
      }
    );
}
