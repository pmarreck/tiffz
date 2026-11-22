#!/usr/bin/env bash
# replay-check.sh TIFFZ_EXPLORE LAYOUTS REPORT FLOORS
#
# Independent control for tiffz-explore's in-process outcomes and free-case
# bound. LAYOUTS and REPORT come from the checks.corruption-coverage run on
# the same floors plan: the subprocess harness (corruption-reader CLI, temp
# files, `tiffz validate`) mapped each seed with libtiff's tiffdump and
# counted, per profile and seed class, the decisive cases, detections, free
# cases and false alarms. `tiffz-explore --replay-floors` replays that plan
# in-process with the same layouts, and its counts must be equal.
set -euo pipefail
exe=$1 layouts=$2 report=$3 floors=$4
work=$(mktemp -d)
pick='$1 == "class" {
  line = $1 " " $2 " " $3
  for (i = 4; i <= NF; i++) if ($i ~ /^(decisive|detect|free|false_alarm)=/) line = line " " $i
  if (line !~ / decisive=0( |$)/) print line
}'
status=0
"$exe" --replay-floors --floors "$floors" --layouts "$layouts" > "$work/replay" || status=$?
awk "$pick" "$work/replay" | sort > "$work/got"
awk "$pick" "$report" | sort > "$work/want"
if [ "$status" -ne 0 ]; then
  echo "tiffz-explore --replay-floors exited $status"
  grep -v '^case' "$work/replay" || true
  exit 1
fi
if [ ! -s "$work/want" ]; then
  echo "no class lines in $report"
  exit 1
fi
if cmp -s "$work/got" "$work/want"; then
  echo "replay matches the harness on $(wc -l < "$work/want") profile and class counts:"
  cat "$work/got"
else
  echo "replay differs from the harness (want, then got):"
  diff "$work/want" "$work/got" || true
  exit 1
fi
