//! Named TIFF tag constants. The set we need for M3 (classic
//! uncompressed strip-based TIFF). More tags accrete as later
//! milestones land.

pub const subfile_type: u16 = 255;           // 0x00FF; SHORT, 1-3 (superseded by NewSubfileType)
pub const image_width: u16 = 256;            // 0x0100
pub const image_length: u16 = 257;           // 0x0101
pub const bits_per_sample: u16 = 258;        // 0x0102
pub const compression: u16 = 259;            // 0x0103
pub const photometric: u16 = 262;            // 0x0106
pub const threshholding: u16 = 263;          // 0x0107; SHORT, 1-3 (the spec's spelling)
pub const fill_order: u16 = 266;            // 0x010A; 1 = MSB-first, 2 = LSB-first
pub const strip_offsets: u16 = 273;          // 0x0111
pub const samples_per_pixel: u16 = 277;      // 0x0115
pub const orientation: u16 = 274;            // 0x0112; SHORT, 1-8
pub const rows_per_strip: u16 = 278;         // 0x0116
pub const strip_byte_counts: u16 = 279;      // 0x0117
/// Child IFD offsets (TIFF Tech Note 1 / DNG). Not a next-IFD link.
pub const sub_ifds: u16 = 330;               // 0x014A
pub const planar_configuration: u16 = 284;   // 0x011C
pub const gray_response_unit: u16 = 290;     // 0x0122; SHORT, 1-5
pub const t4_options: u16 = 292;            // 0x0124; bit 0 = 2D, bit 1 = uncompressed, bit 2 = EOL byte align
pub const t6_options: u16 = 293;             // 0x0125; bit 1 = uncompressed
pub const resolution_unit: u16 = 296;        // 0x0128; SHORT, 1-3
pub const transfer_function: u16 = 301;     // 0x012D; SHORT[{1 or 3} * 2**BitsPerSample]
pub const predictor: u16 = 317;              // 0x013D
pub const colormap: u16 = 320;               // 0x0140
pub const tile_width: u16 = 322;             // 0x0142
pub const tile_length: u16 = 323;            // 0x0143
pub const tile_offsets: u16 = 324;           // 0x0144
pub const tile_byte_counts: u16 = 325;       // 0x0145
pub const ink_set: u16 = 332;                // 0x014C; SHORT, 1-2
pub const extra_samples: u16 = 338;         // 0x0152; SHORT[N]; per extra sample: 0=unspec, 1=associated alpha (pre-multiplied), 2=unassociated alpha
pub const sample_format: u16 = 339;          // 0x0153; SHORT[SamplesPerPixel], 1-4
pub const jpeg_tables: u16 = 347;           // 0x015B; TIFF TN2 Mode 2 — shared JPEG abbreviated table datastream
pub const jpeg_interchange_format: u16 = 513; // 0x0201; thumbnail JPEG blob, not a strip offset
pub const jpeg_interchange_format_length: u16 = 514; // 0x0202
pub const ycbcr_subsampling: u16 = 530;      // 0x0212; SHORT[2] [ChromaSubsampleHoriz, ChromaSubsampleVert], default [2,2]
pub const ycbcr_positioning: u16 = 531;      // 0x0213; SHORT, 1-2

/// DNG / TIFF-EP tags (M8).
pub const cfa_repeat_pattern_dim: u16 = 33421; // 0x828D; SHORT[2] — pattern dims (width, height)
pub const cfa_pattern: u16 = 33422;            // 0x828E; BYTE[dim_w * dim_h] — pattern values 0=R 1=G 2=B 3=C 4=M 5=Y 6=W
pub const opcode_list_1: u16 = 51008;          // 0xC740; UNDEFINED — Adobe opcode list applied to raw image (pre-mosaic)
pub const opcode_list_2: u16 = 51009;          // 0xC741; UNDEFINED — opcode list applied after demosaic, before mapping
pub const opcode_list_3: u16 = 51022;          // 0xC74E; UNDEFINED — opcode list applied after color-mapping

/// CFA photometric code (tag 262 = 32803).
pub const photometric_color_filter_array: u16 = 32803;

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
pub const compression_zstd: u16 = 50000;     // GDAL/libtiff extension, M12
pub const compression_lerc: u16 = 34887;     // Esri LERC (GDAL/libtiff), M12

/// LercParameters tag (private). Two u32 values:
/// [codec_version, add_compression] where add_compression ∈
/// {0 = none, 1 = Deflate post-filter, 2 = Zstd post-filter}.
pub const lerc_parameters: u16 = 50674;
pub const lerc_add_compression_none: u32 = 0;
pub const lerc_add_compression_deflate: u32 = 1;
pub const lerc_add_compression_zstd: u32 = 2;

/// GeoTIFF spec tags (M11 metadata surface). See OGC GeoTIFF 1.1.
pub const model_pixel_scale: u16 = 33550;      // 3 DOUBLE: [Sx, Sy, Sz]
pub const model_tiepoint: u16 = 33922;         // 6N DOUBLE: N × [I, J, K, X, Y, Z]
pub const model_transformation: u16 = 34264;   // 16 DOUBLE: 4×4 affine matrix
pub const geo_key_directory: u16 = 34735;      // 4+4N SHORT: header + N keys
pub const geo_double_params: u16 = 34736;      // M DOUBLE: values referenced by keys
pub const geo_ascii_params: u16 = 34737;       // ASCII: '|'-separated strings referenced by keys

