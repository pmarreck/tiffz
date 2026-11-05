# DNG camera profile IFDs: a walk design (accepted, not implemented)

validate ruled on 2026-11-04 (dng-tier3.md, ruling 3) that camera profile
IFDs are walked only through a separate design. That design must:
- keep image-structure rules out of them;
- take ColorPlanes from the main raw IFD;
- define how a bad profile pointer is reported;
- include the corpus and KNOWN_DEFECT comparison.

This note is that design, cited to DNG 1.6.0.0 (sha256
7f6e7867569c1daeae7f6835cd0a6a769e47e36b109594a8b3cc321d2327e569).

## What the text defines

ExtraCameraProfiles (50933, IFD 0, LONG, count = number of extra profiles)
holds "a list of file offsets to extra Camera Profile IFDs". Each camera
profile is laid out as follows:
- it begins with a 16-bit byte order mark (MM or II);
- then a 16-bit "magic" number, 0x4352 ("CR");
- then a 32-bit IFD offset;
- then a standard TIFF IFD.

"All offsets are relative to the start of the byte order mark." The primary
profile lives in IFD 0, and the tag "should only be used if there is more
than one camera profile".

So each profile is a small embedded TIFF. It has its own byte order and its
own magic, and its offsets are relative to the profile's start. It is not
an IFD of the file's own graph.

Thirty tags list "Camera Profile IFD" in their Usage:
- the ColorMatrix, ForwardMatrix and ReductionMatrix 1-3;
- CalibrationIlluminant 1-3 and IlluminantData 1-3;
- ProfileCalibrationSignature, ProfileName, ProfileCopyright and
  ProfileEmbedPolicy;
- the ProfileHueSatMap and ProfileLookTable dimensions, data and encodings;
- ProfileToneCurve, BaselineExposureOffset and DefaultBlackRender.

tiffz already defines every one of them as a DNG row.

## Proposed walk

1. **Reading the profiles.** In a DNG of known version (D2), read IFD 0's
   ExtraCameraProfiles. Each profile is read through a sub-source starting
   at its offset, so its relative offsets resolve as written. The header is
   checked: byte order II or MM, magic 0x4352, and an IFD offset inside the
   file.
2. **The profile IFD.** It is parsed with the existing IFD parser in the
   profile's byte order, under the same limits. Each profile counts toward
   `max_ifds`. Its next-IFD offset is not followed, because the text
   defines one IFD per profile.
3. **Rules applied:** only the DNG rows of the 30 profile tags, plus
   findings 17 (sort order) and 18. Their counts use ColorPlanes from the
   main raw IFD, as ruled.
4. **Rules not applied:**
   - no image-structure rule: no strip, tile or geometry rule, no finding
     19 and no presence check;
   - no TIFF baseline row, because a profile IFD is not an image;
   - no decoding.
5. **Reach.** Profile checks are structural and directory-only, so they run
   in the walk after IFD 0's directory rules and again in the post-stop
   pass (ruling A). No pass runs after a limit, OutOfMemory or Bug.

## Reporting

1. **Records in a profile IFD.** These need an IFD index in the finding 17
   and 18 payloads. The proposal is to number profiles after the walked
   IFDs: walked count + k for profile k, in tag order. A reader cannot tell
   such an index from a walked IFD without counting, so there are two
   options:
   - document the rule only;
   - add a payload-neutral marker, which would need Einstein. Question 2.
2. **A bad profile pointer:** the offset is outside the file, or the header
   is not II/MM plus 0x4352, or the IFD offset is outside the file or its
   entry table is truncated. The proposal is finding 18 reason 3 (value) on
   the ExtraCameraProfiles entry, once per bad profile. The raw slot is the
   entry's slot, as for every finding 18 record, so a reader learns only
   that one of the offsets is bad. Saying which would need a payload
   extension. Question 3.
3. **A tag in a profile IFD whose Usage excludes profiles,** for example
   StripOffsets: the proposal is no record in this batch (unchecked, and
   said so). The presence finding's `excluded_present` with a new
   requirement value would fit later. Question 4.

## Corpus and KNOWN_DEFECT comparison

An independent byte scan over the 21 corpus DNGs (the pinned manifest's
DNGs and the patched DNG controls) found **no** ExtraCameraProfiles tag.
- **Corpus impact:** none.
- **KNOWN_DEFECT impact:** none. No exemplar is a DNG with profiles.
- **Exemplars:** raw.pixls.us rejects converter output, and Adobe DNG
  Converter is the usual writer of multi-profile DNGs. So a clearly
  licensed exemplar is the open dependency. Without one, the walk would be
  tested only on synthetic files.

## Questions for validate

1. Is the walk's scope right: the 30 profile tags' DNG rows plus findings
   17 and 18, and nothing image-related?
2. Should profile IFDs be numbered after the walked IFDs, with or without a
   marker?
3. Is a bad profile pointer finding 18 reason 3 on the ExtraCameraProfiles
   entry, or something else?
4. Should a non-profile tag in a profile IFD stay unchecked for now?
5. Implement now on synthetic files only, or wait for a licensed real
   exemplar?

## Rulings (validate, 2026-11-05)

1. **Scope: yes.** The walk covers the 30 profile tags' DNG rows plus
   findings 17 and 18, with ColorPlanes from the main raw IFD, and nothing
   image-related. HueSatMap data requiring its dims, and LookTable data
   requiring its dims, are cross-tag dependencies. They come later with the
   presence finding, as a new requirement value.
2. **Numbering:** after the walked IFDs, with a marker. The walked count
   depends on reach, so a per-IFD `camera_profile` marker carrying the
   ordinal k goes on each profile IFD's metadata entry. It was batched into
   the pending Einstein request (2026-11-05).
3. **A bad pointer** (offset, byte order, magic, or IFD offset outside the
   file) is finding 18 reason 3 on the ExtraCameraProfiles entry, once per
   bad profile.
   - Which element is bad is not said. That limitation is documented, and
     the payload is extended only if a real file needs it.
   - A valid header whose IFD fails to parse gets the IFD parser's own
     structural error, anchored at the profile's IFD.
   - It never ends the main walk, and later profiles are still checked.
4. **Non-profile tags in a profile IFD stay unchecked** for now, and the
   coverage doc says so. The later form is `excluded_present` with a "DNG
   Usage" requirement value.
5. **Implementation goes on a branch** when nothing higher is pending. It is
   ranked below the presence landing, after_stop, INFO and geokey_invalid.
   - It does not land on synthetic files alone. A misreading of the
     relative-offset rule would fault ordinary Adobe DNG Converter output.
   - Landing needs one real multi-profile DNG as a local control, compared
     by hash, kept local if its license forbids redistribution, and
     agreeing with the oracle.
   - validate has asked the owner whether they can supply one.
