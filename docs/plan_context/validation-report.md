# Validation report

tiffz is a validator. Callers discard the decoded samples. Parsing and
decoding exist to find discrepancies.

A discrepancy is one record:

- `warning` for a named tolerance that does not fail the walk (findings
  13, 14, and 15). The finding code stays. The record carries the chunk
  or IFD offset when that offset was actually read.
- `error` for a file claim: `Malformed`, `EndOfFacsimileBlock`,
  `IfdChainCycle`, a supported codec's own error, and the other
  non-limit statuses. The type is the error name. The offset is the
  strip, tile, or IFD the walk was checking. The first error wins. An
  error replaces a warning.
- `known_failure` is reserved for a pattern the consumer has admitted.
  tiffz does not keep that registry and does not emit this class.

A resource cap is not a discrepancy. Statuses 11–19, 27, and 28 stay
reach, with `tiffz_limit_progress`. Finding 16 stays structural reach
and is not a discrepancy.

`tiffz_discrepancy` returns the class, the offset when known, and the
static type name. JSON field `discrepancy` uses the same facts. An
unknown offset is omitted. Zero is not invented.

Early CCITT T.6 EOFB is an error of type `EndOfFacsimileBlock` at the
strip offset, with `rows_decoded` as the completed-row count. The
zero-filled tail is not the validation result.
