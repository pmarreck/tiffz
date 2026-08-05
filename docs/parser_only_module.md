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
the parser module their single Zig owner. Both modules must come from the same
`b.dependency("tiffz", ...)` instance in any one Zig compilation.

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
`dep.module("tiffz")`. For in-process Zig integration, Validate should create
the rawz source module itself and inject the parser from its existing tiffz
dependency. Accepting rawz's preconfigured named module would create a second
tiffz dependency instance and can trigger Zig's duplicate-file ownership gate:

```zig
const tiffz_dep = b.dependency("tiffz", tiffz_options);
const rawz_dep = b.dependency("rawz", rawz_options);
const rawz_module = b.createModule(.{
    .root_source_file = rawz_dep.path("src/lib.zig"),
    .target = target,
    .optimize = optimize,
});
rawz_module.addImport("tiffz", tiffz_dep.module("tiffz-parser"));
```

Linking rawz's separately built C FFI is the other isolation-safe option.

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
also compiles the full module plus a rawz-like parser proxy injected from the
same dependency instance, and asserts that every shared public parser type has
one identity.
