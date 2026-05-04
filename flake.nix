{
  description = "tiffz - cleanroom spec-complete TIFF reader (and eventually writer) in pure Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        isDarwin = pkgs.stdenv.isDarwin;
        isLinux = pkgs.stdenv.isLinux;

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
      in {
        # devShell — provides Zig + the full TIFF fixture-generation toolchain
        # per SPEC.md Appendix A. Garnix-relevant packages/checks will be
        # added once build.zig exists (task #5 — Skeleton).
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # Core build
            pkgs.zig
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
