//! Named TIFF tag constants. The set we need for M3 (classic
//! uncompressed strip-based TIFF). More tags accrete as later
//! milestones land.

pub const image_width: u16 = 256;            // 0x0100
pub const image_length: u16 = 257;           // 0x0101
pub const bits_per_sample: u16 = 258;        // 0x0102
pub const compression: u16 = 259;            // 0x0103
pub const photometric: u16 = 262;            // 0x0106
pub const fill_order: u16 = 266;             // 0x010A; 1 = MSB-first, 2 = LSB-first
pub const strip_offsets: u16 = 273;          // 0x0111
pub const samples_per_pixel: u16 = 277;      // 0x0115
pub const rows_per_strip: u16 = 278;         // 0x0116
pub const strip_byte_counts: u16 = 279;      // 0x0117
pub const planar_configuration: u16 = 284;   // 0x011C
pub const t4_options: u16 = 292;             // 0x0124; bit 0 = 2D, bit 1 = uncompressed, bit 2 = EOL byte align
pub const t6_options: u16 = 293;             // 0x0125; bit 1 = uncompressed
pub const predictor: u16 = 317;              // 0x013D
pub const colormap: u16 = 320;               // 0x0140
pub const tile_width: u16 = 322;             // 0x0142
pub const tile_length: u16 = 323;            // 0x0143
pub const tile_offsets: u16 = 324;           // 0x0144
pub const tile_byte_counts: u16 = 325;       // 0x0145
pub const jpeg_tables: u16 = 347;            // 0x015B; TIFF TN2 Mode 2 — shared JPEG abbreviated table datastream

/// Compression scheme codes (tag 259).
pub const compression_none: u16 = 1;
pub const compression_ccitt_t4: u16 = 3;     // Group 3 1D
pub const compression_ccitt_t6: u16 = 4;     // Group 4
pub const compression_lzw: u16 = 5;
pub const compression_jpeg_old: u16 = 6;     // OJPEG, deprecated
pub const compression_jpeg: u16 = 7;         // JPEG-in-TIFF (M9.5)
pub const compression_deflate: u16 = 8;
pub const compression_deflate_adobe: u16 = 32946;
pub const compression_packbits: u16 = 32773;

/// Photometric interpretation codes (tag 262).
pub const photometric_white_is_zero: u16 = 0;
pub const photometric_black_is_zero: u16 = 1;
pub const photometric_rgb: u16 = 2;
pub const photometric_palette: u16 = 3;
pub const photometric_transparency_mask: u16 = 4;
pub const photometric_separated_cmyk: u16 = 5;
pub const photometric_ycbcr: u16 = 6;
pub const photometric_cielab: u16 = 8;

/// Planar configuration codes (tag 284).
pub const planar_chunky: u16 = 1;            // RGBRGBRGB...
pub const planar_separate: u16 = 2;          // RRR...GGG...BBB...
