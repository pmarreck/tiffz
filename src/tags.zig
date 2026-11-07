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
pub const s_min_sample_value: u16 = 340;   // 0x0154; type matching the samples, N = SamplesPerPixel
pub const s_max_sample_value: u16 = 341;   // 0x0155; type matching the samples, N = SamplesPerPixel
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
pub const photometric_log_l: u16 = 32844;          // SGILog LogL (libtiff tif_luv.c)
pub const photometric_log_luv: u16 = 32845;        // SGILog LogLuv (libtiff tif_luv.c)

/// Compression scheme codes (tag 259).
pub const compression_none: u16 = 1;
pub const compression_ccitt_rle: u16 = 2;    // CCITT modified Huffman (TIFF 6.0 section 10)
pub const compression_ccitt_t4: u16 = 3;     // Group 3 1D
pub const compression_ccitt_t6: u16 = 4;     // Group 4
pub const compression_lzw: u16 = 5;
pub const compression_jpeg_old: u16 = 6;     // OJPEG, deprecated
pub const compression_jpeg: u16 = 7;         // JPEG-in-TIFF (M9.5)
pub const compression_deflate: u16 = 8;
pub const compression_deflate_adobe: u16 = 32946;
pub const compression_packbits: u16 = 32773;
pub const compression_next: u16 = 32766;     // NeXT 2-bit gray RLE (libtiff tif_next.c)
pub const compression_thunderscan: u16 = 32809; // ThunderScan 4-bit (libtiff tif_thunder.c)
pub const compression_sgilog: u16 = 34676;   // SGILog LogL and LogLuv32 (libtiff tif_luv.c)
pub const compression_sgilog24: u16 = 34677; // SGILog24, LogLuv24 (libtiff tif_luv.c)
pub const compression_zstd: u16 = 50000;     // GDAL/libtiff extension, M12
pub const compression_lerc: u16 = 34887;     // Esri LERC (GDAL/libtiff), M12
pub const compression_jpegxl: u16 = 50002;   // JPEG XL (GDAL/libtiff)
pub const compression_dng_jpegxl: u16 = 52546; // JPEG XL (DNG 1.7)

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

/// TIFF-FX fields (RFC 3949, which obsoletes RFC 2301) checked by ifd_conformance.
pub const bad_fax_lines: u16 = 326;          // 0x0146; SHORT or LONG, N = 1
pub const clean_fax_data: u16 = 327;         // 0x0147; SHORT, 0-2
pub const consecutive_bad_fax_lines: u16 = 328; // 0x0148; LONG or SHORT, N = 1
pub const global_parameters_ifd: u16 = 400;  // 0x0190; IFD or LONG
pub const profile_type: u16 = 401;           // 0x0191; LONG, 0-1
pub const fax_profile: u16 = 402;            // 0x0192; BYTE, 0-6
pub const coding_methods: u16 = 403;         // 0x0193; LONG bit flags
pub const version_year: u16 = 404;           // 0x0194; BYTE[4], e.g. '1997'
pub const mode_number: u16 = 405;            // 0x0195; BYTE
pub const decode: u16 = 433;                 // 0x01B1; SRATIONAL[2 * SamplesPerPixel]
pub const image_base_color: u16 = 434;       // 0x01B2; SHORT[SamplesPerPixel] (RFC 2301: DefaultImageColor)
pub const t82_options: u16 = 435;            // 0x01B3; LONG (RFC 3949 only)
pub const strip_row_counts: u16 = 559;       // 0x022F; LONG[number of strips]
pub const image_layer: u16 = 34732;          // 0x87AC; LONG[2] (RFC 2301: SHORT or LONG)

