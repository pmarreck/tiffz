#!/usr/bin/env bash
# audit_corpus.sh — generate audit/coverage_matrix.tsv from a TIFF corpus.
#
# Per SPEC.md §2: walk a set of input directories, run tiffinfo on each
# *.tif*/*.dng/*.btf and emit a TSV row capturing the variant axes that
# tiffz needs to handle differently from zigimg.
#
# Usage:
#   tools/audit_corpus.sh path1/ path2/ file1.tif ... > audit/coverage_matrix.tsv
#   tools/audit_corpus.sh --default > audit/coverage_matrix.tsv
#
# Requirements: tiffinfo (libtiff), exiftool. Both provided by the
# project flake.nix devShell.

set -u  # nounset; never set -e (per CLAUDE.md test-script discipline,
        # we want to surface tool failures explicitly rather than silently bail)

# Default corpus locations (per SPEC §2 + §11).
DEFAULT_PATHS=(
    "$HOME/Documents-CloudManaged/validate/ground_truth_examples/tiff"
    "$HOME/Documents-CloudManaged/validate/ground_truth_examples/dng"
    "/Volumes/Fileserver/Pictures/scan from pete's book.tif"
)

# Resolve PATHS from CLI args or fall back to defaults.
if [[ $# -eq 0 || "${1:-}" == "--default" ]]; then
    PATHS=("${DEFAULT_PATHS[@]}")
else
    PATHS=("$@")
fi

# Tab-separated header.
printf 'path\tsize_bytes\tendian\tbigtiff\twidth\theight\tsamples\tbits_per_sample\tphotometric\tcompression\tpredictor\tplanar\tlayout\trows_per_strip\ttile_w\ttile_h\tifd_count\thas_icc\thas_exif\thas_geo\tnotes\n'

# Emit one TSV row for one TIFF file.
emit_row() {
    local path="$1"
    local size_bytes endian bigtiff width height samples bps photo comp pred planar layout rps tw th ifd_n has_icc has_exif has_geo notes

    if [[ ! -r "$path" ]]; then
        printf '%s\tUNREADABLE\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n' "$path"
        return
    fi

    size_bytes=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo "?")

    # tiffinfo returns ALL IFDs; we'll capture the count and then pull
    # variant axes from IFD 0 (the most-relevant for matrix purposes).
    local info
    info="$(tiffinfo "$path" 2>&1 || true)"

    if grep -qi "Cannot read TIFF header" <<<"$info"; then
        printf '%s\t%s\tINVALID\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n' "$path" "$size_bytes"
        return
    fi

    # Endianness — tiffinfo line "TIFF Directory at offset 0x..." doesn't say.
    # Use file magic bytes via dd.
    local magic
    magic="$(dd if="$path" bs=1 count=4 2>/dev/null | xxd -p 2>/dev/null || echo "")"
    case "$magic" in
        49492a00) endian=little; bigtiff=no  ;;
        4d4d002a) endian=big;    bigtiff=no  ;;
        49492b00) endian=little; bigtiff=yes ;;
        4d4d002b) endian=big;    bigtiff=yes ;;
        *)        endian=?;      bigtiff=?   ;;
    esac

    # Pull from IFD 0 (the first "TIFF Directory" block in tiffinfo output).
    # Subsequent IFDs come after additional "TIFF Directory at offset" lines.
    local ifd0
    ifd0="$(awk '
        /^TIFF Directory at offset/ { n++; if (n>1) exit }
        n==1 { print }
    ' <<<"$info")"

    # tiffinfo emits dimensions on a single line:
    #   "  Image Width: 512 Image Length: 384 Image Depth: 1"
    #   "  Tile Width: 128 Tile Length: 128 Tile Depth: 1"
    # Extract by positional field after the colons.
    width=$(awk '/Image Width:/  { print $3; exit }' <<<"$ifd0")
    height=$(awk '/Image Width:/ { print $6; exit }' <<<"$ifd0")
    tw=$(awk '/Tile Width:/      { print $3; exit }' <<<"$ifd0")
    th=$(awk '/Tile Width:/      { print $6; exit }' <<<"$ifd0")

    samples=$(awk -F': ' '/Samples\/Pixel:/ { print $2; exit }' <<<"$ifd0")
    bps=$(awk -F': ' '/Bits\/Sample:/ { print $2; exit }' <<<"$ifd0")
    photo=$(awk -F': ' '/Photometric Interpretation:/ { print $2; exit }' <<<"$ifd0")
    comp=$(awk -F': ' '/Compression Scheme:/ { print $2; exit }' <<<"$ifd0")
    pred=$(awk -F': ' '/Predictor:/ { print $2; exit }' <<<"$ifd0")
    planar=$(awk -F': ' '/Planar Configuration:/ { print $2; exit }' <<<"$ifd0")
    rps=$(awk -F': ' '/Rows\/Strip:/ { print $2; exit }' <<<"$ifd0")

    if [[ -n "$tw" ]]; then layout=tiled; else layout=stripped; fi

    ifd_n=$(grep -c '^TIFF Directory at offset' <<<"$info")

    has_icc="no"; grep -qi 'ICC Profile:' <<<"$info" && has_icc="yes"
    has_exif="no"; grep -qi 'EXIF' <<<"$info" && has_exif="yes"
    has_geo="no"; grep -qi 'GeoTIFF' <<<"$info" && has_geo="yes"

    notes=""
    grep -qi 'DNGVersion' <<<"$info" && notes="$notes,dng"
    grep -qi 'CFAPattern' <<<"$info" && notes="$notes,cfa"
    notes="${notes#,}"

    # Tabs as separators; trim accidentally-multi-line fields.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$size_bytes" "$endian" "$bigtiff" \
        "${width:--}" "${height:--}" "${samples:--}" "${bps:--}" \
        "${photo:--}" "${comp:--}" "${pred:--}" "${planar:--}" \
        "$layout" "${rps:--}" "${tw:--}" "${th:--}" \
        "$ifd_n" "$has_icc" "$has_exif" "$has_geo" "${notes:--}"
}

for entry in "${PATHS[@]}"; do
    if [[ -f "$entry" ]]; then
        emit_row "$entry"
    elif [[ -d "$entry" ]]; then
        # Walk directories; pick up *.tif, *.tiff, *.TIF, *.TIFF, *.dng, *.DNG, *.btf, *.tf8.
        while IFS= read -r -d '' f; do
            emit_row "$f"
        done < <(find "$entry" -type f \( \
            -iname '*.tif' -o -iname '*.tiff' -o \
            -iname '*.dng' -o -iname '*.btf' -o -iname '*.tf8' \
        \) -print0 2>/dev/null)
    else
        printf '%s\tNOT_FOUND\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n' "$entry" >&2
    fi
done
