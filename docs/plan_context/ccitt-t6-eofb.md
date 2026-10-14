# CCITT T.6 early EOFB

`compressions/ccitt_t6.decode` returns `error.Malformed` both when EOFB arrives before the requested row count and when a mode or run does not decode. The EOFB path is the synthetic error after the second EOL.

In PDF, EOFB before the declared row count is conforming at the filter level when EndOfBlock defaults to true (ISO 32000-1 Table 11). Those two outcomes have to be distinct so a row shortfall is not the same status as an undecodable code.

The outcome is appended. It is not inserted into the existing error set. EOFB followed only by zero fill to the end of the data is that outcome and reports how many rows were decoded. Any other byte after EOFB stays `Malformed`.

Acceptance pair: two white rows plus EOFB, decoded with `rows=4`, returns the new outcome after 2 rows. Eight zero bytes stay `Malformed`.

Validate's JPEG provider hold blocks adoption of a newer build. Announce the appended code before a repin.
