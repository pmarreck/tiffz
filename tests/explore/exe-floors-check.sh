#!/usr/bin/env bash
# exe-floors-check.sh TIFFZ_EXPLORE FLOORS SEED_INDEX...
#
# Independent control for the tiffz-explore executable. Batch k of each
# floors plan draws `per` cases from seed k mod SEEDS at rounds k*per onward.
# A floors file listing only seed k makes every tiffz-explore round use seed
# k, so rounds k*per .. k*per+per-1 are exactly batch k. The cases the
# executable detects there must equal the pinned detected cases, which the
# subprocess harness wrote (corruption-reader CLI and `tiffz validate`).
# Prints one line per profile and seed; exits 1 on any difference.
set -euo pipefail
exe=$1 floors=$2
shift 2
work=$(mktemp -d)
master=$(awk -F'\t' '$1 == "master" { print $2 }' "$floors")
nseeds=$(awk -F'\t' '$1 == "seed"' "$floors" | wc -l)
status=0
for k in "$@"; do
  seed=$(awk -F'\t' -v k="$k" '$1 == "seed" && n++ == k { print $2 }' "$floors")
  [ -n "$seed" ] || { echo "no seed $k" >&2; exit 2; }
  one="$work/floors-$k"
  awk -F'\t' -v s="$seed" '$1 == "master" || $1 == "plan" || ($1 == "seed" && $2 == s)' "$floors" > "$one"
  while IFS=$'\t' read -r _ profile per_field batches_field; do
    per=${per_field#per=}
    batches=${batches_field#batches=}
    # Only batches that draw seed k are comparable.
    [ "$k" -lt "$batches" ] || continue
    [ $((k % nseeds)) -eq "$k" ] || continue
    first=$((k * per))
    "$exe" --floors "$one" --master "$master" --profile "$profile" --first-round "$first" --rounds "$per" |
      awk -F'\t' '$1 == "case" && $5 == "detect" { print $2 "\t" $3 "\t" $4 }' | sort > "$work/got"
    awk -F'\t' -v p="$profile" -v s="$seed" -v lo="$first" -v hi=$((first + per)) \
      '$1 == "detect" && $2 == p && $3 == s && $4 >= lo && $4 < hi { print $2 "\t" $3 "\t" $4 }' "$floors" | sort > "$work/want"
    if cmp -s "$work/got" "$work/want"; then
      echo "match $profile seed $k ($seed): $(wc -l < "$work/want") of $per detected"
    else
      echo "MISMATCH $profile seed $k ($seed):"
      diff "$work/want" "$work/got" || true
      status=1
    fi
  done < <(awk -F'\t' '$1 == "plan"' "$floors")
done
exit $status
