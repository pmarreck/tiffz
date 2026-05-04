{
  description = "tiffz - cleanroom spec-complete TIFF reader (and eventually writer) in pure Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Pin Zig explicitly. nixpkgs-unstable ships 0.16.0 already (April 2026),
    # but Peter's project portfolio targets 0.15.x — the documented
    # adoption strategy is "wait for 0.16.1". zig-overlay exposes every
    # release as a named attribute. Update the version below when the
    # whole portfolio moves.
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
        zig = zig-overlay.packages.${system}."0.15.2";

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
        # Build the tiffz static lib + C CLI in a sandboxed Nix
        # derivation. tiffz has no dependencies yet, so we don't need
        # the fixed-output `zigDeps` machinery — `--system` cache is
        # empty and zig build runs offline.
        tiffzPkg = pkgs.stdenv.mkDerivation {
          pname = "tiffz";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            zig build --prefix $out -Doptimize=ReleaseFast
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

          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            ${pkgs.lib.optionalString isDarwin ''
              export C_INCLUDE_PATH="${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            ''}
            export TERM=dumb
            timeout 600 zig build test 2>&1 || {
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
            # Core build (Zig 0.15.2 pinned via zig-overlay)
            zig
            pkgs.git

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
