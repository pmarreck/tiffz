//! Seekable byte-source abstraction. tiffz never opens files —
//! consumers pass a Source. Pread-style `read_at(buf, offset)` +
//! `size()` is the foundation; all four access patterns (validate /
//! pipeline / random / eager) build on this.
//!
//! Thread safety: read_at MUST be safe to call concurrently from
//! multiple threads. fromFile (pread) is. fromMmap is. fromBuffer
//! is. fromBufferedReader is NOT — single-threaded only by contract.
//!
//! M2: types only. Concrete adapters (fromBuffer / fromMmap /
//! fromFile / fromBufferedReader) land in M3 alongside the first
//! decoder that actually needs to read bytes.

pub const Source = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read into buf starting at byte `offset`. Returns bytes
        /// read. Short reads at EOF allowed; reads past end return 0.
        read_at: *const fn (ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize,
        /// Total size of the source, in bytes.
        size: *const fn (ctx: *anyopaque) anyerror!u64,
    };

    pub fn readAt(self: Source, buf: []u8, offset: u64) anyerror!usize {
        return self.vtable.read_at(self.ctx, buf, offset);
    }

    pub fn sizeOf(self: Source) anyerror!u64 {
        return self.vtable.size(self.ctx);
    }
};

test "Source type compiles" {
    _ = Source;
    _ = Source.VTable;
}
