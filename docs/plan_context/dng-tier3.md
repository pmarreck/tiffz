# DNG Tier 3: counts sized by ColorPlanes, across IFDs (proposed, not implemented)

validate approved Tiers 1 and 2 of the DNG batch and left Tier 3 for a
later batch (2026-11-04; dng-batch.md). This note is that batch's design,
sent for review before any implementation. It cites DNG 1.6.0.0 (sha256
7f6e7867569c1daeae7f6835cd0a6a769e47e36b109594a8b3cc321d2327e569).

## The problem

Seventeen tags have counts in terms of ColorPlanes, the number of color
planes of the raw image. Most of them live in IFD 0 (or a camera profile
IFD), while ColorPlanes comes from the raw IFD. In most DNGs the raw IFD is
a SubIFD. So these counts need a value from another IFD.

| Count | Tags (Usage) |
|---|---|
| ColorPlanes | CFAPlaneColor (Raw IFD); AnalogBalance, AsShotNeutral (IFD 0) |
| ColorPlanes * 3 | ColorMatrix1-3 (IFD 0 or camera profile) |
| 3 * ColorPlanes | ReductionMatrix1-3, ForwardMatrix1-3 (IFD 0 or camera profile) |
| ColorPlanes * ColorPlanes | CameraCalibration1-3 (IFD 0) |
| 3 * ColorPlanes or ColorPlanes * ColorPlanes | AsShotPreProfileMatrix, CurrentPreProfileMatrix (IFD 0) |
| 2 or 2 * ColorPlanes | NoiseProfile (Raw IFD or Enhanced IFD) |

ReductionMatrix1-3 also "may only be used if ColorPlanes is greater than 3"
(Tier 2's held-back must, deferred here).

## Deriving ColorPlanes

- **The raw IFD** is the IFD whose NewSubFileType is 0 (the default when
  the tag is absent), anywhere in the walk (next chain and SubIFDs).
- **ColorPlanes**, by the raw IFD's PhotometricInterpretation:
  - CFA (32803): CFAPlaneColor's count, or 3 when CFAPlaneColor is absent
    (its default is "0, 1, 2 (red, green blue)").
  - LinearRaw (34892): SamplesPerPixel (default 1).
- **No value** (every Tier 3 count unconstrained, nothing recorded) when:
  - there is no raw IFD;
  - there is more than one, and they disagree;
  - the raw IFD's photometric is anything else;
  - a field it needs is malformed (its own fault).
- **Timing:** the decoder materializes the whole IFD graph before the walk,
  so ColorPlanes is computed once, alongside the DNGVersion context, and
  passed to every IFD's check. It needs no decoding, so it is also there
  for the post-stop pass (0b07e271).

## Reporting

- Each mismatch is a count fault (finding 18 reason 2) on the dependent
  entry, the same form as Tier 2's derived counts. The payload is
  unchanged.
- Payload question: should the record carry the ColorPlanes it was
  checked against, or the raw IFD's index? Today a reader has to redo the
  derivation. Adding either changes finding 18's payload, so it needs
  sign-off. The proposal is no change: the derivation is fixed by this
  note and reproducible from the file.
- ReductionMatrix with ColorPlanes of 3 or fewer: proposed as a value fault
  (reason 3) on the ReductionMatrix entry ("may only be used if ColorPlanes
  is greater than 3").
- CFAPlaneColor's own count is ColorPlanes by definition, so it is
  tautological for a CFA raw IFD and gets no new check.
- Gating as in Tiers 1 and 2:
  - each row from its tag's edition;
  - counts are count rules, so they apply even with an unknown version
    (D2);
  - the ReductionMatrix condition is a value rule, so it is skipped for an
    unknown version.

## Camera profile IFDs

ExtraCameraProfiles (50933) points at camera profile IFDs, which carry
ColorMatrix, ForwardMatrix, ReductionMatrix and the profile tables. tiffz
does not walk them today: they are not SubIFDs. So their tags get no rule
of any kind, not only none from Tier 3. Walking them would be a separate
change to the IFD graph (question 3).

## Corpus prediction (17 DNGs in the 249-file pinned corpus)

An independent byte scan derived ColorPlanes for every corpus DNG and
checked the Tier 3 counts:
- **ColorPlanes:** 3 in all 17, whether from CFAPlaneColor's count or its
  default.
- **Raw IFD location:** IFD 0 in seven files (Leica M11, Blackmagic,
  Motorola Nexus 6, Sigma fp, and the three Samsung files declaring 1.6),
  a SubIFD in the other ten.
- **Counts:** every ColorMatrix, CameraCalibration, ReductionMatrix,
  AnalogBalance, AsShotNeutral, ForwardMatrix, PreProfileMatrix and
  NoiseProfile count present fits. Expected corpus impact: none.

## Questions for validate

1. Is the ColorPlanes derivation right, including the CFAPlaneColor
   default of 3 and "disagreeing raw IFDs leave it unconstrained"?
2. Should the payload stay as it is, or carry the ColorPlanes used?
3. Should camera profile IFDs (ExtraCameraProfiles) be walked, so that
   Tiers 1 to 3 reach them? That changes the IFD graph, so it is a decision
   of its own.
4. Is the ReductionMatrix "only if ColorPlanes > 3" condition a value fault
   on the ReductionMatrix entry?
