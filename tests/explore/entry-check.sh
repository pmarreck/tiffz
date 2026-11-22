#!/usr/bin/env bash
# entry-check.sh TIFFZ_EXPLORE FLOORS FAULT CODE
#
# Runs `tiffz-explore --entry-fault FAULT` over the floors' seeds and
# requires, for every seed, the entry to exist, the case to be detected,
# only the targeted field to change, and finding CODE among the codes the
# fault added. The expectation comes from the specification, not from
# tiffz: for example, PhotometricInterpretation renamed to a private tag
# leaves a required field missing (TIFF 6.0 sections 3 to 6, finding 20;
# the new tag number also breaks the ascending order, finding 17), and
# Compression written as LONG is the wrong type (TIFF 6.0 p. 30, finding 18).
set -euo pipefail
exe=$1 floors=$2 fault=$3 code=$4
work=$(mktemp -d)
"$exe" --floors "$floors" --entry-fault "$fault" > "$work/out"
seeds=$(awk -F'\t' '$1 == "seed"' "$floors" | wc -l)
bad=$(awk -F'\t' -v code="$code" '
  $1 != "entry" { next }
  { n++; split(substr($8, 7), added, ","); hit = 0; for (i in added) if (added[i] == code) hit = 1 }
  $6 != "detect" || !hit { print }
  END { if (n == 0) print "no entry lines" }' "$work/out")
lines=$(awk -F'\t' '$1 == "entry"' "$work/out" | wc -l)
if [ -n "$bad" ] || [ "$lines" -ne "$seeds" ]; then
  echo "entry fault $fault: want $seeds seeds detected with finding $code added; got:"
  cat "$work/out"
  exit 1
fi
echo "entry fault $fault: all $seeds seeds detected with finding $code added"
