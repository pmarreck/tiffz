//! Stand-in for rawz when Validate injects its one tiffz dependency's parser
//! module into rawz source rather than accepting a second dependency instance.

const tiffz = @import("tiffz");

pub const Source = tiffz.Source;
pub const Ifd = tiffz.ifd.Ifd;
