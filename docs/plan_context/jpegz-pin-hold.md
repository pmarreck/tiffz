# jpegz pin hold

tiffz stays on jpegz `3f6066c9bd24089f8208ab40ce44874caae56fe8` and libjxlz `93b29e86281ea4ba9c681f4879318c87e8a800a4`.

jpegz yolo `f56de741f180347d53cc1f1a549dcc4bfe6fcc58` contains the Canon SOF3 work `6ef766c8d35d9e4b3aebf533a0854632df9bda96` and does not contain validate's DHT stack-overflow fix. Those reports are still in the jpegz inbox (2026-09-26 and 2026-09-28). tiffz replied on 2026-09-28 that it will repin the first revision that contains both, through the single `tiffz.jpegz` instance.

Checked again 2026-09-29 19:39 EDT. `origin/yolo` was still `f56de74`. The jpegz worktree had uncommitted red tests in `src/decode/huffman.zig` and `tests/unit/facade_validation.zig`. `buildFromDht` still assigned `t.codes[idx] = @intCast(code)` and shifted with no range check, and those tests aborted in ReleaseSafe. The jpegz agent was working that fix in place. tiffz did not edit the tree. The repin contract sent that evening asks for one `origin/yolo` commit that keeps `6ef766c` and rejects an over-subscribed table before the fast-table write, while the near-full tables in those tests still build.
