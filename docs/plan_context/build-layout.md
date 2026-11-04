# Build-layout conformance notes

Moved from PLAN.md (2026-11-04) when it was brought into the one-line format.

Rollout (skill order): stage the new layout first and keep the legacy `zig-out/bin` and `result` publication, since the shared shell PATH still admits them. The PATH cutover is the dotfiles owner's step; drop the legacy mirror after it.

Verified 2026-10-23 20:25 EDT: real `./build` (ALLOW_STALE for the lercz item) published `bin/linux-amd64/tiffz` -> `.nix-out/linux-amd64/musl/ReleaseFast`, header linux-amd64 static, `--about` PF=linux-amd64 VARIANT=musl; the direct backend built and passed `zig build test` natively (VARIANT=gnu). Not exercised: macOS and Windows hosts, and cross targets. Remaining: the shared PATH cutover to `bin/<PF>` (dotfiles owner), then drop the legacy `result` and `zig-out/bin` links.
