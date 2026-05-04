//! Single canonical error set for tiffz. The C ABI's tiffz_status_t
//! enum is generated from this set (per design doc §7 / Q3 β —
//! 1:1 stable mapping enforced by build-time codegen).
//!
//! Discipline: append-only. Values are assigned at first introduction
//! by their position in this set; never reorder, never reuse. New
//! variants append at the end.

pub const Error = error{
    InvalidArgument,                     // 1
    Malformed,                           // 2
    UnsupportedCompression,              // 3
    UnsupportedPhotometric,              // 4
    UnsupportedPredictor,                // 5
    UnsupportedBitDepth,                 // 6
    UnsupportedTagType,                  // 7
    SourceSeekTooFarBack,                // 8
    SourceShortRead,                     // 9
    SourceTooShort,                      // 10
    LimitExceededIfdCount,               // 11
    LimitExceededTagCount,               // 12
    LimitExceededTagValueBytes,          // 13
    LimitExceededStripCount,             // 14
    LimitExceededDimension,              // 15
    LimitExceededTotalSamples,           // 16
    LimitExceededCodecScratch,           // 17
    LimitExceededCompressedStripBytes,   // 18
    LimitExceededDecompressedStripBytes, // 19
    DestTooSmall,                        // 20
    OutOfMemory,                         // 21
    Io,                                  // 22 — Source.read_at error pass-through
    Bug,                                 // 23 — internal invariant violated
};

test "Error type compiles and references resolve" {
    const std = @import("std");
    // Reference a known variant — drop the variant from the set and
    // this test fails to compile, catching the regression at build
    // time.
    const sentinel: Error = error.InvalidArgument;
    try std.testing.expectEqual(Error.InvalidArgument, sentinel);
}
