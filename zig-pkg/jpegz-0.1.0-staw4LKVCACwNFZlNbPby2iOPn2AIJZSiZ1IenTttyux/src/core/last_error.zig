//! Thread-local last-error preservation.
//!
//! Single canonical buffer shared between the Zig public API and the
//! C ABI — no string duplication. Both `jpegz.lastErrorMessage()`
//! (Zig, returns `?[]const u8`) and `jpegz_last_error_message()`
//! (C, returns `const char *`) read from the same backing memory.
//!
//! Threading: per-thread. A worker thread that calls `decode` and
//! hits an error sees its own message; no cross-thread bleed.
//!
//! Lifecycle: each public entry point clears the buffer on entry,
//! sets it on error. Callers can read it any time before the next
//! public call on the same thread.

const std = @import("std");

/// Backing buffer. Sized so a full DecodeError formatted message
/// plus the original error name fits without truncation
/// (libjpeg-turbo's longest WARN/ERR is ~120 chars; 512 leaves
/// headroom for "decode failed: <reason>: <detail>" composition).
threadlocal var buf: [512]u8 = undefined;
threadlocal var len: usize = 0;
threadlocal var initialized: bool = false;

inline fn ensureInitialized() void {
    if (!initialized) {
        buf[0] = 0;
        initialized = true;
    }
}

/// Clear the last-error buffer. Call at the start of every public
/// entry point so a successful call leaves a clean slate.
pub fn clear() void {
    ensureInitialized();
    len = 0;
    buf[0] = 0;
}

/// Write a formatted message into the last-error buffer. Truncates
/// at buf.len-1 to leave room for the NUL terminator. Safe to call
/// from any thread; each thread gets its own buffer.
pub fn set(comptime fmt: []const u8, args: anytype) void {
    ensureInitialized();
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    len = slice.len;
    if (len < buf.len) buf[len] = 0 else buf[buf.len - 1] = 0;
}

/// Return the current last-error message as a non-allocating slice.
/// Empty slice (len==0) means no error has been recorded on this
/// thread (or it was explicitly cleared). The returned slice's
/// memory is owned by the thread-local buffer — copy if you need to
/// outlive the next public call.
pub fn current() []const u8 {
    ensureInitialized();
    return buf[0..len];
}

/// Return a NUL-terminated C pointer to the backing buffer. Used
/// only by the C ABI; Zig callers should use `current()` instead.
/// Always returns a valid pointer (the buffer is statically
/// allocated); the string at the pointer is NUL-terminated.
pub fn cPtr() [*:0]const u8 {
    ensureInitialized();
    // Defensive: re-NUL-terminate at the current length in case the
    // last `set` truncated.
    if (len < buf.len) buf[len] = 0 else buf[buf.len - 1] = 0;
    return @ptrCast(&buf[0]);
}

test "set + current round-trip" {
    clear();
    try std.testing.expectEqual(@as(usize, 0), current().len);
    set("hello {s}", .{"world"});
    try std.testing.expectEqualStrings("hello world", current());
}

test "clear empties the message" {
    set("something", .{});
    try std.testing.expect(current().len > 0);
    clear();
    try std.testing.expectEqual(@as(usize, 0), current().len);
}

test "set truncates safely on oversized input" {
    clear();
    // Pass a >512-byte format-args pair. `bufPrint` errors, falls
    // back to the full buffer, NUL-terminated at buf.len-1.
    const big = [_]u8{'A'} ** 600;
    set("{s}", .{&big});
    const cur = current();
    try std.testing.expect(cur.len <= 512);
}

test "cPtr is NUL-terminated at end of message" {
    clear();
    set("ping", .{});
    const p = cPtr();
    const span = std.mem.span(p);
    try std.testing.expectEqualStrings("ping", span);
}
