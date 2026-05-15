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

        # On Linux, we use a musl target explicitly. Two reasons:
        # (1) zig-overlay ships vanilla Zig (no Nix-sandbox patches),
        #     so its host-ABI detection fails inside Garnix's
        #     sandbox: "warning: Encountered error: FileNotFound,
        #     falling back to default ABI and dynamic linker." That
        #     fallback is broken — spawned subprocesses can't find
        #     their dynamic linker.
        # (2) musl produces fully static binaries, which is the
        #     project portfolio's Linux convention (CLAUDE.md
        #     "Better static linking support").
        # macOS handles its own dynamic linker via apple-sdk and
        # doesn't have this issue.
        zigTarget =
          if system == "x86_64-linux"  then "x86_64-linux-musl"
          else if system == "aarch64-linux" then "aarch64-linux-musl"
          else null;
        zigTargetFlag = if zigTarget == null then "" else "-Dtarget=${zigTarget}";

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
        zigDepsHash = "sha256-lRaYRf4bq/wzUfY7Z6JXx13QTBu0ACVFJ8jZIxCx1E8=";

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "tiffz-zig-deps";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = with pkgs; [ zig git cacert ];

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;

          # Zig 0.16 changed the fetched-package cache location: deps
          # land in `./zig-pkg/` (project-local) instead of
          # `$ZIG_GLOBAL_CACHE_DIR/p/`. Capture the local zig-pkg into
          # $out so the consumer can stage it back into its own source
          # tree before running zig build.
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
            mkdir -p $out
            cp -r zig-pkg $out/zig-pkg
          '';

          dontInstall = true;
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
          # JPEG-LS.
          buildInputs = [ pkgs.libjpeg pkgs.openjpeg ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            # Stage pre-fetched packages into Zig 0.16's project-local
            # `./zig-pkg/` (see zigDeps comment for the layout change).
            cp -r ${zigDeps}/zig-pkg ./zig-pkg
            chmod -R u+w ./zig-pkg
            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            ${pkgs.lib.optionalString isLinux ''
              # Linux build target is x86_64-linux-musl (cross from
              # glibc-built nix builder → musl-targeted Zig binary).
              # Nix's cc-wrapper sets NIX_CFLAGS_COMPILE / NIX_LDFLAGS
              # to glibc-relative system paths; those leak into Zig's
              # C compiler invocation for vendored C deps (zlib here)
              # and end up shadowing the in-tree zconf.h with a glibc
              # one that doesn't exist. Unset before invoking zig to
              # restore a clean cross-toolchain environment.
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            ''}
            zig build --prefix $out -Doptimize=ReleaseFast ${zigTargetFlag} \
              -Dlibjpeg-include=${pkgs.libjpeg.dev}/include \
              -Dlibjpeg-lib=${pkgs.libjpeg.out}/lib \
              -Dopenjpeg-include=${pkgs.openjpeg.dev}/include/openjpeg-2.5 \
              -Dopenjpeg-lib=${pkgs.openjpeg.out}/lib
          '';

          dontInstall = true;
          dontFixup = true;
        };

      in {
        packages.default = tiffzPkg;

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "tiffz-test";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          buildInputs = [ pkgs.libjpeg pkgs.openjpeg ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/zig-pkg ./zig-pkg
            chmod -R u+w ./zig-pkg
            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            ${pkgs.lib.optionalString isLinux ''
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            ''}
            export TERM=dumb
            timeout 600 zig build test ${zigTargetFlag} \
              -Dlibjpeg-include=${pkgs.libjpeg.dev}/include \
              -Dlibjpeg-lib=${pkgs.libjpeg.out}/lib \
              -Dopenjpeg-include=${pkgs.openjpeg.dev}/include/openjpeg-2.5 \
              -Dopenjpeg-lib=${pkgs.openjpeg.out}/lib \
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
