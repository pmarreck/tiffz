//! Larson's (u', v') index table for SGILog24 (Compression 34677).
//!
//! The 163 rows below are data from libtiff's uvcode.h ("Version 1.0
//! generated April 7, 1997 by Greg Ward Larson, SGI"), carried with the
//! notice its license requires:
//!
//! Copyright (c) 1997 Greg Ward Larson
//! Copyright (c) 1997 Silicon Graphics, Inc.
//!
//! Permission to use, copy, modify, distribute, and sell this software and
//! its documentation for any purpose is hereby granted without fee, provided
//! that (i) the above copyright notices and this permission notice appear in
//! all copies of the software and related documentation, and (ii) the names of
//! Sam Leffler, Greg Larson and Silicon Graphics may not be used in any
//! advertising or publicity relating to the software without the specific,
//! prior written permission of Sam Leffler, Greg Larson and Silicon Graphics.
//!
//! THE SOFTWARE IS PROVIDED "AS-IS" AND WITHOUT WARRANTY OF ANY KIND,
//! EXPRESS, IMPLIED OR OTHERWISE, INCLUDING WITHOUT LIMITATION, ANY
//! WARRANTY OF MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.
//!
//! IN NO EVENT SHALL SAM LEFFLER, GREG LARSON OR SILICON GRAPHICS BE LIABLE
//! FOR ANY SPECIAL, INCIDENTAL, INDIRECT OR CONSEQUENTIAL DAMAGES OF ANY KIND,
//! OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
//! WHETHER OR NOT ADVISED OF THE POSSIBILITY OF DAMAGE, AND ON ANY THEORY OF
//! LIABILITY, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
//! OF THIS SOFTWARE.
//!
//! The index covers the visible gamut in squares of side `sq_size`: row vi
//! holds the squares at v' = v_start + (vi + 0.5) * sq_size, `nus` of them,
//! starting at u' = `ustart`, and `ncum` counts the squares in earlier rows.

/// Side of one (u', v') square. The C header declares it as a float.
pub const sq_size: f32 = 0.003500;
/// v' of the lower edge of row 0, a float in the C header.
pub const v_start: f32 = 0.016940;
/// Number of squares, so valid indices are 0 to `divisions - 1`.
pub const divisions: u16 = 16289;

pub const Row = struct { ustart: f32, nus: u16, ncum: u16 };

