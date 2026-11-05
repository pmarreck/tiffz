# Directory rules after a stopping error: design (proposed, not implemented)

validate asked for this on 2026-11-04 as a design, not an implementation.
A single decode error stops the walk, which hides every later IFD's
directory rules. The proof: a copy of the iPhone 12 Pro ProRAW DNG, with
its semantic mask's PhotometricInterpretation patched to 1, reports
nothing, because the walk stops at the raw SubIFD before it reaches the
mask.

## How the walk works today

1. `validatePages` first materializes the whole IFD graph (next chain and
   SubIFDs). Any error other than the end of the graph fails right there.
2. It then walks the IFDs in order. For each one it checks the directory
   rules (`ifd_conformance.check`, findings 17 and 18), then decodes the
   chunks.
3. A never-supported Compression code is not a stop. Finding 16 names the
   skipped IFD and the walk continues.
4. Any decode error on a supported code returns at once. Examples are
   UnsupportedCompression for an unsupported variant, error 25
   JpegInTiffPayload, and codec failures. Later IFDs keep their parsed
   entries in memory, but their directory rules never run.

## Is it safe to continue?

The directory rules are pure: they read only the parsed `Ifd` and its
cached values. They depend on no pixel data and no decoder state. Per kind
of stop:

| Stop | Later IFDs | Check them? |
|---|---|---|
| Decode error in IFD k (codec, payload, unsupported variant, short source) | parsed | yes, IFDs k+1 to the end |
| Error while materializing the graph | parsed up to the failure | yes, the IFDs parsed before the failure |
| Limit (`errors.isLimit`), OutOfMemory, Bug | — | no: the budget or state is spent or suspect |

Only the directory rules run after a stop. Records that need decoding
(finding 19 segment geometry, codec findings) are not produced for IFDs the
walk did not reach.

## How later records sit alongside the stopping error

- The stopping error is unchanged. It is still returned and still reported
  first.
- The extra records come after it, in IFD order, with today's codes and
  payloads. Each payload already carries its IFD index.
- Verdict: under the 2026-11-03 ruling, a proven directory violation is
  corrupt. So a file that stops with an indeterminate error, and has a
  finding 18 in an unreached IFD, would aggregate to corrupt. That is
  validate's aggregation to confirm.

## KNOWN_DEFECT stability: measured

I built a throwaway prototype in a separate worktree. It is not landed.
After a stopping error, it checks the directory rules of every parsed IFD
the walk did not reach. I ran it against f8ca6ee1 over the 249-file pinned
corpus and the 10 KNOWN_DEFECT fixtures:

- **One file gains records**: Samsung NX500 SRW (sha256
  156e43118811bcecb6fcc600b5f41ee1773c4f00b6a5b2dd72e177e35f6596ab).
  - It gains a finding 18 on IFD 3, a BitsPerSample count fault.
  - The file is already invalid (error 2), and its status does not change.
- **No CR2, ARW or Kodak file changes, and no KNOWN_DEFECT fixture
  changes.** The Sony and Canon signatures, which say "no other failure
  record", see exactly today's records.
- **The patched iPhone copy now reports its mask IFD**: IFD 2,
  PhotometricInterpretation 1 (the mask role allows 52527 only), and
  Compression 34892 (lossy JPEG needs LinearRaw or PhotometricMask).

## Options

- **A. Plain records.** Emit the extra records like any others. Today no
  signature changes, as measured above. A future signature for a file that
  stops early would have to account for them.
- **B. Plain records plus a metadata flag.** As A, but set a new
  `MetadataFlags` bit, for example `after_stop` (1 << 4), on records from
  IFDs the walk did not reach. The registry can then scope "no other
  failure record" to the reached walk, or to everything. Payloads are
  unchanged.
  - This adds to the findings ABI, so it needs owner and Einstein sign-off.
- **C. Run every IFD's rules before any decoding.** This reorders every
  file's records, not only the files that stop. Not recommended.

**Recommendation: B.** It is additive and leaves every payload alone, and
the matcher can say precisely what it means. A is acceptable if you would
rather not allocate a flag; nothing changes today either way.

## Test plan, once a form is chosen

- A fixture DNG whose IFD 0 stops on an unsupported variant and whose
  SubIFD has a directory fault: the fault is reported after the stopping
  error, and the stopping error is unchanged.
- The same with a graph error after the second IFD: the first two IFDs are
  checked, nothing beyond.
- A limit stop: no extra records.
- Every KNOWN_DEFECT fixture's record set stays byte-identical, pinned by
  the existing fixture test.
- A corpus differential: the only change is the NX500 record above.
- Controlled reds: dropping the post-stop pass, and extending it past a
  limit stop.

## Questions for validate

1. Option A or B, and with B, the bit and its name?
2. Should post-stop records drive the verdict (corrupt), or be reported
   without changing it?
3. Do you want the graph-error case, or only per-IFD decode stops?
