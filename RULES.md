# tiffz — rules

Standing invariants. Do not violate these without an excellent reason
or an explicit decision from Peter.

## Internationalization

- **Status:** deferred
- **Decision owner:** Peter
- **Date:** 2026-09-16 EDT
- **Scope:** C CLI user-facing strings (`cli/main.c`, `--help`, errors)
- **Rationale:** the validate/dump verb surface is still moving. Full
  50-locale prepare/enforce infrastructure would thrash with every
  help-text change. Reopen when the CLI verbs and flags are stable
  enough to extract a key registry (i18n prepare phase). Until then
  the CLI is English-only. `--lang` is not accepted yet.

## C FFI dogfooding

The in-tree C CLI must call tiffz only through `include/tiffz.h`. It
must not `@import` Zig modules.

## Findings

Namespace B codes are append-only. New codes need Einstein sign-off.
Identity is `(source_decoder, finding_code)`. Nested JPEG-family
findings stay tagged with their source. See `INTENT.md` and
`TERMINOLOGY.md`.