/// Photometric interpretation codes (tag 262).
pub const photometric_white_is_zero: u16 = 0;
pub const photometric_black_is_zero: u16 = 1;
pub const photometric_rgb: u16 = 2;
pub const photometric_palette: u16 = 3;
pub const photometric_transparency_mask: u16 = 4;
pub const photometric_separated_cmyk: u16 = 5;
pub const photometric_ycbcr: u16 = 6;
pub const photometric_cielab: u16 = 8;
pub const photometric_icclab: u16 = 9;  // TIFF Tech Note 3: unsigned a/b with bias 128

/// Planar configuration codes (tag 284).
pub const planar_chunky: u16 = 1;            // RGBRGBRGB...
pub const planar_separate: u16 = 2;          // RRR...GGG...BBB...

/// Further TIFF 6.0 fields checked by ifd_conformance (type, count, values).
pub const new_subfile_type: u16 = 254;       // 0x00FE; LONG, N = 1
pub const cell_width: u16 = 264;             // 0x0108; SHORT, N = 1
pub const cell_length: u16 = 265;            // 0x0109; SHORT, N = 1
pub const document_name: u16 = 269;          // 0x010D; ASCII
pub const image_description: u16 = 270;      // 0x010E; ASCII
pub const make: u16 = 271;                   // 0x010F; ASCII
pub const model: u16 = 272;                  // 0x0110; ASCII
pub const min_sample_value: u16 = 280;       // 0x0118; SHORT, N = SamplesPerPixel
pub const max_sample_value: u16 = 281;       // 0x0119; SHORT, N = SamplesPerPixel
pub const x_resolution: u16 = 282;           // 0x011A; RATIONAL, N = 1
pub const y_resolution: u16 = 283;           // 0x011B; RATIONAL, N = 1
pub const page_name: u16 = 285;              // 0x011D; ASCII
pub const x_position: u16 = 286;             // 0x011E; RATIONAL, N = 1
pub const y_position: u16 = 287;             // 0x011F; RATIONAL, N = 1
pub const free_offsets: u16 = 288;           // 0x0120; LONG
pub const free_byte_counts: u16 = 289;       // 0x0121; LONG
pub const gray_response_curve: u16 = 291;    // 0x0123; SHORT, N = 2**BitsPerSample
pub const page_number: u16 = 297;            // 0x0129; SHORT, N = 2
pub const software: u16 = 305;               // 0x0131; ASCII
pub const date_time: u16 = 306;              // 0x0132; ASCII, N = 20, "YYYY:MM:DD HH:MM:SS"
pub const artist: u16 = 315;                 // 0x013B; ASCII
pub const host_computer: u16 = 316;          // 0x013C; ASCII
pub const white_point: u16 = 318;            // 0x013E; RATIONAL, N = 2
pub const primary_chromaticities: u16 = 319; // 0x013F; RATIONAL, N = 6
pub const halftone_hints: u16 = 321;         // 0x0141; SHORT, N = 2
pub const ink_names: u16 = 333;              // 0x014D; ASCII
pub const number_of_inks: u16 = 334;         // 0x014E; SHORT, N = 1
pub const dot_range: u16 = 336;              // 0x0150; BYTE or SHORT, N = 2 or 2 * SamplesPerPixel
pub const target_printer: u16 = 337;         // 0x0151; ASCII
pub const transfer_range: u16 = 342;         // 0x0156; SHORT, N = 6
pub const jpeg_proc: u16 = 512;              // 0x0200; SHORT, 1 or 14
pub const jpeg_restart_interval: u16 = 515;  // 0x0203; SHORT, N = 1
pub const jpeg_lossless_predictors: u16 = 517; // 0x0205; SHORT, N = SamplesPerPixel, 1-7
pub const jpeg_point_transforms: u16 = 518;  // 0x0206; SHORT, N = SamplesPerPixel
pub const jpeg_q_tables: u16 = 519;          // 0x0207; LONG, N = SamplesPerPixel
pub const jpeg_dc_tables: u16 = 520;         // 0x0208; LONG, N = SamplesPerPixel
pub const jpeg_ac_tables: u16 = 521;         // 0x0209; LONG, N = SamplesPerPixel
pub const ycbcr_coefficients: u16 = 529;     // 0x0211; RATIONAL, N = 3
pub const reference_black_white: u16 = 532;  // 0x0214; RATIONAL, N = 6
pub const copyright: u16 = 33432;            // 0x8298; ASCII (defined by TIFF 6.0 despite its number)

/// Fields from the TIFF Technical Notes checked by ifd_conformance.
pub const clip_path: u16 = 343;              // 0x0157; BYTE (PageMaker 6.0 notes)
pub const x_clip_path_units: u16 = 344;      // 0x0158; "DWORD", N = 1 (PageMaker 6.0 notes)
pub const y_clip_path_units: u16 = 345;      // 0x0159; "DWORD", N = 1 (PageMaker 6.0 notes)
pub const indexed: u16 = 346;                // 0x015A; SHORT, 0-1 (PageMaker 6.0 notes)
pub const opi_proxy: u16 = 351;              // 0x015F; SHORT, 0-1 (PageMaker 6.0 notes)
pub const image_id: u16 = 32781;             // 0x800D; ASCII (PageMaker 6.0 notes)
pub const image_source_data: u16 = 37724;    // 0x935C; UNDEFINED (Photoshop TIFF Technical Notes)
