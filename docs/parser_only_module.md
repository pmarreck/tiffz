# Codec-free parser module

`dep.module("tiffz-parser")` is the TIFF container-parsing boundary for rawz
and other format classifiers. It parses headers and lazily walks IFD chains. It
does not decode pixel, strip, tile, or compressed payload data.

## Public surface

The module exports:

- `Error`, `Limits`, and `Source`
- `errors`, `limits`, `source`, `header`, `ifd`, and `tags`
- `Decoder.open`, `Decoder.openWithLimits`, `Decoder.deinit`,
  `Decoder.ifdCount`, and lazy `Decoder.ifd`
- the parser state rawz currently consumes: `endian`, `bigtiff`, `limits`,
  `source`, `ifds`, and `ifd_offsets`

The full `dep.module("tiffz")` module and its decode API remain unchanged.
The full module imports `tiffz-parser` and re-exports its parser types, making
the parser module their single Zig owner. Validate can therefore import the
full module and a rawz dependency backed by `tiffz-parser` in one compilation.

## Consumer wiring

Existing source can keep `const tiffz = @import("tiffz");` by mapping that
local import name to the parser module:

```zig
const tiffz_dep = b.dependency("tiffz", .{
    .target = target,
    .optimize = optimize,
});
consumer_module.addImport("tiffz", tiffz_dep.module("tiffz-parser"));
```

Validate's full TIFF validator, JPEG adapter, and LZW adapter still require
`dep.module("tiffz")`. A rawz classifier embedded by Validate should receive
the parser module through rawz's build graph rather than adding a second full
tiffz module instance.

The dependency direction remains:

```text
Validate -> rawz -> tiffz-parser
Validate -> tiffz -> jpegz and the full TIFF codec graph
```

Neither tiffz module imports rawz.

## Blocking closure proof

`tests/parser_closure_test` recursively follows every `@import` reachable from
`src/parser.zig`. It permits exactly eight local parser files and rejects any
package import. The Nix `checks.<system>.parser-closure` target then:

1. builds a real downstream consumer without codec `buildInputs`;
2. inspects the exact Zig compiler invocation and rejects include, library,
   object archive, or shared-library edges;
3. runs the consumer against a parsed TIFF;
4. rejects ELF `NEEDED`, `RPATH`, or `RUNPATH` entries.
5. strips the installed consumer and gives Nix `allowedReferences = []`, so
   any codec or other store-path closure edge rejects the derivation.

The consumer tests separately sweep successful multi-IFD traversal, cycle
rejection, IFD-limit rejection, BigTIFF/IFD8 declarations, and every allocator
failure point reached by the bounded fixtures. `./test` runs both the full
tiffz suite and the parser-closure Nix target. `tests/dual_module_test.zig`
also compiles the full and parser modules together and asserts that every
shared public parser type has one identity.