pub const rows = [_]Row{
    .{ .ustart = 0.247663, .nus = 4, .ncum = 0 },
    .{ .ustart = 0.243779, .nus = 6, .ncum = 4 },
    .{ .ustart = 0.241684, .nus = 7, .ncum = 10 },
    .{ .ustart = 0.237874, .nus = 9, .ncum = 17 },
    .{ .ustart = 0.235906, .nus = 10, .ncum = 26 },
    .{ .ustart = 0.232153, .nus = 12, .ncum = 36 },
    .{ .ustart = 0.228352, .nus = 14, .ncum = 48 },
    .{ .ustart = 0.226259, .nus = 15, .ncum = 62 },
    .{ .ustart = 0.222371, .nus = 17, .ncum = 77 },
    .{ .ustart = 0.220410, .nus = 18, .ncum = 94 },
    .{ .ustart = 0.214710, .nus = 21, .ncum = 112 },
    .{ .ustart = 0.212714, .nus = 22, .ncum = 133 },
    .{ .ustart = 0.210721, .nus = 23, .ncum = 155 },
    .{ .ustart = 0.204976, .nus = 26, .ncum = 178 },
    .{ .ustart = 0.202986, .nus = 27, .ncum = 204 },
    .{ .ustart = 0.199245, .nus = 29, .ncum = 231 },
    .{ .ustart = 0.195525, .nus = 31, .ncum = 260 },
    .{ .ustart = 0.193560, .nus = 32, .ncum = 291 },
    .{ .ustart = 0.189878, .nus = 34, .ncum = 323 },
    .{ .ustart = 0.186216, .nus = 36, .ncum = 357 },
    .{ .ustart = 0.186216, .nus = 36, .ncum = 393 },
    .{ .ustart = 0.182592, .nus = 38, .ncum = 429 },
    .{ .ustart = 0.179003, .nus = 40, .ncum = 467 },
    .{ .ustart = 0.175466, .nus = 42, .ncum = 507 },
    .{ .ustart = 0.172001, .nus = 44, .ncum = 549 },
    .{ .ustart = 0.172001, .nus = 44, .ncum = 593 },
    .{ .ustart = 0.168612, .nus = 46, .ncum = 637 },
    .{ .ustart = 0.168612, .nus = 46, .ncum = 683 },
    .{ .ustart = 0.163575, .nus = 49, .ncum = 729 },
    .{ .ustart = 0.158642, .nus = 52, .ncum = 778 },
    .{ .ustart = 0.158642, .nus = 52, .ncum = 830 },
    .{ .ustart = 0.158642, .nus = 52, .ncum = 882 },
    .{ .ustart = 0.153815, .nus = 55, .ncum = 934 },
    .{ .ustart = 0.153815, .nus = 55, .ncum = 989 },
    .{ .ustart = 0.149097, .nus = 58, .ncum = 1044 },
    .{ .ustart = 0.149097, .nus = 58, .ncum = 1102 },
    .{ .ustart = 0.142746, .nus = 62, .ncum = 1160 },
    .{ .ustart = 0.142746, .nus = 62, .ncum = 1222 },
    .{ .ustart = 0.142746, .nus = 62, .ncum = 1284 },
    .{ .ustart = 0.138270, .nus = 65, .ncum = 1346 },
    .{ .ustart = 0.138270, .nus = 65, .ncum = 1411 },
    .{ .ustart = 0.138270, .nus = 65, .ncum = 1476 },
    .{ .ustart = 0.132166, .nus = 69, .ncum = 1541 },
    .{ .ustart = 0.132166, .nus = 69, .ncum = 1610 },
    .{ .ustart = 0.126204, .nus = 73, .ncum = 1679 },
    .{ .ustart = 0.126204, .nus = 73, .ncum = 1752 },
    .{ .ustart = 0.126204, .nus = 73, .ncum = 1825 },
    .{ .ustart = 0.120381, .nus = 77, .ncum = 1898 },
    .{ .ustart = 0.120381, .nus = 77, .ncum = 1975 },
    .{ .ustart = 0.120381, .nus = 77, .ncum = 2052 },
    .{ .ustart = 0.120381, .nus = 77, .ncum = 2129 },
    .{ .ustart = 0.112962, .nus = 82, .ncum = 2206 },
    .{ .ustart = 0.112962, .nus = 82, .ncum = 2288 },
    .{ .ustart = 0.112962, .nus = 82, .ncum = 2370 },
    .{ .ustart = 0.107450, .nus = 86, .ncum = 2452 },
    .{ .ustart = 0.107450, .nus = 86, .ncum = 2538 },
    .{ .ustart = 0.107450, .nus = 86, .ncum = 2624 },
    .{ .ustart = 0.107450, .nus = 86, .ncum = 2710 },
    .{ .ustart = 0.100343, .nus = 91, .ncum = 2796 },
    .{ .ustart = 0.100343, .nus = 91, .ncum = 2887 },
    .{ .ustart = 0.100343, .nus = 91, .ncum = 2978 },
    .{ .ustart = 0.095126, .nus = 95, .ncum = 3069 },
    .{ .ustart = 0.095126, .nus = 95, .ncum = 3164 },
    .{ .ustart = 0.095126, .nus = 95, .ncum = 3259 },
    .{ .ustart = 0.095126, .nus = 95, .ncum = 3354 },
    .{ .ustart = 0.088276, .nus = 100, .ncum = 3449 },
    .{ .ustart = 0.088276, .nus = 100, .ncum = 3549 },
    .{ .ustart = 0.088276, .nus = 100, .ncum = 3649 },
    .{ .ustart = 0.088276, .nus = 100, .ncum = 3749 },
    .{ .ustart = 0.081523, .nus = 105, .ncum = 3849 },
    .{ .ustart = 0.081523, .nus = 105, .ncum = 3954 },
    .{ .ustart = 0.081523, .nus = 105, .ncum = 4059 },
    .{ .ustart = 0.081523, .nus = 105, .ncum = 4164 },
    .{ .ustart = 0.074861, .nus = 110, .ncum = 4269 },
    .{ .ustart = 0.074861, .nus = 110, .ncum = 4379 },
    .{ .ustart = 0.074861, .nus = 110, .ncum = 4489 },
    .{ .ustart = 0.074861, .nus = 110, .ncum = 4599 },
    .{ .ustart = 0.068290, .nus = 115, .ncum = 4709 },
    .{ .ustart = 0.068290, .nus = 115, .ncum = 4824 },
    .{ .ustart = 0.068290, .nus = 115, .ncum = 4939 },
    .{ .ustart = 0.068290, .nus = 115, .ncum = 5054 },
    .{ .ustart = 0.063573, .nus = 119, .ncum = 5169 },
    .{ .ustart = 0.063573, .nus = 119, .ncum = 5288 },
    .{ .ustart = 0.063573, .nus = 119, .ncum = 5407 },
    .{ .ustart = 0.063573, .nus = 119, .ncum = 5526 },
    .{ .ustart = 0.057219, .nus = 124, .ncum = 5645 },
    .{ .ustart = 0.057219, .nus = 124, .ncum = 5769 },
    .{ .ustart = 0.057219, .nus = 124, .ncum = 5893 },
    .{ .ustart = 0.057219, .nus = 124, .ncum = 6017 },
    .{ .ustart = 0.050985, .nus = 129, .ncum = 6141 },
    .{ .ustart = 0.050985, .nus = 129, .ncum = 6270 },
    .{ .ustart = 0.050985, .nus = 129, .ncum = 6399 },
    .{ .ustart = 0.050985, .nus = 129, .ncum = 6528 },
    .{ .ustart = 0.050985, .nus = 129, .ncum = 6657 },
    .{ .ustart = 0.044859, .nus = 134, .ncum = 6786 },
    .{ .ustart = 0.044859, .nus = 134, .ncum = 6920 },
    .{ .ustart = 0.044859, .nus = 134, .ncum = 7054 },
    .{ .ustart = 0.044859, .nus = 134, .ncum = 7188 },
    .{ .ustart = 0.040571, .nus = 138, .ncum = 7322 },
    .{ .ustart = 0.040571, .nus = 138, .ncum = 7460 },
    .{ .ustart = 0.040571, .nus = 138, .ncum = 7598 },
    .{ .ustart = 0.040571, .nus = 138, .ncum = 7736 },
    .{ .ustart = 0.036339, .nus = 142, .ncum = 7874 },
    .{ .ustart = 0.036339, .nus = 142, .ncum = 8016 },
    .{ .ustart = 0.036339, .nus = 142, .ncum = 8158 },
    .{ .ustart = 0.036339, .nus = 142, .ncum = 8300 },
    .{ .ustart = 0.032139, .nus = 146, .ncum = 8442 },
    .{ .ustart = 0.032139, .nus = 146, .ncum = 8588 },
    .{ .ustart = 0.032139, .nus = 146, .ncum = 8734 },
    .{ .ustart = 0.032139, .nus = 146, .ncum = 8880 },
    .{ .ustart = 0.027947, .nus = 150, .ncum = 9026 },
    .{ .ustart = 0.027947, .nus = 150, .ncum = 9176 },
    .{ .ustart = 0.027947, .nus = 150, .ncum = 9326 },
    .{ .ustart = 0.023739, .nus = 154, .ncum = 9476 },
    .{ .ustart = 0.023739, .nus = 154, .ncum = 9630 },
    .{ .ustart = 0.023739, .nus = 154, .ncum = 9784 },
    .{ .ustart = 0.023739, .nus = 154, .ncum = 9938 },
    .{ .ustart = 0.019504, .nus = 158, .ncum = 10092 },
    .{ .ustart = 0.019504, .nus = 158, .ncum = 10250 },
    .{ .ustart = 0.019504, .nus = 158, .ncum = 10408 },
    .{ .ustart = 0.016976, .nus = 161, .ncum = 10566 },
    .{ .ustart = 0.016976, .nus = 161, .ncum = 10727 },
    .{ .ustart = 0.016976, .nus = 161, .ncum = 10888 },
    .{ .ustart = 0.016976, .nus = 161, .ncum = 11049 },
    .{ .ustart = 0.012639, .nus = 165, .ncum = 11210 },
    .{ .ustart = 0.012639, .nus = 165, .ncum = 11375 },
    .{ .ustart = 0.012639, .nus = 165, .ncum = 11540 },
    .{ .ustart = 0.009991, .nus = 168, .ncum = 11705 },
    .{ .ustart = 0.009991, .nus = 168, .ncum = 11873 },
    .{ .ustart = 0.009991, .nus = 168, .ncum = 12041 },
    .{ .ustart = 0.009016, .nus = 170, .ncum = 12209 },
    .{ .ustart = 0.009016, .nus = 170, .ncum = 12379 },
    .{ .ustart = 0.009016, .nus = 170, .ncum = 12549 },
    .{ .ustart = 0.006217, .nus = 173, .ncum = 12719 },
    .{ .ustart = 0.006217, .nus = 173, .ncum = 12892 },
    .{ .ustart = 0.005097, .nus = 175, .ncum = 13065 },
    .{ .ustart = 0.005097, .nus = 175, .ncum = 13240 },
    .{ .ustart = 0.005097, .nus = 175, .ncum = 13415 },
    .{ .ustart = 0.003909, .nus = 177, .ncum = 13590 },
    .{ .ustart = 0.003909, .nus = 177, .ncum = 13767 },
    .{ .ustart = 0.002340, .nus = 177, .ncum = 13944 },
    .{ .ustart = 0.002389, .nus = 170, .ncum = 14121 },
    .{ .ustart = 0.001068, .nus = 164, .ncum = 14291 },
    .{ .ustart = 0.001653, .nus = 157, .ncum = 14455 },
    .{ .ustart = 0.000717, .nus = 150, .ncum = 14612 },
    .{ .ustart = 0.001614, .nus = 143, .ncum = 14762 },
    .{ .ustart = 0.000270, .nus = 136, .ncum = 14905 },
    .{ .ustart = 0.000484, .nus = 129, .ncum = 15041 },
    .{ .ustart = 0.001103, .nus = 123, .ncum = 15170 },
    .{ .ustart = 0.001242, .nus = 115, .ncum = 15293 },
    .{ .ustart = 0.001188, .nus = 109, .ncum = 15408 },
    .{ .ustart = 0.001011, .nus = 103, .ncum = 15517 },
    .{ .ustart = 0.000709, .nus = 97, .ncum = 15620 },
    .{ .ustart = 0.000301, .nus = 89, .ncum = 15717 },
    .{ .ustart = 0.002416, .nus = 82, .ncum = 15806 },
    .{ .ustart = 0.003251, .nus = 76, .ncum = 15888 },
    .{ .ustart = 0.003246, .nus = 69, .ncum = 15964 },
    .{ .ustart = 0.004141, .nus = 62, .ncum = 16033 },
    .{ .ustart = 0.005963, .nus = 55, .ncum = 16095 },
    .{ .ustart = 0.008839, .nus = 47, .ncum = 16150 },
    .{ .ustart = 0.010490, .nus = 40, .ncum = 16197 },
    .{ .ustart = 0.016994, .nus = 31, .ncum = 16237 },
    .{ .ustart = 0.023659, .nus = 21, .ncum = 16268 },
};

const std = @import("std");

test "uv table: 163 rows whose counts add up to the declared divisions" {
    try std.testing.expectEqual(@as(usize, 163), rows.len);
    var total: u32 = 0;
    for (rows) |row| {
        try std.testing.expectEqual(@as(u32, row.ncum), total);
        total += row.nus;
    }
    try std.testing.expectEqual(@as(u32, divisions), total);
}