/// DNG tags (Digital Negative Specification 1.6.0.0, Chapter 4) checked by
/// ifd_conformance; the comment names the edition that added each. OpcodeList1-3
/// are above. PhotometricInterpretation and Compression values DNG defines
/// follow.
pub const dng_version: u16 = 50706; // 0xC612; DNG 1.0/1.1
pub const dng_backward_version: u16 = 50707; // 0xC613; DNG 1.0/1.1
pub const unique_camera_model: u16 = 50708; // 0xC614; DNG 1.0/1.1
pub const localized_camera_model: u16 = 50709; // 0xC615; DNG 1.0/1.1
pub const cfa_plane_color: u16 = 50710; // 0xC616; DNG 1.0/1.1
pub const cfa_layout: u16 = 50711; // 0xC617; DNG 1.0/1.1
pub const linearization_table: u16 = 50712; // 0xC618; DNG 1.0/1.1
pub const black_level_repeat_dim: u16 = 50713; // 0xC619; DNG 1.0/1.1
pub const black_level: u16 = 50714; // 0xC61A; DNG 1.0/1.1
pub const black_level_delta_h: u16 = 50715; // 0xC61B; DNG 1.0/1.1
pub const black_level_delta_v: u16 = 50716; // 0xC61C; DNG 1.0/1.1
pub const white_level: u16 = 50717; // 0xC61D; DNG 1.0/1.1
pub const default_scale: u16 = 50718; // 0xC61E; DNG 1.0/1.1
pub const best_quality_scale: u16 = 50780; // 0xC65C; DNG 1.0/1.1
pub const default_crop_origin: u16 = 50719; // 0xC61F; DNG 1.0/1.1
pub const default_crop_size: u16 = 50720; // 0xC620; DNG 1.0/1.1
pub const calibration_illuminant_1: u16 = 50778; // 0xC65A; DNG 1.0/1.1
pub const calibration_illuminant_2: u16 = 50779; // 0xC65B; DNG 1.0/1.1
pub const color_matrix_1: u16 = 50721; // 0xC621; DNG 1.0/1.1
pub const color_matrix_2: u16 = 50722; // 0xC622; DNG 1.0/1.1
pub const camera_calibration_1: u16 = 50723; // 0xC623; DNG 1.0/1.1
pub const camera_calibration_2: u16 = 50724; // 0xC624; DNG 1.0/1.1
pub const reduction_matrix_1: u16 = 50725; // 0xC625; DNG 1.0/1.1
pub const reduction_matrix_2: u16 = 50726; // 0xC626; DNG 1.0/1.1
pub const analog_balance: u16 = 50727; // 0xC627; DNG 1.0/1.1
pub const as_shot_neutral: u16 = 50728; // 0xC628; DNG 1.0/1.1
pub const as_shot_white_xy: u16 = 50729; // 0xC629; DNG 1.0/1.1
pub const baseline_exposure: u16 = 50730; // 0xC62A; DNG 1.0/1.1
pub const baseline_noise: u16 = 50731; // 0xC62B; DNG 1.0/1.1
pub const baseline_sharpness: u16 = 50732; // 0xC62C; DNG 1.0/1.1
pub const bayer_green_split: u16 = 50733; // 0xC62D; DNG 1.0/1.1
pub const linear_response_limit: u16 = 50734; // 0xC62E; DNG 1.0/1.1
pub const camera_serial_number: u16 = 50735; // 0xC62F; DNG 1.0/1.1
pub const lens_info: u16 = 50736; // 0xC630; DNG 1.0/1.1
pub const chroma_blur_radius: u16 = 50737; // 0xC631; DNG 1.0/1.1
pub const anti_alias_strength: u16 = 50738; // 0xC632; DNG 1.0/1.1
pub const shadow_scale: u16 = 50739; // 0xC633; DNG 1.0/1.1
pub const dng_private_data: u16 = 50740; // 0xC634; DNG 1.0/1.1
pub const maker_note_safety: u16 = 50741; // 0xC635; DNG 1.0/1.1
pub const raw_data_unique_id: u16 = 50781; // 0xC65D; DNG 1.0/1.1
pub const original_raw_file_name: u16 = 50827; // 0xC68B; DNG 1.0/1.1
pub const original_raw_file_data: u16 = 50828; // 0xC68C; DNG 1.0/1.1
pub const active_area: u16 = 50829; // 0xC68D; DNG 1.0/1.1
pub const masked_areas: u16 = 50830; // 0xC68E; DNG 1.0/1.1
pub const as_shot_icc_profile: u16 = 50831; // 0xC68F; DNG 1.0/1.1
pub const as_shot_pre_profile_matrix: u16 = 50832; // 0xC690; DNG 1.0/1.1
pub const current_icc_profile: u16 = 50833; // 0xC691; DNG 1.0/1.1
pub const current_pre_profile_matrix: u16 = 50834; // 0xC692; DNG 1.0/1.1
pub const colorimetric_reference: u16 = 50879; // 0xC6BF; DNG 1.2.0.0
pub const camera_calibration_signature: u16 = 50931; // 0xC6F3; DNG 1.2.0.0
pub const profile_calibration_signature: u16 = 50932; // 0xC6F4; DNG 1.2.0.0
pub const extra_camera_profiles: u16 = 50933; // 0xC6F5; DNG 1.2.0.0
pub const as_shot_profile_name: u16 = 50934; // 0xC6F6; DNG 1.2.0.0
pub const noise_reduction_applied: u16 = 50935; // 0xC6F7; DNG 1.2.0.0
pub const profile_name: u16 = 50936; // 0xC6F8; DNG 1.2.0.0
pub const profile_hue_sat_map_dims: u16 = 50937; // 0xC6F9; DNG 1.2.0.0
pub const profile_hue_sat_map_data_1: u16 = 50938; // 0xC6FA; DNG 1.2.0.0
pub const profile_hue_sat_map_data_2: u16 = 50939; // 0xC6FB; DNG 1.2.0.0
pub const profile_tone_curve: u16 = 50940; // 0xC6FC; DNG 1.2.0.0
pub const profile_embed_policy: u16 = 50941; // 0xC6FD; DNG 1.2.0.0
pub const profile_copyright: u16 = 50942; // 0xC6FE; DNG 1.2.0.0
pub const forward_matrix_1: u16 = 50964; // 0xC714; DNG 1.2.0.0
pub const forward_matrix_2: u16 = 50965; // 0xC715; DNG 1.2.0.0
pub const preview_application_name: u16 = 50966; // 0xC716; DNG 1.2.0.0
pub const preview_application_version: u16 = 50967; // 0xC717; DNG 1.2.0.0
pub const preview_settings_name: u16 = 50968; // 0xC718; DNG 1.2.0.0
pub const preview_settings_digest: u16 = 50969; // 0xC719; DNG 1.2.0.0
pub const preview_color_space: u16 = 50970; // 0xC71A; DNG 1.2.0.0
pub const preview_date_time: u16 = 50971; // 0xC71B; DNG 1.2.0.0
pub const raw_image_digest: u16 = 50972; // 0xC71C; DNG 1.2.0.0
pub const original_raw_file_digest: u16 = 50973; // 0xC71D; DNG 1.2.0.0
pub const sub_tile_block_size: u16 = 50974; // 0xC71E; DNG 1.2.0.0
pub const row_interleave_factor: u16 = 50975; // 0xC71F; DNG 1.2.0.0
pub const profile_look_table_dims: u16 = 50981; // 0xC725; DNG 1.2.0.0
pub const profile_look_table_data: u16 = 50982; // 0xC726; DNG 1.2.0.0
pub const noise_profile: u16 = 51041; // 0xC761; DNG 1.3.0.0
pub const default_user_crop: u16 = 51125; // 0xC7B5; DNG 1.4.0.0
pub const default_black_render: u16 = 51110; // 0xC7A6; DNG 1.4.0.0
pub const baseline_exposure_offset: u16 = 51109; // 0xC7A5; DNG 1.4.0.0
pub const profile_look_table_encoding: u16 = 51108; // 0xC7A4; DNG 1.4.0.0
pub const profile_hue_sat_map_encoding: u16 = 51107; // 0xC7A3; DNG 1.4.0.0
pub const original_default_final_size: u16 = 51089; // 0xC791; DNG 1.4.0.0
pub const original_best_quality_final_size: u16 = 51090; // 0xC792; DNG 1.4.0.0
pub const original_default_crop_size: u16 = 51091; // 0xC793; DNG 1.4.0.0
pub const new_raw_image_digest: u16 = 51111; // 0xC7A7; DNG 1.4.0.0
pub const raw_to_preview_gain: u16 = 51112; // 0xC7A8; DNG 1.4.0.0
pub const depth_format: u16 = 51177; // 0xC7E9; DNG 1.5.0.0
pub const depth_near: u16 = 51178; // 0xC7EA; DNG 1.5.0.0
pub const depth_far: u16 = 51179; // 0xC7EB; DNG 1.5.0.0
pub const depth_units: u16 = 51180; // 0xC7EC; DNG 1.5.0.0
pub const depth_measure_type: u16 = 51181; // 0xC7ED; DNG 1.5.0.0
pub const enhance_params: u16 = 51182; // 0xC7EE; DNG 1.5.0.0
pub const profile_gain_table_map: u16 = 52525; // 0xCD2D; DNG 1.6.0.0
pub const semantic_name: u16 = 52526; // 0xCD2E; DNG 1.6.0.0
pub const semantic_instance_id: u16 = 52528; // 0xCD30; DNG 1.6.0.0
pub const mask_sub_area: u16 = 52536; // 0xCD38; DNG 1.6.0.0
pub const rgb_tables: u16 = 52543; // 0xCD3F; DNG 1.6.0.0
pub const calibration_illuminant_3: u16 = 52529; // 0xCD31; DNG 1.6.0.0
pub const color_matrix_3: u16 = 52531; // 0xCD33; DNG 1.6.0.0
pub const camera_calibration_3: u16 = 52530; // 0xCD32; DNG 1.6.0.0
pub const reduction_matrix_3: u16 = 52538; // 0xCD3A; DNG 1.6.0.0
pub const profile_hue_sat_map_data_3: u16 = 52537; // 0xCD39; DNG 1.6.0.0
pub const forward_matrix_3: u16 = 52532; // 0xCD34; DNG 1.6.0.0
pub const illuminant_data_1: u16 = 52533; // 0xCD35; DNG 1.6.0.0
pub const illuminant_data_2: u16 = 52534; // 0xCD36; DNG 1.6.0.0
pub const illuminant_data_3: u16 = 52535; // 0xCD37; DNG 1.6.0.0
pub const photometric_linear_raw: u16 = 34892;     // DNG Chapter 3
pub const photometric_depth: u16 = 51177;          // DNG 1.5.0.0 depth map IFDs
pub const photometric_mask: u16 = 52527;           // DNG 1.6.0.0 semantic mask IFDs
pub const compression_dng_lossy_jpeg: u16 = 34892; // DNG 1.4.0.0
