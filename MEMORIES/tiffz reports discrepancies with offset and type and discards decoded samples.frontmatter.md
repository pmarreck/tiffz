---
description: "tiffz validates files and discards decoded samples. Each discrepancy is a warning, an error, or a known failure, with a byte offset and a type. tiffz does not admit known failures."
datetime: 2026-10-15T23:20:24-04:00 # EDT
tags: [tiffz, validation, discrepancy, warning, error, known-failure, byte-offset, error-type, reach]
---

Callers use tiffz to find data discrepancies. The decoded sample buffer is
not the result and is normally discarded.

A discrepancy record has three parts: a class, a file offset, and a type
name.

- `warning` is a named tolerance that does not fail the walk. Findings 13,
  14, and 15 are this class. The offset is the chunk or IFD that was read.
- `error` is a file claim. The type is the error name, including
  `Malformed`, `EndOfFacsimileBlock`, and `IfdChainCycle`. The offset is
  the strip, tile, or IFD under check. The first error wins and replaces
  a warning.
- `known_failure` is an admitted pattern. Admission lives in the consumer
  registry. tiffz does not emit this class.

A resource cap is a claim about the tool, not a discrepancy. Statuses
11-19, 27, and 28 stay reach. Finding 16 stays structural reach. An
unknown offset is omitted. A zero offset is reported only when that byte
was the real site.
