# CCITT T.6 early EOFB

`compressions/ccitt_t6.decode` returns `error.EndOfFacsimileBlock` (status 26) when EOFB arrives before the requested row count and the bytes after it are only zero fill. A mode or run that does not decode, eight zero bytes, or a 1 bit after EOFB stays `error.Malformed`. `rows_written` is how many rows were fully decoded. `tiffz_facsimile_rows` returns that count, and the CLI JSON names it `rows_decoded`. Status 26 is not a resource limit.

In PDF, EOFB before the declared row count is conforming at the filter level when EndOfBlock defaults to true (ISO 32000-1 Table 11). Those two outcomes have to be distinct so a row shortfall is not the same status as an undecodable code.

The outcome is appended. It is not inserted into the existing error set. EOFB followed only by zero fill to the end of the data is that outcome and reports how many rows were decoded. Any other byte after EOFB stays `Malformed`.

Acceptance pair: two white rows plus EOFB, decoded with `rows=4`, returns the new outcome after 2 rows. Eight zero bytes stay `Malformed`.

Status 26 is appended after `JpegInTiffPayload`. Announce it before a consumer repins.
