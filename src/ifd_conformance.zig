//! Directory-level TIFF "must"s that decoding does not otherwise depend on.
//!
//! A violation here is corrupt, even when every sample still decodes
//! (validate's ruling, 2026-11-03: a proven violation is never a tolerated
//! deviation, however many readers accept it; tolerance belongs in the
//! decoder, not the verdict). Two checks:
//!
//! - Entries in strictly ascending tag order (TIFF 6.0 p. 15). A flipped
//!   bit in a tag ID usually shows up only here: the lost tag's default
//!   then stands in for its value.
//! - Each tag in `rules` has an allowed type, count and value set.
//!
//! Two boundaries from the same ruling. BYTE, SHORT and LONG are all
//! acceptable for any unsigned-integer field, scalar or array: "TIFF
//! readers should accept BYTE, SHORT, or LONG values for any unsigned
//! integer field", and "all fields are actually one-dimensional arrays"
//! (TIFF 6.0 p. 16; validate, corrected 2026-11-04). Each value must still
//! be in range, and a field defined as SHORT holds 16-bit values however
//! it is stored. Values from 32768 up to 65535 are reserved for private
//! use (TIFF 6.0 p. 8), so they are not violations. Tags without a rule,
//! including every private tag, are skipped.
//!
//! DNG rows (Digital Negative Specification 1.6.0.0) apply only when IFD 0
//! carries DNGVersion, then to every IFD of the file, and are gated by the
//! declared version (validate, 2026-11-04; docs/plan_context/dng-batch.md):
//! a row whose tag a later edition added applies only from that edition; a
//! closed value list applies only to a known version up to 1.6.0.0 (D1, D2);
//! a malformed DNGVersion leaves type and count rows only. DNG defines no
//! private value range, so DNG value lists check every value. Chapter 3
//! restrictions on existing TIFF tags are checked after the TIFF row.
//!
//! Pure: reads only the parsed `Ifd`, whose out-of-line values are already
//! cached.

const std = @import("std");
const parser = @import("tiffz-parser");
const ifd_mod = parser.ifd;
const header_mod = parser.header;
const tags = parser.tags;

const Endian = header_mod.Endian;
const Ifd = ifd_mod.Ifd;
const Entry = ifd_mod.Entry;
const FieldType = ifd_mod.FieldType;

/// Why a field is invalid. Wire values for the finding payload.
pub const Reason = enum(u16) {
    type = 1,
    count = 2,
    value = 3,
    /// SamplesPerPixel, as stored or as its default of 1, is not the color
    /// channels C the PhotometricInterpretation implies, and ExtraSamples is
    /// absent (TIFF 6.0 p. 32: it "must be present if there are extra
    /// samples"). A mismatch between fields, not an invalid value of the
    /// entry it is anchored on (validate, 2026-11-04). The payload carries
    /// a `ChannelMismatch`.
    channel_mismatch = 4,
};

/// What a `channel_mismatch` compared: the photometric, the SamplesPerPixel
/// used (stored, or the default 1 when absent, p. 39) and the channel counts
/// C the photometric allows (equal when it allows one).
pub const ChannelMismatch = struct {
    photometric: u16,
    samples: u16,
    samples_stored: bool,
    channels_a: u16,
    channels_b: u16,
};

pub const Fault = union(enum) {
    /// Entry `entry_index` does not have a larger tag than the entry before it.
    unsorted: struct { entry_index: u32, tag: u16, prev_tag: u16 },
    field_invalid: struct {
        entry_index: u32,
        tag: u16,
        reason: Reason,
        raw_type: u16,
        raw_count: u64,
        /// The value/offset slot read as an unsigned integer in the file's
        /// byte order: u32 for classic TIFF, u64 for BigTIFF.
        raw_slot: u64,
        /// Set for `Reason.channel_mismatch` only.
        channels: ?ChannelMismatch = null,
    },

    pub fn entryIndex(self: Fault) u32 {
        return switch (self) {
            .unsorted => |f| f.entry_index,
            .field_invalid => |f| f.entry_index,
        };
    }
};

/// The field type a rule's tag is defined with.
const Kind = enum {
    /// Defined as SHORT. Stored as BYTE, SHORT or LONG, scalar or array
    /// (TIFF 6.0 p. 16); every value must fit in 16 bits.
    unsigned_short,
    /// Defined as LONG, or as SHORT or LONG. Stored as BYTE, SHORT or LONG.
    unsigned_long,
    /// StripOffsets, StripByteCounts, TileOffsets and TileByteCounts: as
    /// `unsigned_long`, and in BigTIFF also LONG8 ("allowed to have the
    /// datatype TIFF_LONG8 in BigTIFF", BigTIFF design, libtiff docs).
    offsets_or_counts,
    /// RATIONAL only.
    rational,
    /// SRATIONAL only.
    srational,
    /// DOUBLE only (IEEE 754 binary64): GeoTIFF's model and parameter tags
    /// (OGC GeoTIFF 1.1 Requirements 5.1, 9.2, 10.2, 11.2). No value check.
    double,
    /// Defined as BYTE. Stored as BYTE, SHORT or LONG (TIFF 6.0 p. 16); every
    /// value must fit in 8 bits.
    unsigned_byte,
    /// ASCII only.
    ascii,
    /// "DWORD" (PageMaker 6.0 notes): a 32-bit integer of either sign, so
    /// BYTE, SHORT, LONG or SLONG; no value or sign check (validate,
    /// 2026-11-04).
    integer32,
    /// BYTE only: an opaque byte sequence, not an integer field.
    bytes,
    /// UNDEFINED only.
    undefined,
    /// Offsets of child IFDs: LONG or IFD (13), and in BigTIFF also IFD8
    /// (PageMaker 6.0 TIFF Technical Notes p. 4; BigTIFF design).
    ifd_offsets,
    /// FLOAT only (IEEE 754 binary32). DNG profile tables.
    float,
    /// DNG "SHORT or LONG or RATIONAL": BYTE, SHORT or LONG holding 32-bit
    /// values, or RATIONAL.
    long_or_rational,
    /// DNG "SHORT or RATIONAL": BYTE, SHORT or LONG holding 16-bit values,
    /// or RATIONAL.
    short_or_rational,
    /// DNG "ASCII or BYTE", "Null-terminated UTF-8 encoded Unicode string":
    /// the last byte is NUL and the bytes before it are valid UTF-8; the
    /// 7-bit rule does not apply, and inner NULs are not checked (D4).
    utf8_string,
};

const Count = enum {
    one,
    two,
    three,
    six,
    /// DateTime's "YYYY:MM:DD HH:MM:SS" plus its NUL.
    twenty,
    samples_per_pixel,
    /// {1 or 3} * 2**BitsPerSample.
    transfer_function,
    /// 2**BitsPerSample.
    per_level,
    /// 3 * 2**BitsPerSample.
    color_map,
    /// 2, or 2 * SamplesPerPixel.
    dot_range,
    /// At least one.
    any,
    four,
    /// 2 * SamplesPerPixel.
    two_per_sample,
    /// One per strip: the count of StripOffsets, when present.
    strips,
    /// Any count, zero included ("N = number of child IFDs").
    zero_or_more,
    /// Exactly 16 (ModelTransformationTag's 4x4 matrix).
    sixteen,
    /// Six per tiepoint, at least one tiepoint.
    multiple_of_six,
    /// At least the four-value GeoKeyDirectory header.
    at_least_four,
    /// A positive multiple of 4 (DNG MaskedAreas rectangles).
    multiple_of_four,
    /// Even and at least 2 (DNG NoiseProfile pairs; the exact count needs
    /// ColorPlanes, a later batch).
    even_at_least_two,
    /// Even and at least 4 (DNG ProfileToneCurve: first and last samples).
    even_at_least_four,
    /// BlackLevelRepeatRows * BlackLevelRepeatCols * SamplesPerPixel (DNG
    /// BlackLevel; the repeat dimensions default to 1, 1).
    black_level,
    /// The ActiveArea width, or ImageWidth when ActiveArea is absent.
    active_area_width,
    /// The ActiveArea length, or ImageLength when ActiveArea is absent.
    active_area_length,
    /// HueDivisions * SaturationDivisions * ValueDivisions * 3, from
    /// ProfileHueSatMapDims.
    hue_sat_map,
    /// As `hue_sat_map`, from ProfileLookTableDims.
    look_table,
};

/// A constraint beyond type, count and value set.
const Extra = enum {
    /// Every value is a multiple of 16.
    multiple_of_16,
    /// Two values, the second (vertical) at most the first (horizontal).
    vertical_at_most_horizontal,
    /// "YYYY:MM:DD HH:MM:SS" followed by NUL.
    date_time,
    /// RowsPerStrip of a multi-strip YCbCr image is a multiple of
    /// YCbCrSubsampleVert (default 2).
    rows_multiple_of_vertical_subsampling,
    /// ImageLayer: [0] is 1, 2 or 3; [1], the imaging order, starts at 1
    /// (RFC 3949 p. 68).
    image_layer,
    /// StripRowCounts: "Only one of the two fields, StripRowCounts and
    /// RowsPerStrip, may be used in an IFD" (RFC 3949 p. 68).
    not_with_rows_per_strip,
    /// With Compression 7, PhotometricInterpretation "shall not be 3 (palette
    /// color) nor 4 (transparency mask)" (TIFF Technical Note 2).
    not_palette_or_mask_with_jpeg,
    /// SamplesPerPixel = C + m, with C the color channels the
    /// PhotometricInterpretation implies and m the ExtraSamples count, 0 when
    /// absent (TIFF 6.0 p. 32; validate's table, 2026-11-04). On ExtraSamples,
    /// a mismatch is a count fault. On SamplesPerPixel, it is a value fault,
    /// reported only when ExtraSamples is absent.
    channels_plus_extra_samples,
    /// As `channels_plus_extra_samples`, on PhotometricInterpretation, when
    /// neither SamplesPerPixel nor ExtraSamples is present: the default of
    /// one sample must suit the photometric.
    channels_without_samples_per_pixel,
    /// PhotometricInterpretation 3: "ColorMap must be present" (TIFF 6.0 p. 37).
    palette_has_color_map,
    /// BitsPerSample of a transparency mask (PhotometricInterpretation 4):
    /// "SamplesPerPixel and BitsPerSample must be 1" (TIFF 6.0 p. 37).
    one_bit_for_transparency_mask,
    /// DNG DefaultUserCrop: "0 <= Top < Bottom <= 1.0, 0 <= Left < Right <= 1.0".
    user_crop,
    /// DNG NoiseProfile: "each S term must be positive", "each O term must be
    /// non-negative".
    noise_profile_signs,
    /// DNG ProfileToneCurve: "The first sample is required to be (0.0, 0.0),
    /// and the last sample is required to be (1.0, 1.0)."
    tone_curve_endpoints,
    /// DNG EnhanceParams: "required to be non-null".
    non_empty,
    /// DNG MaskSubArea (T_crop, L_crop, W_full, H_full): "the tag is invalid"
    /// when out of bounds. The printed conditions pair the top offset with
    /// ImageWidth, which looks transposed, so a fault needs both the literal
    /// and the dimensionally consistent reading to fail (validate, 2026-11-04).
    mask_sub_area_bounds,
    /// DNG PreviewDateTime: "encoded using ISO 8601 format" (validate,
    /// 2026-11-04: definitional, so a fault).
    iso8601,
};

const Rule = struct {
    tag: u16,
    kind: Kind,
    count: Count,
    /// Inclusive public-range value ranges, or null when unconstrained.
    values: ?[]const [2]u16 = null,
    extras: []const Extra = &.{},
    /// DNG rows only: the packed DNGVersion (major << 24 | minor << 16 | ...)
    /// of the edition that added the tag. Null for every non-DNG row.
    since: ?u32 = null,
    /// Where the rule comes from, so an omission is auditable.
    citation: []const u8,
};

/// One row per constrained tag. Growing this table to every tag a claimed
/// specification constrains is tracked in PLAN.md.
/// Value sets for Compression, PhotometricInterpretation, Predictor and
/// NewSubfileType wait for the batch that claims their other defining
/// specifications; see `pending`.
pub const rules = [_]Rule{
    .{ .tag = tags.new_subfile_type, .kind = .unsigned_long, .count = .one, .citation = "TIFF 6.0 p. 36" },
    .{ .tag = tags.subfile_type, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 3 }}, .citation = "TIFF 6.0 pp. 40-41" },
    .{ .tag = tags.image_width, .kind = .unsigned_long, .count = .one, .citation = "TIFF 6.0 p. 34 (not constrained by YCbCr subsampling: TIFF Technical Note 2, Section 21)" },
    .{ .tag = tags.image_length, .kind = .unsigned_long, .count = .one, .citation = "TIFF 6.0 p. 34 (not constrained by YCbCr subsampling: TIFF Technical Note 2, Section 21)" },
    .{ .tag = tags.bits_per_sample, .kind = .unsigned_short, .count = .samples_per_pixel, .extras = &.{.one_bit_for_transparency_mask}, .citation = "TIFF 6.0 pp. 29, 37" },
    .{ .tag = tags.compression, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 10 }}, .citation = "TIFF 6.0 pp. 30, 49, 104 (1-7); Photoshop TIFF Technical Notes (8); RFC 3949 pp. 44, 56 (9, 10)" },
    .{ .tag = tags.photometric, .kind = .unsigned_short, .count = .one, .values = &.{ .{ 0, 6 }, .{ 8, 10 } }, .extras = &.{ .not_palette_or_mask_with_jpeg, .channels_without_samples_per_pixel, .palette_has_color_map }, .citation = "TIFF 6.0 p. 37 (0-6, 8); Photoshop TIFF Technical Notes (9); RFC 3949 p. 48 (10); TIFF Technical Note 2 (not 3 or 4 with JPEG); TIFF 6.0 p. 32 (channels, when SamplesPerPixel is absent); TIFF 6.0 p. 37 (palette needs ColorMap)" },
    .{ .tag = tags.threshholding, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 3 }}, .citation = "TIFF 6.0 p. 41" },
    .{ .tag = tags.cell_width, .kind = .unsigned_short, .count = .one, .citation = "TIFF 6.0 p. 29" },
    .{ .tag = tags.cell_length, .kind = .unsigned_short, .count = .one, .citation = "TIFF 6.0 p. 29" },
    .{ .tag = tags.fill_order, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 2 }}, .citation = "TIFF 6.0 p. 32" },
    .{ .tag = tags.document_name, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 55" },
    .{ .tag = tags.image_description, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 34" },
    .{ .tag = tags.make, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 35" },
    .{ .tag = tags.model, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 35" },
    .{ .tag = tags.strip_offsets, .kind = .offsets_or_counts, .count = .any, .citation = "TIFF 6.0 p. 40; BigTIFF" },
    .{ .tag = tags.orientation, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 8 }}, .citation = "TIFF 6.0 pp. 36-37" },
    .{ .tag = tags.samples_per_pixel, .kind = .unsigned_short, .count = .one, .extras = &.{.channels_plus_extra_samples}, .citation = "TIFF 6.0 pp. 32, 39" },
    .{ .tag = tags.rows_per_strip, .kind = .unsigned_long, .count = .one, .extras = &.{.rows_multiple_of_vertical_subsampling}, .citation = "TIFF 6.0 pp. 39, 92; TIFF Technical Note 2, Section 21" },
    .{ .tag = tags.strip_byte_counts, .kind = .offsets_or_counts, .count = .any, .citation = "TIFF 6.0 p. 40; BigTIFF" },
    .{ .tag = tags.min_sample_value, .kind = .unsigned_short, .count = .samples_per_pixel, .citation = "TIFF 6.0 p. 35" },
    .{ .tag = tags.max_sample_value, .kind = .unsigned_short, .count = .samples_per_pixel, .citation = "TIFF 6.0 p. 35" },
    .{ .tag = tags.x_resolution, .kind = .rational, .count = .one, .citation = "TIFF 6.0 p. 41" },
    .{ .tag = tags.y_resolution, .kind = .rational, .count = .one, .citation = "TIFF 6.0 p. 41" },
    .{ .tag = tags.planar_configuration, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 2 }}, .citation = "TIFF 6.0 p. 38" },
    .{ .tag = tags.page_name, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 55" },
    .{ .tag = tags.x_position, .kind = .rational, .count = .one, .citation = "TIFF 6.0 p. 55" },
    .{ .tag = tags.y_position, .kind = .rational, .count = .one, .citation = "TIFF 6.0 p. 56" },
    .{ .tag = tags.free_offsets, .kind = .unsigned_long, .count = .any, .citation = "TIFF 6.0 p. 33" },
    .{ .tag = tags.free_byte_counts, .kind = .unsigned_long, .count = .any, .citation = "TIFF 6.0 p. 33" },
    .{ .tag = tags.gray_response_unit, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 5 }}, .citation = "TIFF 6.0 pp. 33-34" },
    .{ .tag = tags.gray_response_curve, .kind = .unsigned_short, .count = .per_level, .citation = "TIFF 6.0 p. 33" },
    .{ .tag = tags.t4_options, .kind = .unsigned_long, .count = .one, .citation = "TIFF 6.0 p. 51" },
    .{ .tag = tags.t6_options, .kind = .unsigned_long, .count = .one, .citation = "TIFF 6.0 p. 52" },
    .{ .tag = tags.resolution_unit, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 3 }}, .citation = "TIFF 6.0 p. 38" },
    .{ .tag = tags.page_number, .kind = .unsigned_short, .count = .two, .citation = "TIFF 6.0 p. 55" },
    .{ .tag = tags.transfer_function, .kind = .unsigned_short, .count = .transfer_function, .citation = "TIFF 6.0 p. 84" },
    .{ .tag = tags.software, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 39" },
    .{ .tag = tags.date_time, .kind = .ascii, .count = .twenty, .extras = &.{.date_time}, .citation = "TIFF 6.0 pp. 15-16, 31" },
    .{ .tag = tags.artist, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 28" },
    .{ .tag = tags.host_computer, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 34" },
    .{ .tag = tags.predictor, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 3 }}, .citation = "TIFF 6.0 p. 64; Adobe Photoshop TIFF Technical Note 3 (2005)" },
    .{ .tag = tags.white_point, .kind = .rational, .count = .two, .citation = "TIFF 6.0 p. 83" },
    .{ .tag = tags.primary_chromaticities, .kind = .rational, .count = .six, .citation = "TIFF 6.0 p. 83" },
    .{ .tag = tags.colormap, .kind = .unsigned_short, .count = .color_map, .citation = "TIFF 6.0 p. 29" },
    .{ .tag = tags.halftone_hints, .kind = .unsigned_short, .count = .two, .citation = "TIFF 6.0 p. 72" },
    .{ .tag = tags.tile_width, .kind = .unsigned_long, .count = .one, .extras = &.{.multiple_of_16}, .citation = "TIFF 6.0 p. 67 (a multiple of 16 is a multiple of any subsampling factor, as TIFF Technical Note 2 Section 21 requires)" },
    .{ .tag = tags.tile_length, .kind = .unsigned_long, .count = .one, .extras = &.{.multiple_of_16}, .citation = "TIFF 6.0 pp. 67-68 (a multiple of 16 is a multiple of any subsampling factor, as TIFF Technical Note 2 Section 21 requires)" },
    .{ .tag = tags.tile_offsets, .kind = .offsets_or_counts, .count = .any, .citation = "TIFF 6.0 p. 68; BigTIFF" },
    .{ .tag = tags.tile_byte_counts, .kind = .offsets_or_counts, .count = .any, .citation = "TIFF 6.0 p. 68; BigTIFF" },
    .{ .tag = tags.bad_fax_lines, .kind = .unsigned_long, .count = .one, .citation = "RFC 3949 p. 33 (RFC 2301 agrees)" },
    .{ .tag = tags.clean_fax_data, .kind = .unsigned_short, .count = .one, .values = &.{.{ 0, 2 }}, .citation = "RFC 3949 p. 33 (RFC 2301 agrees)" },
    .{ .tag = tags.consecutive_bad_fax_lines, .kind = .unsigned_long, .count = .one, .citation = "RFC 3949 p. 34 (RFC 2301 agrees)" },
    .{ .tag = tags.sub_ifds, .kind = .ifd_offsets, .count = .zero_or_more, .citation = "PageMaker 6.0 TIFF Technical Notes p. 4; BigTIFF" },
    .{ .tag = tags.ink_set, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 2 }}, .citation = "TIFF 6.0 p. 70" },
    .{ .tag = tags.ink_names, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 70" },
    .{ .tag = tags.number_of_inks, .kind = .unsigned_short, .count = .one, .citation = "TIFF 6.0 p. 70" },
    .{ .tag = tags.dot_range, .kind = .unsigned_short, .count = .dot_range, .citation = "TIFF 6.0 p. 71" },
    .{ .tag = tags.target_printer, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 71" },
    .{ .tag = tags.extra_samples, .kind = .unsigned_short, .count = .any, .values = &.{.{ 0, 2 }}, .extras = &.{.channels_plus_extra_samples}, .citation = "TIFF 6.0 pp. 31-32, 77" },
    .{ .tag = tags.sample_format, .kind = .unsigned_short, .count = .samples_per_pixel, .values = &.{.{ 1, 4 }}, .citation = "TIFF 6.0 p. 80" },
    .{ .tag = tags.transfer_range, .kind = .unsigned_short, .count = .six, .citation = "TIFF 6.0 p. 86" },
    .{ .tag = tags.clip_path, .kind = .bytes, .count = .any, .citation = "PageMaker 6.0 TIFF Technical Notes p. 6" },
    .{ .tag = tags.x_clip_path_units, .kind = .integer32, .count = .one, .citation = "PageMaker 6.0 TIFF Technical Notes p. 9 (\"Type = DWORD\"; libtiff registers LONG)" },
    .{ .tag = tags.y_clip_path_units, .kind = .integer32, .count = .one, .citation = "PageMaker 6.0 TIFF Technical Notes p. 10 (\"Type = DWORD\"; libtiff registers LONG)" },
    .{ .tag = tags.indexed, .kind = .unsigned_short, .count = .one, .values = &.{.{ 0, 1 }}, .citation = "PageMaker 6.0 TIFF Technical Notes p. 11" },
    .{ .tag = tags.jpeg_tables, .kind = .undefined, .count = .any, .citation = "TIFF Technical Note 2" },
    .{ .tag = tags.opi_proxy, .kind = .unsigned_short, .count = .one, .values = &.{.{ 0, 1 }}, .citation = "PageMaker 6.0 TIFF Technical Notes p. 15" },
    .{ .tag = tags.global_parameters_ifd, .kind = .ifd_offsets, .count = .one, .citation = "RFC 3949 p. 18 (IFD or LONG; RFC 2301 says IFD)" },
    .{ .tag = tags.profile_type, .kind = .unsigned_long, .count = .one, .values = &.{.{ 0, 1 }}, .citation = "RFC 3949 p. 19 (RFC 2301 agrees)" },
    .{ .tag = tags.fax_profile, .kind = .unsigned_byte, .count = .one, .values = &.{.{ 0, 6 }}, .citation = "RFC 3949 p. 19 (RFC 2301 agrees)" },
    .{ .tag = tags.coding_methods, .kind = .unsigned_long, .count = .one, .citation = "RFC 3949 p. 19 (bits 7-31 reserved, not checked; RFC 2301 agrees)" },
    .{ .tag = tags.version_year, .kind = .bytes, .count = .four, .citation = "RFC 3949 p. 20 (RFC 2301 agrees)" },
    .{ .tag = tags.mode_number, .kind = .unsigned_byte, .count = .one, .citation = "RFC 3949 p. 20 (RFC 2301 agrees)" },
    .{ .tag = tags.decode, .kind = .srational, .count = .two_per_sample, .citation = "RFC 3949 p. 50 (RFC 2301 agrees)" },
    .{ .tag = tags.image_base_color, .kind = .unsigned_short, .count = .samples_per_pixel, .citation = "RFC 3949 p. 67 (RFC 2301 calls it DefaultImageColor)" },
    .{ .tag = tags.t82_options, .kind = .unsigned_long, .count = .one, .citation = "RFC 3949 p. 44 (not in RFC 2301)" },
    .{ .tag = tags.jpeg_proc, .kind = .unsigned_short, .count = .one, .values = &.{ .{ 1, 1 }, .{ 14, 14 } }, .citation = "TIFF 6.0 p. 104" },
    .{ .tag = tags.jpeg_interchange_format, .kind = .unsigned_long, .count = .one, .citation = "TIFF 6.0 p. 105" },
    .{ .tag = tags.jpeg_interchange_format_length, .kind = .unsigned_long, .count = .one, .citation = "TIFF 6.0 p. 105" },
    .{ .tag = tags.jpeg_restart_interval, .kind = .unsigned_short, .count = .one, .citation = "TIFF 6.0 p. 105" },
    .{ .tag = tags.jpeg_lossless_predictors, .kind = .unsigned_short, .count = .samples_per_pixel, .values = &.{.{ 1, 7 }}, .citation = "TIFF 6.0 p. 106" },
    .{ .tag = tags.jpeg_point_transforms, .kind = .unsigned_short, .count = .samples_per_pixel, .citation = "TIFF 6.0 p. 106" },
    .{ .tag = tags.jpeg_q_tables, .kind = .unsigned_long, .count = .samples_per_pixel, .citation = "TIFF 6.0 p. 107" },
    .{ .tag = tags.jpeg_dc_tables, .kind = .unsigned_long, .count = .samples_per_pixel, .citation = "TIFF 6.0 p. 107" },
    .{ .tag = tags.jpeg_ac_tables, .kind = .unsigned_long, .count = .samples_per_pixel, .citation = "TIFF 6.0 p. 107" },
    .{ .tag = tags.ycbcr_coefficients, .kind = .rational, .count = .three, .citation = "TIFF 6.0 p. 90" },
    .{ .tag = tags.ycbcr_subsampling, .kind = .unsigned_short, .count = .two, .values = &.{ .{ 1, 2 }, .{ 4, 4 } }, .extras = &.{.vertical_at_most_horizontal}, .citation = "TIFF 6.0 pp. 91-92" },
    .{ .tag = tags.ycbcr_positioning, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 2 }}, .citation = "TIFF 6.0 p. 92" },
    .{ .tag = tags.reference_black_white, .kind = .rational, .count = .six, .citation = "TIFF 6.0 p. 86" },
    .{ .tag = tags.strip_row_counts, .kind = .unsigned_long, .count = .strips, .extras = &.{.not_with_rows_per_strip}, .citation = "RFC 3949 p. 68 (RFC 2301 agrees)" },
    .{ .tag = tags.image_id, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16; PageMaker 6.0 TIFF Technical Notes p. 15" },
    .{ .tag = tags.copyright, .kind = .ascii, .count = .any, .citation = "TIFF 6.0 pp. 15-16, 31" },
    .{ .tag = tags.model_pixel_scale, .kind = .double, .count = .three, .citation = "OGC GeoTIFF 1.1 (19-008r4) Requirements 10.2, 10.3" },
    .{ .tag = tags.model_tiepoint, .kind = .double, .count = .multiple_of_six, .citation = "OGC GeoTIFF 1.1 (19-008r4) Requirements 9.2, 9.3" },
    .{ .tag = tags.model_transformation, .kind = .double, .count = .sixteen, .citation = "OGC GeoTIFF 1.1 (19-008r4) Requirements 11.2, 11.3" },
    .{ .tag = tags.image_layer, .kind = .unsigned_long, .count = .two, .extras = &.{.image_layer}, .citation = "RFC 3949 p. 68 (RFC 2301: SHORT or LONG, which p. 16 widening also allows)" },
    .{ .tag = tags.geo_key_directory, .kind = .unsigned_short, .count = .at_least_four, .citation = "OGC GeoTIFF 1.1 (19-008r4) Requirements 2.2, 2.3 (the exact count waits for the GeoKeyDirectory batch)" },
    .{ .tag = tags.geo_double_params, .kind = .double, .count = .any, .citation = "OGC GeoTIFF 1.1 (19-008r4) Requirements 5.1, 5.2" },
    .{ .tag = tags.geo_ascii_params, .kind = .ascii, .count = .any, .citation = "OGC GeoTIFF 1.1 (19-008r4) Requirement 6.5; TIFF 6.0 p. 15" },
    .{ .tag = tags.image_source_data, .kind = .undefined, .count = .any, .citation = "Adobe Photoshop TIFF Technical Notes (2002)" },
    // DNG 1.6.0.0, Chapter 4. Type and count come from each definition block,
    // normative per DNGBackwardVersion (p. 21): "readers should, for all tags,
    // check the types, counts, and values" (validate D3, 2026-11-04).
    .{ .tag = tags.dng_version, .kind = .unsigned_byte, .count = .four, .since = 0x01000000, .citation = "DNG 1.6.0.0, DNGVersion (BYTE)" },
    .{ .tag = tags.dng_backward_version, .kind = .unsigned_byte, .count = .four, .since = 0x01000000, .citation = "DNG 1.6.0.0, DNGBackwardVersion (BYTE)" },
    .{ .tag = tags.unique_camera_model, .kind = .ascii, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, UniqueCameraModel (ASCII)" },
    .{ .tag = tags.localized_camera_model, .kind = .utf8_string, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, LocalizedCameraModel (ASCII or BYTE)" },
    .{ .tag = tags.cfa_plane_color, .kind = .unsigned_byte, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, CFAPlaneColor (BYTE)" },
    .{ .tag = tags.cfa_layout, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 9 }}, .since = 0x01000000, .citation = "DNG 1.6.0.0, CFALayout (SHORT)" },
    .{ .tag = tags.linearization_table, .kind = .unsigned_short, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, LinearizationTable (SHORT)" },
    .{ .tag = tags.black_level_repeat_dim, .kind = .unsigned_short, .count = .two, .since = 0x01000000, .citation = "DNG 1.6.0.0, BlackLevelRepeatDim (SHORT)" },
    .{ .tag = tags.black_level, .kind = .long_or_rational, .count = .black_level, .since = 0x01000000, .citation = "DNG 1.6.0.0, BlackLevel (SHORT or LONG or RATIONAL)" },
    .{ .tag = tags.black_level_delta_h, .kind = .srational, .count = .active_area_width, .since = 0x01000000, .citation = "DNG 1.6.0.0, BlackLevelDeltaH (SRATIONAL)" },
    .{ .tag = tags.black_level_delta_v, .kind = .srational, .count = .active_area_length, .since = 0x01000000, .citation = "DNG 1.6.0.0, BlackLevelDeltaV (SRATIONAL)" },
    .{ .tag = tags.white_level, .kind = .unsigned_long, .count = .samples_per_pixel, .since = 0x01000000, .citation = "DNG 1.6.0.0, WhiteLevel (SHORT or LONG)" },
    .{ .tag = tags.default_scale, .kind = .rational, .count = .two, .since = 0x01000000, .citation = "DNG 1.6.0.0, DefaultScale (RATIONAL)" },
    .{ .tag = tags.default_crop_origin, .kind = .long_or_rational, .count = .two, .since = 0x01000000, .citation = "DNG 1.6.0.0, DefaultCropOrigin (SHORT or LONG or RATIONAL)" },
    .{ .tag = tags.default_crop_size, .kind = .long_or_rational, .count = .two, .since = 0x01000000, .citation = "DNG 1.6.0.0, DefaultCropSize (SHORT or LONG or RATIONAL)" },
    .{ .tag = tags.color_matrix_1, .kind = .srational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, ColorMatrix1 (SRATIONAL)" },
    .{ .tag = tags.color_matrix_2, .kind = .srational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, ColorMatrix2 (SRATIONAL)" },
    .{ .tag = tags.camera_calibration_1, .kind = .srational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, CameraCalibration1 (SRATIONAL)" },
    .{ .tag = tags.camera_calibration_2, .kind = .srational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, CameraCalibration2 (SRATIONAL)" },
    .{ .tag = tags.reduction_matrix_1, .kind = .srational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, ReductionMatrix1 (SRATIONAL)" },
    .{ .tag = tags.reduction_matrix_2, .kind = .srational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, ReductionMatrix2 (SRATIONAL)" },
    .{ .tag = tags.analog_balance, .kind = .rational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, AnalogBalance (RATIONAL)" },
    .{ .tag = tags.as_shot_neutral, .kind = .short_or_rational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, AsShotNeutral (SHORT or RATIONAL)" },
    .{ .tag = tags.as_shot_white_xy, .kind = .rational, .count = .two, .since = 0x01000000, .citation = "DNG 1.6.0.0, AsShotWhiteXY (RATIONAL)" },
    .{ .tag = tags.baseline_exposure, .kind = .srational, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, BaselineExposure (SRATIONAL)" },
    .{ .tag = tags.baseline_noise, .kind = .rational, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, BaselineNoise (RATIONAL)" },
    .{ .tag = tags.baseline_sharpness, .kind = .rational, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, BaselineSharpness (RATIONAL)" },
    .{ .tag = tags.bayer_green_split, .kind = .unsigned_long, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, BayerGreenSplit (LONG)" },
    .{ .tag = tags.linear_response_limit, .kind = .rational, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, LinearResponseLimit (RATIONAL)" },
    .{ .tag = tags.camera_serial_number, .kind = .ascii, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, CameraSerialNumber (ASCII)" },
    .{ .tag = tags.lens_info, .kind = .rational, .count = .four, .since = 0x01000000, .citation = "DNG 1.6.0.0, LensInfo (RATIONAL)" },
    .{ .tag = tags.chroma_blur_radius, .kind = .rational, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, ChromaBlurRadius (RATIONAL)" },
    .{ .tag = tags.anti_alias_strength, .kind = .rational, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, AntiAliasStrength (RATIONAL)" },
    .{ .tag = tags.shadow_scale, .kind = .rational, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, ShadowScale (RATIONAL)" },
    .{ .tag = tags.dng_private_data, .kind = .bytes, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, DNGPrivateData (BYTE)" },
    .{ .tag = tags.maker_note_safety, .kind = .unsigned_short, .count = .one, .values = &.{.{ 0, 1 }}, .since = 0x01000000, .citation = "DNG 1.6.0.0, MakerNoteSafety (SHORT)" },
    .{ .tag = tags.calibration_illuminant_1, .kind = .unsigned_short, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, CalibrationIlluminant1 (SHORT)" },
    .{ .tag = tags.calibration_illuminant_2, .kind = .unsigned_short, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, CalibrationIlluminant2 (SHORT)" },
    .{ .tag = tags.best_quality_scale, .kind = .rational, .count = .one, .since = 0x01000000, .citation = "DNG 1.6.0.0, BestQualityScale (RATIONAL)" },
    .{ .tag = tags.raw_data_unique_id, .kind = .bytes, .count = .sixteen, .since = 0x01000000, .citation = "DNG 1.6.0.0, RawDataUniqueID (BYTE)" },
    .{ .tag = tags.original_raw_file_name, .kind = .utf8_string, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, OriginalRawFileName (ASCII or BYTE)" },
    .{ .tag = tags.original_raw_file_data, .kind = .undefined, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, OriginalRawFileData (UNDEFINED)" },
    .{ .tag = tags.active_area, .kind = .unsigned_long, .count = .four, .since = 0x01000000, .citation = "DNG 1.6.0.0, ActiveArea (SHORT or LONG)" },
    .{ .tag = tags.masked_areas, .kind = .unsigned_long, .count = .multiple_of_four, .since = 0x01000000, .citation = "DNG 1.6.0.0, MaskedAreas (SHORT or LONG)" },
    .{ .tag = tags.as_shot_icc_profile, .kind = .undefined, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, AsShotICCProfile (UNDEFINED)" },
    .{ .tag = tags.as_shot_pre_profile_matrix, .kind = .srational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, AsShotPreProfileMatrix (SRATIONAL)" },
    .{ .tag = tags.current_icc_profile, .kind = .undefined, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, CurrentICCProfile (UNDEFINED)" },
    .{ .tag = tags.current_pre_profile_matrix, .kind = .srational, .count = .any, .since = 0x01000000, .citation = "DNG 1.6.0.0, CurrentPreProfileMatrix (SRATIONAL)" },
    .{ .tag = tags.colorimetric_reference, .kind = .unsigned_short, .count = .one, .values = &.{.{ 0, 1 }}, .since = 0x01020000, .citation = "DNG 1.6.0.0, ColorimetricReference (SHORT)" },
    .{ .tag = tags.camera_calibration_signature, .kind = .utf8_string, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, CameraCalibrationSignature (ASCII or BYTE)" },
    .{ .tag = tags.profile_calibration_signature, .kind = .utf8_string, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileCalibrationSignature (ASCII or BYTE)" },
    .{ .tag = tags.extra_camera_profiles, .kind = .ifd_offsets, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, ExtraCameraProfiles (LONG)" },
    .{ .tag = tags.as_shot_profile_name, .kind = .utf8_string, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, AsShotProfileName (ASCII or BYTE)" },
    .{ .tag = tags.noise_reduction_applied, .kind = .rational, .count = .one, .since = 0x01020000, .citation = "DNG 1.6.0.0, NoiseReductionApplied (RATIONAL)" },
    .{ .tag = tags.profile_name, .kind = .utf8_string, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileName (ASCII or BYTE)" },
    .{ .tag = tags.profile_hue_sat_map_dims, .kind = .unsigned_long, .count = .three, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileHueSatMapDims (LONG)" },
    .{ .tag = tags.profile_hue_sat_map_data_1, .kind = .float, .count = .hue_sat_map, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileHueSatMapData1 (FLOAT)" },
    .{ .tag = tags.profile_hue_sat_map_data_2, .kind = .float, .count = .hue_sat_map, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileHueSatMapData2 (FLOAT)" },
    .{ .tag = tags.profile_tone_curve, .kind = .float, .count = .even_at_least_four, .extras = &.{.tone_curve_endpoints}, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileToneCurve (FLOAT)" },
    .{ .tag = tags.profile_embed_policy, .kind = .unsigned_long, .count = .one, .values = &.{.{ 0, 3 }}, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileEmbedPolicy (LONG)" },
    .{ .tag = tags.profile_copyright, .kind = .utf8_string, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileCopyright (ASCII or BYTE)" },
    .{ .tag = tags.forward_matrix_1, .kind = .srational, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, ForwardMatrix1 (SRATIONAL)" },
    .{ .tag = tags.forward_matrix_2, .kind = .srational, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, ForwardMatrix2 (SRATIONAL)" },
    .{ .tag = tags.preview_application_name, .kind = .utf8_string, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, PreviewApplicationName (ASCII or BYTE)" },
    .{ .tag = tags.preview_application_version, .kind = .utf8_string, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, PreviewApplicationVersion (ASCII or BYTE)" },
    .{ .tag = tags.preview_settings_name, .kind = .utf8_string, .count = .any, .since = 0x01020000, .citation = "DNG 1.6.0.0, PreviewSettingsName (ASCII or BYTE)" },
    .{ .tag = tags.preview_settings_digest, .kind = .bytes, .count = .sixteen, .since = 0x01020000, .citation = "DNG 1.6.0.0, PreviewSettingsDigest (BYTE)" },
    .{ .tag = tags.preview_color_space, .kind = .unsigned_long, .count = .one, .since = 0x01020000, .citation = "DNG 1.6.0.0, PreviewColorSpace (LONG)" },
    .{ .tag = tags.preview_date_time, .kind = .ascii, .count = .any, .extras = &.{.iso8601}, .since = 0x01020000, .citation = "DNG 1.6.0.0, PreviewDateTime (ASCII)" },
    .{ .tag = tags.raw_image_digest, .kind = .bytes, .count = .sixteen, .since = 0x01020000, .citation = "DNG 1.6.0.0, RawImageDigest (BYTE)" },
    .{ .tag = tags.original_raw_file_digest, .kind = .bytes, .count = .sixteen, .since = 0x01020000, .citation = "DNG 1.6.0.0, OriginalRawFileDigest (BYTE)" },
    .{ .tag = tags.sub_tile_block_size, .kind = .unsigned_long, .count = .two, .since = 0x01020000, .citation = "DNG 1.6.0.0, SubTileBlockSize (SHORT or LONG)" },
    .{ .tag = tags.row_interleave_factor, .kind = .unsigned_long, .count = .one, .since = 0x01020000, .citation = "DNG 1.6.0.0, RowInterleaveFactor (SHORT or LONG)" },
    .{ .tag = tags.profile_look_table_dims, .kind = .unsigned_long, .count = .three, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileLookTableDims (LONG)" },
    .{ .tag = tags.profile_look_table_data, .kind = .float, .count = .look_table, .since = 0x01020000, .citation = "DNG 1.6.0.0, ProfileLookTableData (FLOAT)" },
    .{ .tag = tags.opcode_list_1, .kind = .undefined, .count = .any, .since = 0x01030000, .citation = "DNG 1.6.0.0, OpcodeList1 (UNDEFINED)" },
    .{ .tag = tags.opcode_list_2, .kind = .undefined, .count = .any, .since = 0x01030000, .citation = "DNG 1.6.0.0, OpcodeList2 (UNDEFINED)" },
    .{ .tag = tags.opcode_list_3, .kind = .undefined, .count = .any, .since = 0x01030000, .citation = "DNG 1.6.0.0, OpcodeList3 (UNDEFINED)" },
    .{ .tag = tags.noise_profile, .kind = .double, .count = .even_at_least_two, .extras = &.{.noise_profile_signs}, .since = 0x01030000, .citation = "DNG 1.6.0.0, NoiseProfile (DOUBLE)" },
    .{ .tag = tags.original_default_final_size, .kind = .unsigned_long, .count = .two, .since = 0x01040000, .citation = "DNG 1.6.0.0, OriginalDefaultFinalSize (SHORT or LONG)" },
    .{ .tag = tags.original_best_quality_final_size, .kind = .unsigned_long, .count = .two, .since = 0x01040000, .citation = "DNG 1.6.0.0, OriginalBestQualityFinalSize (SHORT or LONG)" },
    .{ .tag = tags.original_default_crop_size, .kind = .long_or_rational, .count = .two, .since = 0x01040000, .citation = "DNG 1.6.0.0, OriginalDefaultCropSize (SHORT or LONG or RATIONAL)" },
    .{ .tag = tags.profile_hue_sat_map_encoding, .kind = .unsigned_long, .count = .one, .values = &.{.{ 0, 1 }}, .since = 0x01040000, .citation = "DNG 1.6.0.0, ProfileHueSatMapEncoding (LONG)" },
    .{ .tag = tags.profile_look_table_encoding, .kind = .unsigned_long, .count = .one, .values = &.{.{ 0, 1 }}, .since = 0x01040000, .citation = "DNG 1.6.0.0, ProfileLookTableEncoding (LONG)" },
    .{ .tag = tags.baseline_exposure_offset, .kind = .rational, .count = .one, .since = 0x01040000, .citation = "DNG 1.6.0.0, BaselineExposureOffset (RATIONAL)" },
    .{ .tag = tags.default_black_render, .kind = .unsigned_long, .count = .one, .values = &.{.{ 0, 1 }}, .since = 0x01040000, .citation = "DNG 1.6.0.0, DefaultBlackRender (LONG)" },
    .{ .tag = tags.new_raw_image_digest, .kind = .bytes, .count = .sixteen, .since = 0x01040000, .citation = "DNG 1.6.0.0, NewRawImageDigest (BYTE)" },
    .{ .tag = tags.raw_to_preview_gain, .kind = .double, .count = .one, .since = 0x01040000, .citation = "DNG 1.6.0.0, RawToPreviewGain (DOUBLE)" },
    .{ .tag = tags.default_user_crop, .kind = .rational, .count = .four, .extras = &.{.user_crop}, .since = 0x01040000, .citation = "DNG 1.6.0.0, DefaultUserCrop (RATIONAL)" },
    .{ .tag = tags.depth_format, .kind = .unsigned_short, .count = .one, .values = &.{.{ 0, 2 }}, .since = 0x01050000, .citation = "DNG 1.6.0.0, DepthFormat (SHORT)" },
    .{ .tag = tags.depth_near, .kind = .rational, .count = .one, .since = 0x01050000, .citation = "DNG 1.6.0.0, DepthNear (RATIONAL)" },
    .{ .tag = tags.depth_far, .kind = .rational, .count = .one, .since = 0x01050000, .citation = "DNG 1.6.0.0, DepthFar (RATIONAL)" },
    .{ .tag = tags.depth_units, .kind = .unsigned_short, .count = .one, .values = &.{.{ 0, 1 }}, .since = 0x01050000, .citation = "DNG 1.6.0.0, DepthUnits (SHORT)" },
    .{ .tag = tags.depth_measure_type, .kind = .unsigned_short, .count = .one, .values = &.{.{ 0, 2 }}, .since = 0x01050000, .citation = "DNG 1.6.0.0, DepthMeasureType (SHORT)" },
    .{ .tag = tags.enhance_params, .kind = .ascii, .count = .any, .extras = &.{.non_empty}, .since = 0x01050000, .citation = "DNG 1.6.0.0, EnhanceParams (ASCII)" },
    .{ .tag = tags.profile_gain_table_map, .kind = .undefined, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, ProfileGainTableMap (UNDEFINED)" },
    .{ .tag = tags.semantic_name, .kind = .ascii, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, SemanticName (ASCII)" },
    .{ .tag = tags.semantic_instance_id, .kind = .ascii, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, SemanticInstanceID (ASCII)" },
    .{ .tag = tags.calibration_illuminant_3, .kind = .unsigned_short, .count = .one, .since = 0x01060000, .citation = "DNG 1.6.0.0, CalibrationIlluminant3 (SHORT)" },
    .{ .tag = tags.camera_calibration_3, .kind = .srational, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, CameraCalibration3 (SRATIONAL)" },
    .{ .tag = tags.color_matrix_3, .kind = .srational, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, ColorMatrix3 (SRATIONAL)" },
    .{ .tag = tags.forward_matrix_3, .kind = .srational, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, ForwardMatrix3 (SRATIONAL)" },
    .{ .tag = tags.illuminant_data_1, .kind = .undefined, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, IlluminantData1 (UNDEFINED)" },
    .{ .tag = tags.illuminant_data_2, .kind = .undefined, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, IlluminantData2 (UNDEFINED)" },
    .{ .tag = tags.illuminant_data_3, .kind = .undefined, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, IlluminantData3 (UNDEFINED)" },
    .{ .tag = tags.mask_sub_area, .kind = .unsigned_long, .count = .four, .extras = &.{.mask_sub_area_bounds}, .since = 0x01060000, .citation = "DNG 1.6.0.0, MaskSubArea (LONG)" },
    .{ .tag = tags.profile_hue_sat_map_data_3, .kind = .float, .count = .hue_sat_map, .since = 0x01060000, .citation = "DNG 1.6.0.0, ProfileHueSatMapData3 (FLOAT)" },
    .{ .tag = tags.reduction_matrix_3, .kind = .srational, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, ReductionMatrix3 (SRATIONAL)" },
    .{ .tag = tags.rgb_tables, .kind = .undefined, .count = .any, .since = 0x01060000, .citation = "DNG 1.6.0.0, RGBTables (UNDEFINED)" },
};

/// Constraints a claimed specification states that are not yet checked,
/// each waiting for a named reason. Kept as data so that none silently
/// disappears; a test pins this list.
pub const Pending = struct { what: []const u8, citation: []const u8, waits_for: []const u8 };
pub const pending = [_]Pending{
    .{ .what = "NewSubfileType bits", .citation = "TIFF 6.0 p. 36; DNG 1.6.0.0 Chapter 3", .waits_for = "validate's ruling on the DNG should-rows (DNG says previews \"should use\" 1, raw 0, and so on; TIFF-FX adds bit 4, MRC, RFC 3949 p. 64)" },
};

comptime {
    // Strictly ascending, so a duplicated row cannot shadow another.
    for (rules[1..], 0..) |rule, i| {
        if (rule.tag <= rules[i].tag) @compileError("ifd_conformance.rules must be sorted by tag without duplicates");
    }
}

/// Binary search; `rules` is sorted by tag (checked at comptime).
fn ruleFor(tag: u16) ?*const Rule {
    var lo: usize = 0;
    var hi: usize = rules.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (rules[mid].tag == tag) return &rules[mid];
        if (rules[mid].tag < tag) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// What IFD 0 declares about DNG. Null where IFD 0 has no DNGVersion: the
/// file does not claim DNG, and no DNG row or restriction applies.
pub const Dng = struct {
    /// Packed DNGVersion, major << 24 | minor << 16 | revision << 8 | build,
    /// or null when the entry is malformed, which leaves the version unknown
    /// (validate D2, 2026-11-04).
    version: ?u32,

    /// The cited edition, 1.6.0.0.
    pub const cited: u32 = 0x01060000;
    pub const v1_4: u32 = 0x01040000;

    /// From IFD 0, or null when it carries no DNGVersion. Any unsigned
    /// storage of four 8-bit values gives a version; anything else is
    /// malformed (its own fault).
    pub fn fromIfd0(dir: *const Ifd, endian: Endian) ?Dng {
        const index = indexOf(dir, tags.dng_version) orelse return null;
        const entry = dir.entries[index];
        if (entry.count != 4) return .{ .version = null };
        const bytes = dir.entryValueSlice(index);
        var packed_version: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const b = element(bytes, entry.field_type, i, endian) orelse return .{ .version = null };
            if (b > 255) return .{ .version = null };
            packed_version = (packed_version << 8) | @as(u32, @intCast(b));
        }
        return .{ .version = packed_version };
    }

    /// Closed value lists apply to a known version up to the cited edition:
    /// a later edition may extend any list (D1), and an unknown version
    /// gets none (D2).
    fn valueLists(self: Dng) bool {
        const v = self.version orelse return false;
        return v <= cited;
    }

    /// A constraint introduced in edition `since` applies to a known version
    /// of at least `since`; none applies to an unknown version (D2).
    fn from(self: Dng, since: u32) bool {
        const v = self.version orelse return false;
        return v >= since;
    }
};

/// Append every fault in `dir` to `out`, in entry order. `dng` is what IFD 0
/// of the same file declares (`Dng.fromIfd0`), or null.
pub fn check(
    allocator: std.mem.Allocator,
    dir: *const Ifd,
    endian: Endian,
    dng: ?Dng,
    out: *std.ArrayListUnmanaged(Fault),
) error{OutOfMemory}!void {
    for (dir.entries, 0..) |entry, i| {
        const index: u32 = @intCast(i);
        if (i > 0 and entry.tag <= dir.entries[i - 1].tag) {
            try out.append(allocator, .{ .unsorted = .{
                .entry_index = index,
                .tag = entry.tag,
                .prev_tag = dir.entries[i - 1].tag,
            } });
        }
        const rule = ruleFor(entry.tag) orelse continue;
        // A DNG row applies only in a DNG file, and only from the edition
        // that added its tag; with an unknown version, type and count rows
        // still apply (D2).
        if (rule.since) |since| {
            const d = dng orelse continue;
            if (d.version) |v| if (v < since) continue;
        }
        const values: Values = if (rule.since == null) .all else if (dng.?.version == null) .none else if (dng.?.valueLists()) .all else .no_closed_lists;
        const found = fieldReason(dir, i, rule.*, endian, values) orelse
            if (dng) |d| dngRestriction(dir, i, endian, d) else null;
        if (found) |reason| {
            try out.append(allocator, .{ .field_invalid = .{
                .entry_index = index,
                .tag = entry.tag,
                .reason = reason,
                .raw_type = entry.raw_type,
                .raw_count = entry.count,
                .raw_slot = rawSlot(entry, dir.offset_width, endian),
                .channels = if (reason == .channel_mismatch) channelMismatch(dir, endian) else null,
            } });
        }
    }
}

fn rawSlot(entry: Entry, width: ifd_mod.OffsetWidth, endian: Endian) u64 {
    return switch (width) {
        .classic => header_mod.readU32(entry.raw_value_or_offset[0..4], endian),
        .big => header_mod.readU64(&entry.raw_value_or_offset, endian),
    };
}

/// Which value rules of a row apply. Every non-DNG row: all. A DNG row: all
/// for a known version up to 1.6.0.0; above it, all but closed value lists
/// (D1); for an unknown version, none, leaving type and count (D2).
const Values = enum { all, no_closed_lists, none };

fn fieldReason(dir: *const Ifd, index: usize, rule: Rule, endian: Endian, values: Values) ?Reason {
    const entry = dir.entries[index];
    const type_ok = switch (rule.kind) {
        .unsigned_short, .unsigned_long => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long,
        .offsets_or_counts => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long or
            (entry.field_type == .long8 and dir.offset_width == .big),
        .rational => entry.field_type == .rational,
        .double => entry.field_type == .double,
        .srational => entry.field_type == .srational,
        .unsigned_byte => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long,
        .integer32 => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long or entry.field_type == .slong,
        .bytes => entry.field_type == .byte,
        .undefined => entry.field_type == .undefined,
        .ifd_offsets => entry.field_type == .long or entry.raw_type == 13 or
            (entry.field_type == .ifd8 and dir.offset_width == .big),
        .ascii => entry.field_type == .ascii,
        .float => entry.field_type == .float,
        .long_or_rational, .short_or_rational => entry.field_type == .byte or entry.field_type == .short or
            entry.field_type == .long or entry.field_type == .rational,
        .utf8_string => entry.field_type == .ascii or entry.field_type == .byte,
    };
    if (!type_ok) return .type;

    // An absent SamplesPerPixel or BitsPerSample takes its TIFF default (1).
    // A malformed one is its own fault; do not let it cascade into a count
    // fault here.
    const spp_entry = dir.get(tags.samples_per_pixel) != null;
    const spp_value: ?u64 = if (spp_entry) scalar(dir, tags.samples_per_pixel, endian) else 1;
    const spp_dependent = rule.count == .samples_per_pixel or rule.count == .dot_range or rule.count == .two_per_sample;
    const spp = spp_value orelse 1;
    const count_ok = if (spp_dependent and spp_value == null) true else switch (rule.count) {
        .one => entry.count == 1,
        .two => entry.count == 2,
        .three => entry.count == 3,
        .six => entry.count == 6,
        .twenty => entry.count == 20,
        .samples_per_pixel => entry.count == spp,
        .transfer_function, .per_level, .color_map => blk: {
            const bps = firstElement(dir, tags.bits_per_sample, endian) orelse 1;
            if (bps == 0 or bps > 16) break :blk false;
            const levels = @as(u64, 1) << @intCast(bps);
            break :blk switch (rule.count) {
                .transfer_function => entry.count == levels or entry.count == 3 * levels,
                .per_level => entry.count == levels,
                .color_map => entry.count == 3 * levels,
                else => unreachable,
            };
        },
        .dot_range => entry.count == 2 or entry.count == 2 * spp,
        .any => entry.count >= 1,
        .four => entry.count == 4,
        .two_per_sample => entry.count == 2 * spp,
        .strips => if (indexOf(dir, tags.strip_offsets)) |offsets| entry.count == dir.entries[offsets].count else entry.count >= 1,
        .zero_or_more => true,
        .sixteen => entry.count == 16,
        .multiple_of_six => entry.count >= 6 and entry.count % 6 == 0,
        .at_least_four => entry.count >= 4,
        .multiple_of_four => entry.count >= 4 and entry.count % 4 == 0,
        .even_at_least_two => entry.count >= 2 and entry.count % 2 == 0,
        .even_at_least_four => entry.count >= 4 and entry.count % 2 == 0,
        // A dependency that is absent where it is needed, or malformed (its
        // own fault), leaves the count unconstrained.
        .black_level, .active_area_width, .active_area_length, .hue_sat_map, .look_table => if (derivedCount(dir, rule.count, endian)) |n| entry.count == n else true,
    };
    if (!count_ok) return .count;
    if (values == .none) return null;

    const bytes = dir.entryValueSlice(index);
    switch (rule.kind) {
        .bytes, .undefined, .ifd_offsets, .integer32 => return null,
        .rational, .srational, .double, .float => return realReason(bytes, entry, rule, endian),
        .ascii => {
            if (!isAscii(bytes)) return .value;
            if (hasExtra(rule, .date_time) and !isDateTime(bytes)) return .value;
            if (hasExtra(rule, .non_empty) and (bytes.len < 2 or bytes[0] == 0)) return .value;
            if (hasExtra(rule, .iso8601) and !isIso8601(bytes)) return .value;
            return null;
        },
        .utf8_string => {
            if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return .value;
            if (!std.unicode.utf8ValidateSlice(bytes[0 .. bytes.len - 1])) return .value;
            return null;
        },
        .long_or_rational, .short_or_rational => if (entry.field_type == .rational) return null,
        .unsigned_byte, .unsigned_short, .unsigned_long, .offsets_or_counts => {},
    }
    const max: u64 = switch (rule.kind) {
        .unsigned_byte => std.math.maxInt(u8),
        .unsigned_short, .short_or_rational => std.math.maxInt(u16),
        .long_or_rational => std.math.maxInt(u32),
        .unsigned_long => std.math.maxInt(u32),
        else => std.math.maxInt(u64),
    };
    var i: usize = 0;
    while (i < entry.count) : (i += 1) {
        const value = element(bytes, entry.field_type, i, endian) orelse return .count;
        if (value > max) return .value;
        if (hasExtra(rule, .multiple_of_16) and value % 16 != 0) return .value;
        const ranges = rule.values orelse continue;
        if (rule.since == null) {
            if (value >= 32768) continue; // private range, not a violation
        } else if (values == .no_closed_lists) continue; // D1
        if (value > std.math.maxInt(u16) or !inRanges(@intCast(value), ranges)) return .value;
    }
    for (rule.extras) |extra| switch (extra) {
        .vertical_at_most_horizontal => {
            const horizontal = element(bytes, entry.field_type, 0, endian) orelse return .count;
            const vertical = element(bytes, entry.field_type, 1, endian) orelse return .count;
            if (vertical > horizontal) return .value;
        },
        .rows_multiple_of_vertical_subsampling => {
            // Only a YCbCr image with more than one strip: the effective rows
            // per strip is min(RowsPerStrip, ImageLength), and a single strip
            // reduces to the ImageLength rule (validate, 2026-11-04).
            const vertical = subsampling(dir, endian, 1) orelse continue;
            const rows = element(bytes, entry.field_type, 0, endian) orelse return .count;
            const length = scalar(dir, tags.image_length, endian) orelse continue;
            if (rows < length and rows % vertical != 0) return .value;
        },
        .not_palette_or_mask_with_jpeg => {
            const compression = scalar(dir, tags.compression, endian) orelse continue;
            const value = element(bytes, entry.field_type, 0, endian) orelse return .count;
            if (compression == tags.compression_jpeg and (value == 3 or value == 4)) return .value;
        },
        .image_layer => {
            const layer = element(bytes, entry.field_type, 0, endian) orelse return .count;
            const order = element(bytes, entry.field_type, 1, endian) orelse return .count;
            if (layer < 1 or layer > 3 or order < 1) return .value;
        },
        .not_with_rows_per_strip => if (indexOf(dir, tags.rows_per_strip) != null) return .value,
        .channels_plus_extra_samples => {
            const c = channels(dir, endian) orelse continue;
            if (entry.tag == tags.extra_samples) {
                const samples = scalar(dir, tags.samples_per_pixel, endian) orelse
                    if (indexOf(dir, tags.samples_per_pixel) == null) 1 else continue;
                // A palette or mask with SamplesPerPixel other than 1 is
                // reported on SamplesPerPixel alone (p. 37).
                if (c.one_sample_only and samples != 1) continue;
                if (!c.fits(samples, entry.count)) return .count;
            } else {
                const samples = element(bytes, entry.field_type, 0, endian) orelse return .count;
                // "SamplesPerPixel must be 1" for palette and transparency
                // mask (p. 37), whatever ExtraSamples says.
                if (c.one_sample_only and samples != 1) return .value;
                if (indexOf(dir, tags.extra_samples) == null and !c.fits(samples, 0)) return .channel_mismatch;
            }
        },
        .channels_without_samples_per_pixel => {
            if (indexOf(dir, tags.samples_per_pixel) != null or indexOf(dir, tags.extra_samples) != null) continue;
            const c = channels(dir, endian) orelse continue;
            if (!c.fits(1, 0)) return .channel_mismatch;
        },
        .palette_has_color_map => {
            const value = element(bytes, entry.field_type, 0, endian) orelse return .count;
            if (value == tags.photometric_palette and indexOf(dir, tags.colormap) == null) return .value;
        },
        .one_bit_for_transparency_mask => {
            const photometric = scalar(dir, tags.photometric, endian) orelse continue;
            if (photometric != tags.photometric_transparency_mask) continue;
            var k: usize = 0;
            while (k < entry.count) : (k += 1) {
                const bits = element(bytes, entry.field_type, k, endian) orelse return .count;
                if (bits != 1) return .value;
            }
        },
        .mask_sub_area_bounds => {
            const top = element(bytes, entry.field_type, 0, endian) orelse return .count;
            const left = element(bytes, entry.field_type, 1, endian) orelse return .count;
            const full_width = element(bytes, entry.field_type, 2, endian) orelse return .count;
            const full_height = element(bytes, entry.field_type, 3, endian) orelse return .count;
            const width = scalar(dir, tags.image_width, endian) orelse continue;
            const length = scalar(dir, tags.image_length, endian) orelse continue;
            const literal = top + width > full_height or left + length > full_width;
            const consistent = top + length > full_height or left + width > full_width;
            if (literal and consistent) return .value;
        },
        .multiple_of_16, .date_time, .user_crop, .noise_profile_signs, .tone_curve_endpoints, .non_empty, .iso8601 => {},
    };
    return null;
}

/// Value checks of a RATIONAL, SRATIONAL, DOUBLE or FLOAT field, after its
/// type and count.
fn realReason(bytes: []const u8, entry: Entry, rule: Rule, endian: Endian) ?Reason {
    for (rule.extras) |extra| switch (extra) {
        // "0 <= Top < Bottom <= 1.0, 0 <= Left < Right <= 1.0". RATIONAL is
        // unsigned, so only the order and the upper bound can fail; a zero
        // denominator defines no value.
        .user_crop => {
            var r: [4][2]u64 = undefined;
            for (&r, 0..) |*v, k| {
                const q = rationalAt(bytes, k, endian) orelse return .count;
                if (q[1] == 0) return .value;
                v.* = q;
            }
            const top = r[0];
            const left = r[1];
            const bottom = r[2];
            const right = r[3];
            if (top[0] * bottom[1] >= bottom[0] * top[1] or bottom[0] > bottom[1]) return .value;
            if (left[0] * right[1] >= right[0] * left[1] or right[0] > right[1]) return .value;
        },
        // Pairs (S, O): each S positive, each O non-negative; NaN fails both.
        .noise_profile_signs => {
            var k: usize = 0;
            while (k < entry.count) : (k += 1) {
                const v = doubleAt(bytes, k, endian) orelse return .count;
                const ok = if (k % 2 == 0) v > 0 else v >= 0;
                if (!ok) return .value;
            }
        },
        // The first sample (0, 0) and the last (1, 1).
        .tone_curve_endpoints => {
            const n: usize = std.math.cast(usize, entry.count) orelse return .count;
            const first_x = floatAt(bytes, 0, endian) orelse return .count;
            const first_y = floatAt(bytes, 1, endian) orelse return .count;
            const last_x = floatAt(bytes, n - 2, endian) orelse return .count;
            const last_y = floatAt(bytes, n - 1, endian) orelse return .count;
            if (first_x != 0 or first_y != 0 or last_x != 1 or last_y != 1) return .value;
        },
        else => {},
    };
    return null;
}

/// The count a DNG Tier 2 rule derives from other fields of `dir`, or null
/// when a field it needs is malformed (its own fault) or absent with no
/// default in the text.
fn derivedCount(dir: *const Ifd, count: Count, endian: Endian) ?u64 {
    switch (count) {
        // BlackLevelRepeatDim defaults to 1, 1; SamplesPerPixel to 1.
        .black_level => {
            var rows: u64 = 1;
            var cols: u64 = 1;
            if (indexOf(dir, tags.black_level_repeat_dim)) |k| {
                const entry = dir.entries[k];
                if (entry.count != 2) return null;
                const values = dir.entryValueSlice(k);
                rows = element(values, entry.field_type, 0, endian) orelse return null;
                cols = element(values, entry.field_type, 1, endian) orelse return null;
            }
            const samples = if (indexOf(dir, tags.samples_per_pixel) != null) scalar(dir, tags.samples_per_pixel, endian) orelse return null else 1;
            const area = std.math.mul(u64, rows, cols) catch return null;
            return std.math.mul(u64, area, samples) catch null;
        },
        // ActiveArea is top, left, bottom, right; absent, the whole image.
        .active_area_width, .active_area_length => {
            const width = count == .active_area_width;
            if (indexOf(dir, tags.active_area)) |k| {
                const entry = dir.entries[k];
                if (entry.count != 4) return null;
                const values = dir.entryValueSlice(k);
                const top = element(values, entry.field_type, 0, endian) orelse return null;
                const left = element(values, entry.field_type, 1, endian) orelse return null;
                const bottom = element(values, entry.field_type, 2, endian) orelse return null;
                const right = element(values, entry.field_type, 3, endian) orelse return null;
                if (bottom < top or right < left) return null;
                return if (width) right - left else bottom - top;
            }
            return scalar(dir, if (width) tags.image_width else tags.image_length, endian);
        },
        .hue_sat_map, .look_table => {
            const k = indexOf(dir, if (count == .hue_sat_map) tags.profile_hue_sat_map_dims else tags.profile_look_table_dims) orelse return null;
            const entry = dir.entries[k];
            if (entry.count != 3) return null;
            const values = dir.entryValueSlice(k);
            var product: u64 = 3;
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                const d = element(values, entry.field_type, i, endian) orelse return null;
                product = std.math.mul(u64, product, d) catch return null;
            }
            return product;
        },
        else => return null,
    }
}

/// The role DNG gives an IFD by its NewSubFileType, default 0 (DNG 1.6.0.0
/// Chapter 3); `unknown` for any other value or a malformed entry.
const Role = enum { raw, preview_or_reduced, alternative_preview, transparency, depth, enhanced, semantic_mask, unknown };

fn role(dir: *const Ifd, endian: Endian) Role {
    const nst = if (indexOf(dir, tags.new_subfile_type) != null) scalar(dir, tags.new_subfile_type, endian) orelse return .unknown else 0;
    return switch (nst) {
        0 => .raw,
        1 => .preview_or_reduced,
        0x10001 => .alternative_preview,
        4, 5 => .transparency,
        8, 9 => .depth,
        16 => .enhanced,
        0x10004 => .semantic_mask,
        else => .unknown,
    };
}

/// PhotometricInterpretation values DNG 1.6.0.0 Chapter 3 allows by role:
/// previews 1, 2, 6; raw 32803 (CFA) and 34892 (LinearRaw); depth maps 51177
/// and semantic masks 52527 ("required"). Enhanced IFDs take the raw list:
/// "The LinearRaw value can be used in reduced resolution IFDs and enhanced
/// IFDs" (p. 20) is permissive, and "should always use" LinearRaw is a
/// should-row (validate, 2026-11-04). NewSubFileType 1 marks previews and
/// reduced-resolution raw images alike, so it takes both lists. The text
/// gives transparency masks no list, so they take the union, as an unknown
/// role does (validate D6).
fn photometricAllowed(r: Role, value: u64) bool {
    const cfa = tags.photometric_color_filter_array;
    const linear = tags.photometric_linear_raw;
    const any_role = [_]u64{ 1, 2, 6, cfa, linear, tags.photometric_depth, tags.photometric_mask };
    const list: []const u64 = switch (r) {
        .raw => &.{ cfa, linear },
        .preview_or_reduced => &.{ 1, 2, 6, cfa, linear },
        .alternative_preview => &.{ 1, 2, 6 },
        .enhanced => &.{ cfa, linear },
        .depth => &.{tags.photometric_depth},
        .semantic_mask => &.{tags.photometric_mask},
        .transparency, .unknown => &any_role,
    };
    return std.mem.indexOfScalar(u64, list, value) != null;
}

/// DNG 1.6.0.0 Chapter 3, "Restrictions and Extensions to Existing TIFF
/// Tags", on an entry that passed its TIFF row: restrictions, so faults
/// (validate D6). Closed lists follow D1 and D2. The Deflate and lossy JPEG
/// conditions, from 1.4.0.0, apply to any known version from 1.4.0.0 on.
fn dngRestriction(dir: *const Ifd, index: usize, endian: Endian, dng: Dng) ?Reason {
    const entry = dir.entries[index];
    const bytes = dir.entryValueSlice(index);
    const lists = dng.valueLists();
    switch (entry.tag) {
        // "Supported values are from 8 to 32 bits/sample. The depth must be
        // the same for each sample if SamplesPerPixel is not equal to 1."
        // Floating point: "16, 24, and 32".
        tags.bits_per_sample => {
            const first = element(bytes, entry.field_type, 0, endian) orelse return null;
            var k: usize = 0;
            while (k < entry.count) : (k += 1) {
                const bits = element(bytes, entry.field_type, k, endian) orelse return null;
                if (bits != first) return .value;
                if (lists and (bits < 8 or bits > 32)) return .value;
            }
            if (lists and floatingPoint(dir, endian) and first != 16 and first != 24 and first != 32) return .value;
            // With SampleFormat absent (integer), a depth only floating point
            // allows is reported here.
            if (pixelRule(dir, endian, dng)) |p| {
                if (!p.bitsAllowed(first) or (indexOf(dir, tags.sample_format) == null and !p.fits(first, false))) return .value;
            }
        },
        // "If BitsPerSample is not equal to 8 or 16 or 32, then the bits must
        // be packed into bytes using the TIFF default FillOrder of 1".
        tags.fill_order => {
            const fill = element(bytes, entry.field_type, 0, endian) orelse return null;
            if (fill != 1 and !allBitsIn(dir, endian, &.{ 8, 16, 32 })) return .value;
        },
        // "DNG versions earlier than 1.4.0.0 always use the default
        // SampleFormat value of 1"; 1.4.0.0 "allows" 3.
        tags.sample_format => {
            if (!lists) return null;
            var k: usize = 0;
            while (k < entry.count) : (k += 1) {
                const format = element(bytes, entry.field_type, k, endian) orelse return null;
                if (format != 1 and !(format == 3 and dng.from(Dng.v1_4))) return .value;
            }
            // A depth map or semantic mask whose bit depth is allowed but whose
            // sample format does not match it.
            if (pixelRule(dir, endian, dng)) |p| {
                const bits = firstElement(dir, tags.bits_per_sample, endian) orelse 1;
                if (p.bitsAllowed(bits) and !p.fits(bits, floatingPoint(dir, endian))) return .value;
            }
        },
        // 1 and 7 before 1.4.0.0; 8 (Deflate) and 34892 (lossy JPEG) from it.
        tags.compression => {
            const compression = element(bytes, entry.field_type, 0, endian) orelse return null;
            const later = compression == tags.compression_deflate or compression == tags.compression_dng_lossy_jpeg;
            if (lists and compression != tags.compression_none and compression != tags.compression_jpeg and
                !(later and dng.from(Dng.v1_4))) return .value;
            if (!dng.from(Dng.v1_4)) return null;
            // "Deflate (8) compression is allowed for floating point image
            // data, 32-bit integer image data, transparency mask data, and
            // depth map data."
            if (compression == tags.compression_deflate) {
                const r = role(dir, endian);
                if (!(floatingPoint(dir, endian) or allBitsIn(dir, endian, &.{32}) or r == .transparency or r == .depth)) return .value;
            }
            // "Lossy JPEG (34892) is allowed for IFDs that use 8-bit integer
            // data and one of the following PhotometricInterpretation values:
            // 34892 (LinearRaw), 52527 (PhotometricMask)".
            if (compression == tags.compression_dng_lossy_jpeg) {
                const photometric = scalar(dir, tags.photometric, endian) orelse return null;
                if (floatingPoint(dir, endian) or !allBitsIn(dir, endian, &.{8}) or
                    (photometric != tags.photometric_linear_raw and photometric != tags.photometric_mask)) return .value;
            }
        },
        // With Compression 8: 1, 2, 3, or 34892 to 34895.
        tags.predictor => {
            if (!lists) return null;
            const compression = scalar(dir, tags.compression, endian) orelse return null;
            if (compression != tags.compression_deflate) return null;
            const p = element(bytes, entry.field_type, 0, endian) orelse return null;
            if (!(p >= 1 and p <= 3) and !(p >= 34892 and p <= 34895)) return .value;
        },
        // Depth maps and semantic masks are single channel.
        tags.samples_per_pixel => {
            if (pixelRule(dir, endian, dng) == null) return null;
            const samples = element(bytes, entry.field_type, 0, endian) orelse return null;
            if (samples != 1) return .value;
        },
        // An absent BitsPerSample is 1 bit, which no depth map or semantic
        // mask allows; reported on the NewSubFileType that gives the role.
        tags.new_subfile_type => {
            if (pixelRule(dir, endian, dng) == null) return null;
            if (indexOf(dir, tags.bits_per_sample) == null) return .value;
        },
        tags.photometric => {
            if (!lists) return null;
            const p = element(bytes, entry.field_type, 0, endian) orelse return null;
            if (!photometricAllowed(role(dir, endian), p)) return .value;
        },
        else => {},
    }
    return null;
}

/// The pixel types DNG fixes for two roles. Depth maps, from 1.5.0.0:
/// "stored as an 8 or 16-bit single channel unsigned integer image" (p. 15).
/// Semantic masks, from 1.6.0.0: "a single channel image" of 8 or 16-bit
/// unsigned integers or 32-bit floating point (p. 16). Closed lists, so
/// subject to D1 and D2 (validate, 2026-11-04).
const PixelRule = struct {
    float32: bool,

    fn bitsAllowed(self: PixelRule, bits: u64) bool {
        return bits == 8 or bits == 16 or (self.float32 and bits == 32);
    }

    fn fits(self: PixelRule, bits: u64, float: bool) bool {
        return if (float) self.float32 and bits == 32 else bits == 8 or bits == 16;
    }
};

fn pixelRule(dir: *const Ifd, endian: Endian, dng: Dng) ?PixelRule {
    if (!dng.valueLists()) return null;
    return switch (role(dir, endian)) {
        .depth => if (dng.from(0x01050000)) .{ .float32 = false } else null,
        .semantic_mask => if (dng.from(Dng.cited)) .{ .float32 = true } else null,
        else => null,
    };
}

/// Whether any SampleFormat value is 3 (IEEE floating point).
fn floatingPoint(dir: *const Ifd, endian: Endian) bool {
    const k = indexOf(dir, tags.sample_format) orelse return false;
    const entry = dir.entries[k];
    const values = dir.entryValueSlice(k);
    var i: usize = 0;
    while (i < entry.count) : (i += 1) {
        if ((element(values, entry.field_type, i, endian) orelse return false) == 3) return true;
    }
    return false;
}

/// Whether every BitsPerSample value (default 1) is one of `allowed`; true
/// when BitsPerSample is malformed (its own fault).
fn allBitsIn(dir: *const Ifd, endian: Endian, allowed: []const u64) bool {
    const k = indexOf(dir, tags.bits_per_sample) orelse return std.mem.indexOfScalar(u64, allowed, 1) != null;
    const entry = dir.entries[k];
    const values = dir.entryValueSlice(k);
    var i: usize = 0;
    while (i < entry.count) : (i += 1) {
        const bits = element(values, entry.field_type, i, endian) orelse return true;
        if (std.mem.indexOfScalar(u64, allowed, bits) == null) return false;
    }
    return true;
}

fn hasExtra(rule: Rule, extra: Extra) bool {
    return std.mem.indexOfScalar(Extra, rule.extras, extra) != null;
}

/// Whether `samples` = C + `extra`, with C the color channels the
/// PhotometricInterpretation implies (validate's table, 2026-11-04). True
/// when the photometric is absent, malformed, private or undefined (each its
/// own fault or no constraint), or when an ink field it needs is malformed.
const Channels = struct {
    photometric: u16,
    /// The channel counts C allowed; equal when only one is.
    a: u64,
    b: u64,
    /// Palette and transparency mask: "SamplesPerPixel must be 1" (p. 37).
    one_sample_only: bool = false,

    fn fits(self: Channels, samples: u64, extra: u64) bool {
        return samples == self.a + extra or samples == self.b + extra;
    }
};

/// The color channels C the PhotometricInterpretation implies (validate's
/// table, 2026-11-04), or null when the photometric is absent, malformed,
/// private or undefined (each its own fault or no constraint), or when an
/// ink field it needs is malformed.
fn channels(dir: *const Ifd, endian: Endian) ?Channels {
    const photometric = scalar(dir, tags.photometric, endian) orelse return null;
    const p: u16 = std.math.cast(u16, photometric) orelse return null;
    return switch (photometric) {
        // WhiteIsZero and BlackIsZero (p. 37).
        0, 1 => .{ .photometric = p, .a = 1, .b = 1 },
        // Palette and transparency mask (p. 37).
        3, 4 => .{ .photometric = p, .a = 1, .b = 1, .one_sample_only = true },
        // RGB (p. 24) and YCbCr (p. 94).
        2, 6 => .{ .photometric = p, .a = 3, .b = 3 },
        // Separated: NumberOfInks, default 4 (p. 70). With InkSet 1 (CMYK,
        // the default) and NumberOfInks other than 4, either is accepted.
        5 => blk: {
            const inks = scalar(dir, tags.number_of_inks, endian) orelse
                if (indexOf(dir, tags.number_of_inks) == null) 4 else return null;
            const ink_set = scalar(dir, tags.ink_set, endian) orelse
                if (indexOf(dir, tags.ink_set) == null) 1 else return null;
            break :blk .{ .photometric = p, .a = inks, .b = if (ink_set == 1) 4 else inks };
        },
        // CIELab (p. 111), ICCLab (Photoshop notes) and ITULab (RFC 3949):
        // L* may stand alone.
        8, 9, 10 => .{ .photometric = p, .a = 3, .b = 1 },
        else => null,
    };
}

/// The detail of a `channel_mismatch` in `dir`; null if there is none.
fn channelMismatch(dir: *const Ifd, endian: Endian) ?ChannelMismatch {
    const c = channels(dir, endian) orelse return null;
    const stored = indexOf(dir, tags.samples_per_pixel) != null;
    const samples = if (stored) scalar(dir, tags.samples_per_pixel, endian) orelse return null else 1;
    const sat = std.math.maxInt(u16);
    return .{
        .photometric = c.photometric,
        .samples = std.math.cast(u16, samples) orelse sat,
        .samples_stored = stored,
        .channels_a = std.math.cast(u16, c.a) orelse sat,
        .channels_b = std.math.cast(u16, c.b) orelse sat,
    };
}

/// YCbCrSubSampling factor `axis` (0 horizontal, 1 vertical) of a YCbCr image,
/// default 2 (TIFF 6.0 p. 92); null when the image is not YCbCr or the field
/// is malformed (its own fault).
fn subsampling(dir: *const Ifd, endian: Endian, axis: usize) ?u64 {
    const photometric = scalar(dir, tags.photometric, endian) orelse return null;
    if (photometric != tags.photometric_ycbcr) return null;
    const index = indexOf(dir, tags.ycbcr_subsampling) orelse return 2;
    const entry = dir.entries[index];
    if (entry.count != 2) return null;
    const factor = element(dir.entryValueSlice(index), entry.field_type, axis, endian) orelse return null;
    return if (factor == 0) null else factor;
}

/// TIFF 6.0 p. 15: "8-bit byte that contains a 7-bit ASCII code; the last
/// byte must be NUL". p. 16: "Only one NUL is allowed between strings", so a
/// run of NULs followed by more text is a fault; trailing NUL padding is
/// not (validate, 2026-11-04).
fn isAscii(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return false;
    for (bytes, 0..) |b, i| {
        if (b >= 0x80) return false;
        if (b == 0 and i + 1 < bytes.len and bytes[i + 1] == 0) {
            for (bytes[i + 1 ..]) |rest| if (rest != 0) return false;
            return true;
        }
    }
    return true;
}

/// "YYYY:MM:DD HH:MM:SS" and its NUL (TIFF 6.0 p. 31).
fn isDateTime(bytes: []const u8) bool {
    const pattern = "dddd:dd:dd dd:dd:dd";
    if (bytes.len != pattern.len + 1 or bytes[pattern.len] != 0) return false;
    for (pattern, bytes[0..pattern.len]) |p, b| {
        const ok = if (p == 'd') std.ascii.isDigit(b) else b == p;
        if (!ok) return false;
    }
    return true;
}

/// An ISO 8601 complete date-time, before the NUL (DNG PreviewDateTime;
/// validate, 2026-11-04: strict but complete). Extended
/// "YYYY-MM-DDThh:mm:ss" or basic "YYYYMMDDThhmmss", one form throughout;
/// an optional fraction after "." or ","; then nothing (local time), "Z",
/// or an offset "+hh:mm" (basic "+hhmm") or with "-". Fields are range
/// checked against the calendar; 24:00:00 is allowed with a zero fraction,
/// and second 60 for a leap second.
fn isIso8601(bytes: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    const s = bytes[0..end];
    const extended = s.len >= 5 and s[4] == '-';
    var at: usize = 0;
    const Reader = struct {
        fn digits(text: []const u8, pos: *usize, n: usize) ?u32 {
            if (pos.* + n > text.len) return null;
            var v: u32 = 0;
            for (text[pos.* .. pos.* + n]) |c| {
                if (!std.ascii.isDigit(c)) return null;
                v = v * 10 + (c - '0');
            }
            pos.* += n;
            return v;
        }
        fn char(text: []const u8, pos: *usize, c: u8) bool {
            if (pos.* >= text.len or text[pos.*] != c) return false;
            pos.* += 1;
            return true;
        }
    };
    const year = Reader.digits(s, &at, 4) orelse return false;
    if (extended and !Reader.char(s, &at, '-')) return false;
    const month = Reader.digits(s, &at, 2) orelse return false;
    if (extended and !Reader.char(s, &at, '-')) return false;
    const day = Reader.digits(s, &at, 2) orelse return false;
    if (!Reader.char(s, &at, 'T')) return false;
    const hour = Reader.digits(s, &at, 2) orelse return false;
    if (extended and !Reader.char(s, &at, ':')) return false;
    const minute = Reader.digits(s, &at, 2) orelse return false;
    if (extended and !Reader.char(s, &at, ':')) return false;
    const second = Reader.digits(s, &at, 2) orelse return false;
    var zero_fraction = true;
    if (at < s.len and (s[at] == '.' or s[at] == ',')) {
        at += 1;
        const start = at;
        while (at < s.len and std.ascii.isDigit(s[at])) : (at += 1) {
            if (s[at] != '0') zero_fraction = false;
        }
        if (at == start) return false;
    }
    if (at < s.len) {
        if (s[at] == 'Z') {
            at += 1;
        } else if (s[at] == '+' or s[at] == '-') {
            at += 1;
            const offset_hour = Reader.digits(s, &at, 2) orelse return false;
            if (extended and !Reader.char(s, &at, ':')) return false;
            const offset_minute = Reader.digits(s, &at, 2) orelse return false;
            if (offset_hour > 23 or offset_minute > 59) return false;
        } else return false;
    }
    if (at != s.len) return false;
    if (month < 1 or month > 12) return false;
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const month_days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day < 1 or day > month_days[month - 1]) return false;
    if (hour == 24) return minute == 0 and second == 0 and zero_fraction;
    return hour <= 23 and minute <= 59 and second <= 60;
}

fn inRanges(value: u16, ranges: []const [2]u16) bool {
    for (ranges) |range| {
        if (value >= range[0] and value <= range[1]) return true;
    }
    return false;
}

/// Element `i` of a RATIONAL array as numerator and denominator, or null.
fn rationalAt(bytes: []const u8, i: usize, endian: Endian) ?[2]u64 {
    const at = i * 8;
    if (at + 8 > bytes.len) return null;
    return .{ header_mod.readU32(bytes[at..], endian), header_mod.readU32(bytes[at + 4 ..], endian) };
}

fn floatAt(bytes: []const u8, i: usize, endian: Endian) ?f32 {
    const at = i * 4;
    if (at + 4 > bytes.len) return null;
    return @bitCast(header_mod.readU32(bytes[at..], endian));
}

fn doubleAt(bytes: []const u8, i: usize, endian: Endian) ?f64 {
    const at = i * 8;
    if (at + 8 > bytes.len) return null;
    return @bitCast(header_mod.readU64(bytes[at..][0..8], endian));
}

/// Element `i` of an unsigned BYTE, SHORT, LONG or LONG8 array, or null if
/// the bytes are too short.
fn element(bytes: []const u8, field_type: FieldType, i: usize, endian: Endian) ?u64 {
    const width: usize = switch (field_type) {
        .byte => 1,
        .short => 2,
        .long => 4,
        .long8 => 8,
        else => return null,
    };
    const at = i * width;
    if (at + width > bytes.len) return null;
    return switch (field_type) {
        .byte => bytes[at],
        .short => header_mod.readU16(bytes[at..], endian),
        .long => header_mod.readU32(bytes[at..], endian),
        .long8 => header_mod.readU64(bytes[at..][0..8], endian),
        else => unreachable,
    };
}

fn indexOf(dir: *const Ifd, tag: u16) ?usize {
    for (dir.entries, 0..) |entry, i| {
        if (entry.tag == tag) return i;
    }
    return null;
}

/// The value of an unsigned scalar tag with count 1, or null.
fn scalar(dir: *const Ifd, tag: u16, endian: Endian) ?u64 {
    for (dir.entries, 0..) |entry, i| {
        if (entry.tag != tag) continue;
        if (entry.count != 1) return null;
        return element(dir.entryValueSlice(i), entry.field_type, 0, endian);
    }
    return null;
}

/// The first element of an unsigned array tag, or null.
fn firstElement(dir: *const Ifd, tag: u16, endian: Endian) ?u64 {
    for (dir.entries, 0..) |entry, i| {
        if (entry.tag != tag) continue;
        if (entry.count == 0) return null;
        return element(dir.entryValueSlice(i), entry.field_type, 0, endian);
    }
    return null;
}

/// Payload of finding 17 `ifd_entries_unsorted`, little-endian: u32 IFD
/// index, u32 entry index, u64 absolute entry offset, u16 tag, u16 tag of
/// the preceding entry.
pub const unsorted_payload_len = 20;

/// Payload of finding 18 `tag_field_invalid`, little-endian: u32 IFD index,
/// u32 entry index, u64 absolute entry offset, u16 tag, u16 reason, u16 raw
/// type, u64 raw count, u64 raw value/offset slot (see `Fault`). Reason 4
/// `channel_mismatch` appends `channel_mismatch_extension_len` bytes: u16
/// PhotometricInterpretation, u16 SamplesPerPixel used, u16 1 if it is stored
/// or 0 if absent (the default 1, TIFF 6.0 p. 39), then u16 and u16 the
/// channel counts C allowed (equal when one is). ExtraSamples is always
/// absent for this reason.
pub const field_invalid_payload_len = 38;
pub const channel_mismatch_extension_len = 10;
/// Room for the longest payload of finding 17 or 18.
pub const max_payload_len = field_invalid_payload_len + channel_mismatch_extension_len;

/// Absolute offset of entry `entry_index` in the IFD at `ifd_offset`.
pub fn entryOffset(ifd_offset: u64, entry_index: u32, width: ifd_mod.OffsetWidth) u64 {
    return switch (width) {
        .classic => ifd_offset + 2 + @as(u64, entry_index) * 12,
        .big => ifd_offset + 8 + @as(u64, entry_index) * 20,
    };
}

/// Write `fault`'s payload into `buf` and return the used prefix.
pub fn encodePayload(fault: Fault, ifd_index: u32, entry_offset: u64, buf: *[max_payload_len]u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], ifd_index, .little);
    std.mem.writeInt(u32, buf[4..8], fault.entryIndex(), .little);
    std.mem.writeInt(u64, buf[8..16], entry_offset, .little);
    switch (fault) {
        .unsorted => |f| {
            std.mem.writeInt(u16, buf[16..18], f.tag, .little);
            std.mem.writeInt(u16, buf[18..20], f.prev_tag, .little);
            return buf[0..unsorted_payload_len];
        },
        .field_invalid => |f| {
            std.mem.writeInt(u16, buf[16..18], f.tag, .little);
            std.mem.writeInt(u16, buf[18..20], @intFromEnum(f.reason), .little);
            std.mem.writeInt(u16, buf[20..22], f.raw_type, .little);
            std.mem.writeInt(u64, buf[22..30], f.raw_count, .little);
            std.mem.writeInt(u64, buf[30..38], f.raw_slot, .little);
            const c = f.channels orelse return buf[0..field_invalid_payload_len];
            std.mem.writeInt(u16, buf[38..40], c.photometric, .little);
            std.mem.writeInt(u16, buf[40..42], c.samples, .little);
            std.mem.writeInt(u16, buf[42..44], @intFromBool(c.samples_stored), .little);
            std.mem.writeInt(u16, buf[44..46], c.channels_a, .little);
            std.mem.writeInt(u16, buf[46..48], c.channels_b, .little);
            return buf[0..max_payload_len];
        },
    }
}

// ---- tests ----

const testing = std.testing;

/// A little-endian classic entry with an inline value.
fn inline16(tag: u16, field_type: FieldType, count: u64, value: u32) Entry {
    var slot = [_]u8{0} ** 8;
    std.mem.writeInt(u32, slot[0..4], value, .little);
    return .{ .tag = tag, .field_type = field_type, .raw_type = @intFromEnum(field_type), .count = count, .raw_value_or_offset = slot };
}

fn faultsOf(entries: []Entry, cached: []?[]u8) !std.ArrayListUnmanaged(Fault) {
    return faultsOfDng(entries, cached, null);
}

fn faultsOfDng(entries: []Entry, cached: []?[]u8, dng: ?Dng) !std.ArrayListUnmanaged(Fault) {
    const dir = Ifd{
        .entries = entries,
        .next_offset = 0,
        .offset_width = .classic,
        .allocator = testing.allocator,
        .cached_values = cached,
    };
    var out: std.ArrayListUnmanaged(Fault) = .empty;
    try check(testing.allocator, &dir, .little, dng, &out);
    return out;
}

fn expectFaultsDng(dng: ?Dng, entries: []Entry, expected: []const Fault) !void {
    var cached = [_]?[]u8{null} ** 16;
    var out = try faultsOfDng(entries, cached[0..entries.len], dng);
    defer out.deinit(testing.allocator);
    try testing.expectEqualDeep(expected, out.items);
}

fn expectFaults(entries: []Entry, expected: []const Fault) !void {
    var cached = [_]?[]u8{null} ** 16;
    var out = try faultsOf(entries, cached[0..entries.len]);
    defer out.deinit(testing.allocator);
    try testing.expectEqualDeep(expected, out.items);
}

test "sorted entries with valid fields have no faults" {
    var entries = [_]Entry{
        inline16(256, .short, 1, 8),
        inline16(258, .short, 1, 8),
        inline16(tags.fill_order, .short, 1, 2),
        inline16(tags.orientation, .short, 1, 8),
        inline16(tags.samples_per_pixel, .short, 1, 1),
        inline16(tags.sample_format, .short, 1, 4),
    };
    try expectFaults(&entries, &.{});
}

test "a tag not larger than its predecessor is unsorted, duplicates included" {
    var entries = [_]Entry{
        inline16(256, .short, 1, 8),
        inline16(8476, .short, 1, 1), // a PlanarConfiguration whose tag ID was hit
        inline16(296, .short, 1, 2),
        inline16(296, .short, 1, 2),
    };
    try expectFaults(&entries, &.{
        .{ .unsorted = .{ .entry_index = 2, .tag = 296, .prev_tag = 8476 } },
        .{ .unsorted = .{ .entry_index = 3, .tag = 296, .prev_tag = 296 } },
    });
}

test "BYTE, SHORT and LONG are all acceptable for an unsigned scalar, other types are not" {
    for ([_]FieldType{ .byte, .short, .long }) |t| {
        var entries = [_]Entry{inline16(tags.fill_order, t, 1, 1)};
        try expectFaults(&entries, &.{});
    }
    for ([_]FieldType{ .float, .sshort, .slong, .rational, .ascii, .undefined, .sbyte }) |t| {
        var entries = [_]Entry{inline16(tags.fill_order, t, 1, 1)};
        try expectFaults(&entries, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.fill_order, .reason = .type, .raw_type = @intFromEnum(t), .raw_count = 1, .raw_slot = 1 } }});
    }
}

test "every single-value rule accepts its range ends and rejects the values just outside" {
    var checked: usize = 0;
    for (rules) |rule| {
        if (rule.count != .one) continue;
        const ranges = rule.values orelse continue;
        // A DNG row is checked in a DNG 1.6.0.0 file, and has no private range.
        const dng: ?Dng = if (rule.since != null) v1_6 else null;
        for (ranges) |range| {
            for ([_]u16{ range[0], range[1] }) |v| {
                if (rule.tag == tags.photometric) {
                    // With the SamplesPerPixel the photometric implies.
                    var ok = [_]Entry{ inline16(rule.tag, .short, 1, v), inline16(tags.samples_per_pixel, .short, 1, impliedChannels(v)) };
                    try expectFaultsDng(dng, &ok, &.{});
                } else {
                    var ok = [_]Entry{inline16(rule.tag, .short, 1, v)};
                    try expectFaultsDng(dng, &ok, &.{});
                }
            }
            for ([_]u32{ range[0] -% 1, range[1] + 1 }) |v| {
                if (dng == null and v >= 32768) continue; // private, never a fault
                var inside = false;
                for (ranges) |other| inside = inside or (v >= other[0] and v <= other[1]);
                if (inside) continue;
                var bad = [_]Entry{inline16(rule.tag, .short, 1, v)};
                try expectFaultsDng(dng, &bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = rule.tag, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = v } }});
            }
            checked += 1;
        }
        var two = [_]Entry{inline16(rule.tag, .short, 2, ranges[0][0] | (@as(u32, ranges[0][0]) << 16))};
        try expectFaultsDng(dng, &two, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = rule.tag, .reason = .count, .raw_type = 3, .raw_count = 2, .raw_slot = ranges[0][0] | (@as(u32, ranges[0][0]) << 16) } }});
    }
    try testing.expect(checked >= 8);
}

test "out-of-range public values are invalid; private-range values are not" {
    var bad = [_]Entry{inline16(tags.orientation, .short, 1, 257)};
    try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.orientation, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 257 } }});
    var zero = [_]Entry{inline16(tags.fill_order, .short, 1, 0)};
    try expectFaults(&zero, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.fill_order, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 0 } }});
    var private = [_]Entry{inline16(tags.orientation, .short, 1, 40000)};
    try expectFaults(&private, &.{});
    // A LONG above the SHORT range is a value fault, not a private value.
    var wide = [_]Entry{inline16(tags.orientation, .long, 1, 65537)};
    try expectFaults(&wide, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.orientation, .reason = .value, .raw_type = 4, .raw_count = 1, .raw_slot = 65537 } }});
}

test "SampleFormat needs one value per sample, each 1 to 4" {
    var ok = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 2), inline16(tags.sample_format, .short, 2, 0x0003_0003) };
    try expectFaults(&ok, &.{});
    var count = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 1), inline16(tags.sample_format, .short, 2, 0x0001_0001) };
    try expectFaults(&count, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.sample_format, .reason = .count, .raw_type = 3, .raw_count = 2, .raw_slot = 0x0001_0001 } }});
    var value = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 2), inline16(tags.sample_format, .short, 2, 0x0005_0001) };
    try expectFaults(&value, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.sample_format, .reason = .value, .raw_type = 3, .raw_count = 2, .raw_slot = 0x0005_0001 } }});
    // Without SamplesPerPixel the default is 1.
    var absent = [_]Entry{inline16(tags.sample_format, .short, 1, 2)};
    try expectFaults(&absent, &.{});
}

test "TransferFunction count is one or three tables of 2**BitsPerSample" {
    inline for (.{ 256, 768 }) |n| {
        var entries = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 8), inline16(tags.transfer_function, .short, n, 0x40) };
        var table = [_]u8{0} ** (2 * n);
        var cached = [_]?[]u8{ null, &table };
        var out = try faultsOf(&entries, &cached);
        defer out.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
    var entries = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 8), inline16(tags.transfer_function, .short, 272, 0x40) };
    try expectFaults(&entries, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.transfer_function, .reason = .count, .raw_type = 3, .raw_count = 272, .raw_slot = 0x40 } }});
}

test "an unsigned-integer array may be BYTE, SHORT or LONG, but holds 16-bit values" {
    // SampleFormat for two samples, widened and narrowed (TIFF 6.0 p. 16).
    var byte = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 2), inline16(tags.sample_format, .byte, 2, 0x0301) };
    try expectFaults(&byte, &.{});
    var long_values = [_]u8{ 1, 0, 0, 0, 3, 0, 0, 0 };
    var long = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 2), inline16(tags.sample_format, .long, 2, 0x200) };
    var cached = [_]?[]u8{ null, &long_values };
    var out = try faultsOf(&long, &cached);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    out.deinit(testing.allocator);
    // A LONG above 65535 is a value fault even where the low half is valid.
    var wide = [_]Entry{inline16(tags.sample_format, .long, 1, 0x1_0001)};
    try expectFaults(&wide, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.sample_format, .reason = .value, .raw_type = 4, .raw_count = 1, .raw_slot = 0x1_0001 } }});
    // Other types stay type faults for an array.
    for ([_]FieldType{ .sshort, .slong, .float, .rational, .ascii, .undefined }) |t| {
        var bad = [_]Entry{inline16(tags.sample_format, t, 1, 1)};
        try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.sample_format, .reason = .type, .raw_type = @intFromEnum(t), .raw_count = 1, .raw_slot = 1 } }});
    }
}

test "TransferFunction may be BYTE or LONG, and a LONG entry above 65535 is a value fault" {
    // BitsPerSample 2 gives tables of 4 entries.
    var byte = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 2), inline16(tags.transfer_function, .byte, 4, 0x0302_0100) };
    try expectFaults(&byte, &.{});

    var long_table = [_]u8{0} ** 16;
    for (0..4) |k| std.mem.writeInt(u32, long_table[4 * k ..][0..4], @intCast(k * 21845), .little);
    var long = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 2), inline16(tags.transfer_function, .long, 4, 0x100) };
    var cached = [_]?[]u8{ null, &long_table };
    var out = try faultsOf(&long, &cached);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    out.deinit(testing.allocator);

    std.mem.writeInt(u32, long_table[12..16], 65536, .little);
    out = try faultsOf(&long, &cached);
    defer out.deinit(testing.allocator);
    try testing.expectEqualDeep(&[_]Fault{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.transfer_function, .reason = .value, .raw_type = 4, .raw_count = 4, .raw_slot = 0x100 } }}, out.items);
}

/// Faults for one entry `tag` of `field_type` and `count`, whose value bytes
/// are `bytes` (served as the cached out-of-line value), after `before`.
fn faultsWithBytes(before: []const Entry, tag: u16, field_type: FieldType, count: u64, bytes: []u8) !std.ArrayListUnmanaged(Fault) {
    var entries: [8]Entry = undefined;
    @memcpy(entries[0..before.len], before);
    entries[before.len] = inline16(tag, field_type, count, 0x1234);
    var cached = [_]?[]u8{null} ** 8;
    cached[before.len] = bytes;
    return faultsOf(entries[0 .. before.len + 1], cached[0 .. before.len + 1]);
}

fn expectBytesReason(before: []const Entry, tag: u16, field_type: FieldType, count: u64, text: []const u8, expected: ?Reason) !void {
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..text.len], text);
    var out = try faultsWithBytes(before, tag, field_type, count, buf[0..text.len]);
    defer out.deinit(testing.allocator);
    if (expected) |reason| {
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqual(reason, out.items[0].field_invalid.reason);
    } else {
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "ruleFor finds every row and nothing else" {
    for (&rules) |*rule| try testing.expectEqual(rule, ruleFor(rule.tag).?);
    for ([_]u16{ 0, 253, 257 + 10000, 34738, 65535 }) |tag| try testing.expect(ruleFor(tag) == null);
}

test "ASCII: 7-bit, NUL-terminated, and no NUL run before more text" {
    const none: []const Entry = &.{};
    try expectBytesReason(none, tags.make, .ascii, 6, "SONY\x00\x00", null); // trailing padding is fine
    try expectBytesReason(none, tags.make, .ascii, 4, "a\x00b\x00", null); // two strings
    try expectBytesReason(none, tags.make, .ascii, 4, "SONY", .value); // no NUL
    try expectBytesReason(none, tags.make, .ascii, 5, "Caf\xc3\x00", .value); // not 7-bit
    try expectBytesReason(none, tags.make, .ascii, 5, "a\x00\x00b\x00", .value); // a run between strings
    try expectBytesReason(none, tags.make, .ascii, 0, "", .count);
    try expectBytesReason(none, tags.make, .undefined, 5, "SONY\x00", .type);
    try expectBytesReason(none, tags.copyright, .ascii, 3, "(c)", .value); // checked despite its number
}

test "DateTime is exactly YYYY:MM:DD HH:MM:SS and its NUL" {
    const none: []const Entry = &.{};
    try expectBytesReason(none, tags.date_time, .ascii, 20, "2017:07:13 16:58:28\x00", null);
    try expectBytesReason(none, tags.date_time, .ascii, 20, "2017-07-13 16:58:28\x00", .value);
    try expectBytesReason(none, tags.date_time, .ascii, 20, "    :  :     :  :  \x00", .value);
    try expectBytesReason(none, tags.date_time, .ascii, 19, "2017:07:13 16:58:2\x00", .count);
}

test "RATIONAL fields need RATIONAL and their fixed counts" {
    const none: []const Entry = &.{};
    var pair = [_]u8{0} ** 48;
    try expectBytesReason(none, tags.white_point, .rational, 2, pair[0..16], null);
    try expectBytesReason(none, tags.white_point, .rational, 3, pair[0..24], .count);
    try expectBytesReason(none, tags.reference_black_white, .rational, 6, pair[0..48], null);
    try expectBytesReason(none, tags.x_resolution, .srational, 1, pair[0..8], .type);
    try expectBytesReason(none, tags.x_resolution, .long, 1, pair[0..4], .type);
}

test "TileWidth and TileLength are multiples of 16" {
    var ok = [_]Entry{ inline16(tags.tile_width, .short, 1, 256), inline16(tags.tile_length, .long, 1, 16) };
    try expectFaults(&ok, &.{});
    var bad = [_]Entry{inline16(tags.tile_width, .short, 1, 250)};
    try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.tile_width, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 250 } }});
}

test "YCbCrSubSampling: each 1, 2 or 4, vertical at most horizontal" {
    for ([_]u32{ 0x0001_0002, 0x0002_0002, 0x0001_0004, 0x0004_0004, 0x0001_0001 }) |slot| {
        var ok = [_]Entry{inline16(tags.ycbcr_subsampling, .short, 2, slot)};
        try expectFaults(&ok, &.{});
    }
    for ([_]u32{ 0x0002_0001, 0x0003_0003, 0x0002_0000, 0x0008_0008 }) |slot| {
        var bad = [_]Entry{inline16(tags.ycbcr_subsampling, .short, 2, slot)};
        try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.ycbcr_subsampling, .reason = .value, .raw_type = 3, .raw_count = 2, .raw_slot = slot } }});
    }
}

test "multi-strip YCbCr RowsPerStrip is a multiple of the vertical subsampling" {
    // ImageLength 16, YCbCr, default subsampling [2, 2].
    for ([_]struct { rows: u32, fault: bool }{
        .{ .rows = 4, .fault = false },
        .{ .rows = 3, .fault = true },
        .{ .rows = 17, .fault = false }, // one strip: waits in `pending`
        .{ .rows = 0xFFFF_FFFF, .fault = false }, // the default, one strip
    }) |case| {
        var entries = [_]Entry{
            inline16(tags.image_length, .short, 1, 16),
            inline16(tags.photometric, .short, 1, 6),
            inline16(tags.samples_per_pixel, .short, 1, 3),
            inline16(tags.rows_per_strip, .long, 1, case.rows),
        };
        if (case.fault) {
            try expectFaults(&entries, &.{.{ .field_invalid = .{ .entry_index = 3, .tag = tags.rows_per_strip, .reason = .value, .raw_type = 4, .raw_count = 1, .raw_slot = case.rows } }});
        } else try expectFaults(&entries, &.{});
    }
    // Explicit [4, 4] subsampling makes 6 a fault and 8 fine.
    var four = [_]Entry{
        inline16(tags.image_length, .short, 1, 16),
        inline16(tags.photometric, .short, 1, 6),
        inline16(tags.samples_per_pixel, .short, 1, 3),
        inline16(tags.rows_per_strip, .short, 1, 6),
        inline16(tags.ycbcr_subsampling, .short, 2, 0x0004_0004),
    };
    try expectFaults(&four, &.{.{ .field_invalid = .{ .entry_index = 3, .tag = tags.rows_per_strip, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 6 } }});
    four[3] = inline16(tags.rows_per_strip, .short, 1, 8);
    try expectFaults(&four, &.{});
    // Not YCbCr: no constraint.
    var rgb = [_]Entry{
        inline16(tags.image_length, .short, 1, 16),
        inline16(tags.photometric, .short, 1, 2),
        inline16(tags.samples_per_pixel, .short, 1, 3),
        inline16(tags.rows_per_strip, .short, 1, 3),
    };
    try expectFaults(&rgb, &.{});
}

test "counts derived from BitsPerSample and SamplesPerPixel" {
    const bps2 = [_]Entry{inline16(tags.bits_per_sample, .short, 1, 2)};
    var levels = [_]u8{0} ** 32;
    try expectBytesReason(&bps2, tags.gray_response_curve, .short, 4, levels[0..8], null);
    try expectBytesReason(&bps2, tags.gray_response_curve, .short, 5, levels[0..10], .count);
    try expectBytesReason(&bps2, tags.colormap, .short, 12, levels[0..24], null);
    try expectBytesReason(&bps2, tags.colormap, .short, 4, levels[0..8], .count);
    const spp3 = [_]Entry{inline16(tags.samples_per_pixel, .short, 1, 3)};
    try expectBytesReason(&spp3, tags.dot_range, .short, 6, levels[0..12], null);
    try expectBytesReason(&spp3, tags.dot_range, .byte, 2, levels[0..2], null);
    try expectBytesReason(&spp3, tags.dot_range, .short, 4, levels[0..8], .count);
    // A malformed SamplesPerPixel does not cascade into count faults.
    var bad_spp = [_]Entry{ inline16(tags.samples_per_pixel, .short, 2, 0x0003_0003), inline16(tags.sample_format, .short, 1, 1) };
    try expectFaults(&bad_spp, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.samples_per_pixel, .reason = .count, .raw_type = 3, .raw_count = 2, .raw_slot = 0x0003_0003 } }});
}

test "LONG8 is allowed only for strip and tile offsets and counts, and only in BigTIFF" {
    var offsets = [_]u8{0} ** 16;
    std.mem.writeInt(u64, offsets[0..8], 16, .little);
    std.mem.writeInt(u64, offsets[8..16], 1 << 33, .little);
    for ([_]ifd_mod.OffsetWidth{ .classic, .big }) |width| {
        for ([_]u16{ tags.strip_offsets, tags.image_width }) |tag| {
            var entries = [_]Entry{inline16(tag, .long8, 2, 0)};
            var cached = [_]?[]u8{&offsets};
            const dir = Ifd{ .entries = &entries, .next_offset = 0, .offset_width = width, .allocator = testing.allocator, .cached_values = &cached };
            var out: std.ArrayListUnmanaged(Fault) = .empty;
            defer out.deinit(testing.allocator);
            try check(testing.allocator, &dir, .little, null, &out);
            const allowed = width == .big and tag == tags.strip_offsets;
            if (allowed) {
                try testing.expectEqual(@as(usize, 0), out.items.len);
            } else {
                try testing.expectEqual(@as(usize, 1), out.items.len);
                // ImageWidth also has count 2 here, but type is checked first.
                try testing.expectEqual(Reason.type, out.items[0].field_invalid.reason);
            }
        }
    }
}

test "YCbCr image dimensions are not constrained by the subsampling (TIFF Technical Note 2)" {
    // TN2 rewrites TIFF 6.0 Section 21: "ImageWidth/ImageLength are not
    // constrained", whatever the compression (validate, 2026-11-04).
    for ([_]u32{ 1, 5, 6, 7 }) |compression| {
        var entries = [_]Entry{
            inline16(tags.image_width, .short, 1, 5),
            inline16(tags.image_length, .short, 1, 3),
            inline16(tags.compression, .short, 1, compression),
            inline16(tags.photometric, .short, 1, 6),
            inline16(tags.samples_per_pixel, .short, 1, 3),
        };
        try expectFaults(&entries, &.{});
    }
}

test "with Compression 7, PhotometricInterpretation is not palette or transparency mask" {
    for ([_]struct { compression: u32, photometric: u32, fault: bool }{
        .{ .compression = 7, .photometric = 3, .fault = true },
        .{ .compression = 7, .photometric = 4, .fault = true },
        .{ .compression = 7, .photometric = 2, .fault = false },
        .{ .compression = 5, .photometric = 3, .fault = false },
    }) |case| {
        // A 1-bit ColorMap, so that a palette fails only for JPEG.
        var entries = [_]Entry{
            inline16(tags.compression, .short, 1, case.compression),
            inline16(tags.photometric, .short, 1, case.photometric),
            inline16(tags.samples_per_pixel, .short, 1, impliedChannels(case.photometric)),
            inline16(tags.colormap, .short, 6, 0),
        };
        var map = [_]u8{0} ** 12;
        var cached = [_]?[]u8{ null, null, null, &map };
        var out = try faultsOf(&entries, &cached);
        defer out.deinit(testing.allocator);
        if (case.fault) {
            try testing.expectEqualDeep(@as([]const Fault, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.photometric, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = case.photometric } }}), out.items);
        } else try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "a palette image needs a ColorMap, and a transparency mask one bit per sample (TIFF 6.0 p. 37)" {
    var no_map = [_]Entry{inline16(tags.photometric, .short, 1, 3)};
    try expectFaults(&no_map, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.photometric, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 3 } }});
    var map = [_]u8{0} ** 12;
    var with_map = [_]Entry{ inline16(tags.photometric, .short, 1, 3), inline16(tags.colormap, .short, 6, 0) };
    var cached = [_]?[]u8{ null, &map };
    var out = try faultsOf(&with_map, &cached);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    // A ColorMap without a palette is not this rule's concern.
    var gray = [_]Entry{inline16(tags.photometric, .short, 1, 1)};
    try expectFaults(&gray, &.{});

    var mask_default = [_]Entry{inline16(tags.photometric, .short, 1, 4)};
    try expectFaults(&mask_default, &.{});
    var mask1 = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 1), inline16(tags.photometric, .short, 1, 4) };
    try expectFaults(&mask1, &.{});
    for ([_]FieldType{ .short, .byte }) |t| {
        var mask8 = [_]Entry{ inline16(tags.bits_per_sample, t, 1, 8), inline16(tags.photometric, .short, 1, 4) };
        try expectFaults(&mask8, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.bits_per_sample, .reason = .value, .raw_type = @intFromEnum(t), .raw_count = 1, .raw_slot = 8 } }});
    }
    var gray8 = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 8), inline16(tags.photometric, .short, 1, 1) };
    try expectFaults(&gray8, &.{});
}

test "a channel mismatch says what it compared, in its payload too" {
    // BlackIsZero with three samples and no ExtraSamples: anchored on
    // SamplesPerPixel, which is stored.
    var stored = [_]Entry{ inline16(tags.photometric, .short, 1, 1), inline16(tags.samples_per_pixel, .short, 1, 3) };
    try expectFaults(&stored, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.samples_per_pixel, .reason = .channel_mismatch, .raw_type = 3, .raw_count = 1, .raw_slot = 3, .channels = .{ .photometric = 1, .samples = 3, .samples_stored = true, .channels_a = 1, .channels_b = 1 } } }});
    // YCbCr with SamplesPerPixel absent: anchored on the photometric; the
    // default of 1 is what fails.
    var absent = [_]Entry{inline16(tags.photometric, .short, 1, 6)};
    const fault: Fault = .{ .field_invalid = .{ .entry_index = 0, .tag = tags.photometric, .reason = .channel_mismatch, .raw_type = 3, .raw_count = 1, .raw_slot = 6, .channels = .{ .photometric = 6, .samples = 1, .samples_stored = false, .channels_a = 3, .channels_b = 3 } } };
    try expectFaults(&absent, &.{fault});
    var buf: [max_payload_len]u8 = undefined;
    const payload = encodePayload(fault, 0, 34, &buf);
    try testing.expectEqual(@as(usize, 48), payload.len);
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, payload[18..20], .little));
    try testing.expectEqualSlices(u8, &.{ 6, 0, 1, 0, 0, 0, 3, 0, 3, 0 }, payload[38..48]);
    // Lab allows 3 or 1.
    var lab = [_]Entry{ inline16(tags.photometric, .short, 1, 8), inline16(tags.samples_per_pixel, .short, 1, 2) };
    try expectFaults(&lab, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.samples_per_pixel, .reason = .channel_mismatch, .raw_type = 3, .raw_count = 1, .raw_slot = 2, .channels = .{ .photometric = 8, .samples = 2, .samples_stored = true, .channels_a = 3, .channels_b = 1 } } }});
}

test "Technical Notes kinds: BYTE-only, UNDEFINED-only, DWORD and IFD offsets" {
    const none: []const Entry = &.{};
    var four = [_]u8{0} ** 8;
    try expectBytesReason(none, tags.clip_path, .byte, 4, four[0..4], null);
    try expectBytesReason(none, tags.clip_path, .undefined, 4, four[0..4], .type);
    try expectBytesReason(none, tags.jpeg_tables, .undefined, 4, four[0..4], null);
    try expectBytesReason(none, tags.jpeg_tables, .byte, 4, four[0..4], .type);
    try expectBytesReason(none, tags.image_source_data, .undefined, 4, four[0..4], null);
    for ([_]FieldType{ .byte, .short, .long, .slong }) |t| {
        var ok = [_]Entry{inline16(tags.x_clip_path_units, t, 1, 1000)};
        try expectFaults(&ok, &.{});
    }
    for ([_]FieldType{ .ascii, .float, .rational, .undefined }) |t| {
        var bad = [_]Entry{inline16(tags.y_clip_path_units, t, 1, 1000)};
        try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.y_clip_path_units, .reason = .type, .raw_type = @intFromEnum(t), .raw_count = 1, .raw_slot = 1000 } }});
    }
    var two = [_]Entry{inline16(tags.x_clip_path_units, .long, 2, 0)};
    try expectFaults(&two, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.x_clip_path_units, .reason = .count, .raw_type = 4, .raw_count = 2, .raw_slot = 0 } }});
    // SubIFDs: LONG or IFD (13); IFD8 only in BigTIFF; not SHORT.
    var long = [_]Entry{inline16(tags.sub_ifds, .long, 1, 8)};
    try expectFaults(&long, &.{});
    var ifd13 = [_]Entry{.{ .tag = tags.sub_ifds, .field_type = .unknown, .raw_type = 13, .count = 1, .raw_value_or_offset = [_]u8{ 8, 0, 0, 0, 0, 0, 0, 0 } }};
    try expectFaults(&ifd13, &.{});
    var short = [_]Entry{inline16(tags.sub_ifds, .short, 1, 8)};
    try expectFaults(&short, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.sub_ifds, .reason = .type, .raw_type = 3, .raw_count = 1, .raw_slot = 8 } }});
    var ifd8 = [_]Entry{inline16(tags.sub_ifds, .ifd8, 1, 8)};
    try expectFaults(&ifd8, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.sub_ifds, .reason = .type, .raw_type = 18, .raw_count = 1, .raw_slot = 8 } }});
}

test "Compression is 1 to 10 and PhotometricInterpretation 0 to 6 or 8 to 10; private values are skipped" {
    for ([_]struct { tag: u16, value: u32, fault: bool }{
        .{ .tag = tags.compression, .value = 10, .fault = false },
        .{ .tag = tags.compression, .value = 11, .fault = true },
        .{ .tag = tags.compression, .value = 32766, .fault = true }, // NeXT: public range, no claimed spec
        .{ .tag = tags.compression, .value = 50000, .fault = false }, // Zstd: private
        .{ .tag = tags.photometric, .value = 7, .fault = true },
        .{ .tag = tags.photometric, .value = 10, .fault = false },
        .{ .tag = tags.photometric, .value = 32803, .fault = false }, // CFA: private
    }) |case| {
        var entries = [_]Entry{inline16(case.tag, .short, 1, case.value)};
        if (case.fault) {
            try expectFaults(&entries, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = case.tag, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = case.value } }});
        } else try expectFaults(&entries, &.{});
    }
}

test "TIFF-FX kinds and rules" {
    // FaxProfile is defined as BYTE: SHORT is accepted, but not above 255.
    var byte_ok = [_]Entry{inline16(tags.fax_profile, .short, 1, 6)};
    try expectFaults(&byte_ok, &.{});
    var byte_wide = [_]Entry{inline16(tags.mode_number, .short, 1, 256)};
    try expectFaults(&byte_wide, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.mode_number, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 256 } }});
    // Decode is SRATIONAL[2 * SamplesPerPixel].
    const spp3 = [_]Entry{inline16(tags.samples_per_pixel, .short, 1, 3)};
    var six = [_]u8{0} ** 48;
    try expectBytesReason(&spp3, tags.decode, .srational, 6, six[0..48], null);
    try expectBytesReason(&spp3, tags.decode, .srational, 2, six[0..16], .count);
    try expectBytesReason(&spp3, tags.decode, .rational, 6, six[0..48], .type);
    // StripRowCounts: one per strip, and never alongside RowsPerStrip.
    var rows = [_]u8{0} ** 8;
    const one_strip = [_]Entry{inline16(tags.strip_offsets, .long, 1, 0)};
    try expectBytesReason(&one_strip, tags.strip_row_counts, .long, 1, rows[0..4], null);
    try expectBytesReason(&one_strip, tags.strip_row_counts, .long, 2, rows[0..8], .count);
    const with_rows = [_]Entry{ inline16(tags.strip_offsets, .long, 1, 0), inline16(tags.rows_per_strip, .long, 1, 8) };
    try expectBytesReason(&with_rows, tags.strip_row_counts, .long, 1, rows[0..4], .value);
    // ImageLayer: [0] is 1-3, [1] at least 1.
    var layer_ok = [_]Entry{inline16(tags.image_layer, .short, 2, 0x0001_0003)};
    try expectFaults(&layer_ok, &.{});
    for ([_]u32{ 0x0001_0000, 0x0001_0004, 0x0000_0002 }) |slot| {
        var bad = [_]Entry{inline16(tags.image_layer, .short, 2, slot)};
        try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.image_layer, .reason = .value, .raw_type = 3, .raw_count = 2, .raw_slot = slot } }});
    }
}

test "GeoTIFF Tier 1: DOUBLE only for the DOUBLE tags, and the model-tag counts" {
    const none: []const Entry = &.{};
    var d = [_]u8{0} ** (16 * 8);
    // DOUBLE is the only valid type; FLOAT, RATIONAL and integers are type faults.
    for ([_]u16{ tags.model_pixel_scale, tags.model_tiepoint, tags.model_transformation, tags.geo_double_params }) |tag| {
        const n: u32 = switch (tag) {
            tags.model_pixel_scale => 3,
            tags.model_transformation => 16,
            else => 6,
        };
        try expectBytesReason(none, tag, .double, n, d[0 .. 8 * n], null);
        for ([_]FieldType{ .float, .rational, .srational, .long, .short }) |t| {
            try expectBytesReason(none, tag, t, n, d[0 .. 8 * n], .type);
        }
    }
    // ModelPixelScale is exactly 3 and ModelTransformation exactly 16.
    try expectBytesReason(none, tags.model_pixel_scale, .double, 2, d[0..16], .count);
    try expectBytesReason(none, tags.model_pixel_scale, .double, 4, d[0..32], .count);
    try expectBytesReason(none, tags.model_transformation, .double, 15, d[0..120], .count);
    // ModelTiepoint is a positive multiple of 6.
    try expectBytesReason(none, tags.model_tiepoint, .double, 12, d[0..96], null);
    for ([_]u32{ 0, 5, 7, 11 }) |n| {
        try expectBytesReason(none, tags.model_tiepoint, .double, n, d[0 .. 8 * n], .count);
    }
    // GeoDoubleParams takes any count.
    try expectBytesReason(none, tags.geo_double_params, .double, 1, d[0..8], null);
    // GeoKeyDirectory: unsigned 16-bit values, at least the 4-value header.
    try expectBytesReason(none, tags.geo_key_directory, .short, 4, d[0..8], null);
    try expectBytesReason(none, tags.geo_key_directory, .short, 3, d[0..6], .count);
    try expectBytesReason(none, tags.geo_key_directory, .double, 4, d[0..32], .type);
    // GeoAsciiParams is ASCII.
    try expectBytesReason(none, tags.geo_ascii_params, .ascii, 8, "WGS 84|\x00", null);
    try expectBytesReason(none, tags.geo_ascii_params, .byte, 8, "WGS 84|\x00", .type);
}

test "SamplesPerPixel is the photometric's color channels plus the ExtraSamples count" {
    const F = struct { tag: u16, reason: Reason };
    const Case = struct { photometric: u32, spp: ?u32, extra: ?u32 = null, inks: ?u32 = null, ink_set: ?u32 = null, fault: ?F = null };
    for ([_]Case{
        .{ .photometric = 1, .spp = 1 },
        .{ .photometric = 1, .spp = null },
        .{ .photometric = 1, .spp = 2, .extra = 1 },
        .{ .photometric = 1, .spp = 2, .fault = .{ .tag = tags.samples_per_pixel, .reason = .channel_mismatch } },
        .{ .photometric = 0, .spp = 3, .extra = 1, .fault = .{ .tag = tags.extra_samples, .reason = .count } },
        .{ .photometric = 2, .spp = 3 },
        .{ .photometric = 2, .spp = 4, .extra = 1 },
        .{ .photometric = 2, .spp = 4, .fault = .{ .tag = tags.samples_per_pixel, .reason = .channel_mismatch } },
        .{ .photometric = 2, .spp = 3, .extra = 1, .fault = .{ .tag = tags.extra_samples, .reason = .count } },
        .{ .photometric = 2, .spp = null, .fault = .{ .tag = tags.photometric, .reason = .channel_mismatch } },
        .{ .photometric = 2, .spp = null, .extra = 1, .fault = .{ .tag = tags.extra_samples, .reason = .count } },
        .{ .photometric = 3, .spp = 1 },
        // Palette and mask: SamplesPerPixel other than 1 is a value fault on
        // it alone (p. 37); with 1, ExtraSamples is a count fault.
        .{ .photometric = 3, .spp = 3, .fault = .{ .tag = tags.samples_per_pixel, .reason = .value } },
        .{ .photometric = 3, .spp = 2, .extra = 1, .fault = .{ .tag = tags.samples_per_pixel, .reason = .value } },
        .{ .photometric = 3, .spp = 1, .extra = 1, .fault = .{ .tag = tags.extra_samples, .reason = .count } },
        .{ .photometric = 3, .spp = null, .extra = 1, .fault = .{ .tag = tags.extra_samples, .reason = .count } },
        .{ .photometric = 4, .spp = 2, .extra = 1, .fault = .{ .tag = tags.samples_per_pixel, .reason = .value } },
        .{ .photometric = 4, .spp = 1 },
        .{ .photometric = 5, .spp = 4 },
        .{ .photometric = 5, .spp = 5, .extra = 1 },
        .{ .photometric = 5, .spp = 3, .fault = .{ .tag = tags.samples_per_pixel, .reason = .channel_mismatch } },
        .{ .photometric = 5, .spp = 2, .inks = 2 },
        .{ .photometric = 5, .spp = 4, .inks = 2 }, // InkSet 1 by default: 4 also accepted
        .{ .photometric = 5, .spp = 4, .inks = 2, .ink_set = 2, .fault = .{ .tag = tags.samples_per_pixel, .reason = .channel_mismatch } },
        .{ .photometric = 5, .spp = 6, .inks = 6, .ink_set = 2 },
        .{ .photometric = 6, .spp = 3 },
        .{ .photometric = 6, .spp = 1, .fault = .{ .tag = tags.samples_per_pixel, .reason = .channel_mismatch } },
        .{ .photometric = 8, .spp = 1 },
        .{ .photometric = 8, .spp = 3 },
        .{ .photometric = 9, .spp = 4, .extra = 1 },
        .{ .photometric = 10, .spp = 2, .fault = .{ .tag = tags.samples_per_pixel, .reason = .channel_mismatch } },
        .{ .photometric = 32803, .spp = 1 }, // CFA: private, skipped
        .{ .photometric = 7, .spp = 9, .fault = .{ .tag = tags.photometric, .reason = .value } }, // undefined: its own fault only
    }) |case| {
        var entries: [6]Entry = undefined;
        var n: usize = 0;
        entries[n] = inline16(tags.photometric, .short, 1, case.photometric);
        n += 1;
        if (case.spp) |v| {
            entries[n] = inline16(tags.samples_per_pixel, .short, 1, v);
            n += 1;
        }
        var cached = [_]?[]u8{null} ** 16;
        var map = [_]u8{0} ** 12; // a 1-bit ColorMap, which palette needs (p. 37)
        if (case.photometric == 3) {
            entries[n] = inline16(tags.colormap, .short, 6, 0);
            cached[n] = &map;
            n += 1;
        }
        if (case.ink_set) |v| {
            entries[n] = inline16(tags.ink_set, .short, 1, v);
            n += 1;
        }
        if (case.inks) |v| {
            entries[n] = inline16(tags.number_of_inks, .short, 1, v);
            n += 1;
        }
        if (case.extra) |m| {
            // m associated-alpha values; inline holds at most two SHORTs.
            std.debug.assert(m <= 2);
            entries[n] = inline16(tags.extra_samples, .short, m, if (m == 2) 0x0001_0001 else 1);
            n += 1;
        }
        var out = try faultsOf(entries[0..n], cached[0..n]);
        defer out.deinit(testing.allocator);
        if (case.fault) |want| {
            if (out.items.len != 1 or out.items[0].field_invalid.tag != want.tag or out.items[0].field_invalid.reason != want.reason) {
                std.debug.print("photometric {d} spp {?d} extra {?d}: want {d}/{s}, got {any}\n", .{ case.photometric, case.spp, case.extra, want.tag, @tagName(want.reason), out.items });
                return error.TestExpectedEqual;
            }
        } else if (out.items.len != 0) {
            std.debug.print("photometric {d} spp {?d} extra {?d}: want no fault, got {any}\n", .{ case.photometric, case.spp, case.extra, out.items });
            return error.TestExpectedEqual;
        }
    }
}

test "a malformed SamplesPerPixel or NumberOfInks reports only its own fault" {
    var spp = [_]Entry{ inline16(tags.photometric, .short, 1, 2), inline16(tags.samples_per_pixel, .short, 2, 0x0003_0003), inline16(tags.extra_samples, .short, 1, 1) };
    try expectFaults(&spp, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.samples_per_pixel, .reason = .count, .raw_type = 3, .raw_count = 2, .raw_slot = 0x0003_0003 } }});
    var inks = [_]Entry{ inline16(tags.photometric, .short, 1, 5), inline16(tags.samples_per_pixel, .short, 1, 7), inline16(tags.number_of_inks, .short, 2, 0x0007_0007) };
    try expectFaults(&inks, &.{.{ .field_invalid = .{ .entry_index = 2, .tag = tags.number_of_inks, .reason = .count, .raw_type = 3, .raw_count = 2, .raw_slot = 0x0007_0007 } }});
}

/// The SamplesPerPixel a photometric implies without extra samples (a
/// Separated image with the default four inks).
fn impliedChannels(photometric: u32) u32 {
    return switch (photometric) {
        2, 6 => 3,
        5 => 4,
        else => 1,
    };
}

const v1_2: Dng = .{ .version = 0x01020000 };
const v1_3: Dng = .{ .version = 0x01030000 };
const v1_4: Dng = .{ .version = Dng.v1_4 };
const v1_5: Dng = .{ .version = 0x01050000 };
const v1_6: Dng = .{ .version = Dng.cited };
const v1_7: Dng = .{ .version = 0x01070000 };
const unknown_version: Dng = .{ .version = null };

/// The reason the single fault on `tag` gives, or null when `entries` (sorted,
/// out-of-line values in `cached`) have no fault at all.
fn expectDng(entries: []Entry, cached: []?[]u8, dng: ?Dng, tag: u16, expected: ?Reason) !void {
    var out = try faultsOfDng(entries, cached, dng);
    defer out.deinit(testing.allocator);
    if (expected) |reason| {
        if (out.items.len != 1 or out.items[0].field_invalid.tag != tag or out.items[0].field_invalid.reason != reason) {
            std.debug.print("tag {d}: expected {s}, got {any}\n", .{ tag, @tagName(reason), out.items });
            return error.TestExpectedEqual;
        }
    } else if (out.items.len != 0) {
        std.debug.print("tag {d}: expected no fault, got {any}\n", .{ tag, out.items });
        return error.TestExpectedEqual;
    }
}

/// One entry checked alone in a DNG context.
fn expectDngOne(dng: ?Dng, entry: Entry, bytes: ?[]u8, expected: ?Reason) !void {
    var entries = [_]Entry{entry};
    var cached = [_]?[]u8{bytes};
    try expectDng(&entries, &cached, dng, entry.tag, expected);
}

test "DNG rows apply only in a DNG file, and only from the edition that added the tag" {
    // DepthFormat (1.5.0.0) is SHORT[1]; count 2 is a count fault.
    const bad = inline16(tags.depth_format, .short, 2, 0);
    try expectDngOne(null, bad, null, null);
    try expectDngOne(v1_4, bad, null, null);
    try expectDngOne(v1_5, bad, null, .count);
    try expectDngOne(v1_7, bad, null, .count);
    // An unknown version keeps type and count rows (D2).
    try expectDngOne(unknown_version, bad, null, .count);
    // A 1.0/1.1 tag applies to every known version.
    try expectDngOne(.{ .version = 0x01000000 }, inline16(tags.cfa_layout, .short, 2, 0x0001_0001), null, .count);
}

test "DNG closed value lists apply up to 1.6.0.0, to a known version, with no private range" {
    const layout = struct {
        fn of(v: u32) Entry {
            return inline16(tags.cfa_layout, .short, 1, v);
        }
    };
    try expectDngOne(v1_6, layout.of(9), null, null);
    try expectDngOne(v1_6, layout.of(10), null, .value);
    try expectDngOne(v1_6, layout.of(0), null, .value);
    try expectDngOne(v1_6, layout.of(40000), null, .value);
    // The 1.0 to 1.6 union: layouts 6 to 9 (added in 1.3.0.0) are valid in 1.2.
    try expectDngOne(v1_2, layout.of(6), null, null);
    // Above 1.6.0.0, or with an unknown version, closed lists are skipped
    // and nothing is recorded (D1, D2).
    try expectDngOne(v1_7, layout.of(10), null, null);
    try expectDngOne(unknown_version, layout.of(10), null, null);
    // A LONG-defined list (ProfileEmbedPolicy 0-3) faults above 65535 too.
    try expectDngOne(v1_6, inline16(tags.profile_embed_policy, .long, 1, 3), null, null);
    try expectDngOne(v1_6, inline16(tags.profile_embed_policy, .long, 1, 70000), null, .value);
    // PreviewColorSpace's "valid values include" is open (D5): no list.
    try expectDngOne(v1_6, inline16(tags.preview_color_space, .long, 1, 9), null, null);
}

test "DNGVersion: four 8-bit values in any unsigned storage, otherwise unknown" {
    var none = [_]Entry{inline16(tags.image_width, .long, 1, 1)};
    const no_dng = Ifd{ .entries = &none, .next_offset = 0, .offset_width = .classic, .allocator = testing.allocator, .cached_values = &.{} };
    try testing.expect(Dng.fromIfd0(&no_dng, .little) == null);
    var shorts = [_]u8{ 1, 0, 6, 0, 0, 0, 0, 0 };
    const cases = [_]struct { entry: Entry, bytes: ?[]u8, version: ?u32 }{
        .{ .entry = inline16(tags.dng_version, .byte, 4, 0x0000_0601), .bytes = null, .version = 0x01060000 },
        .{ .entry = inline16(tags.dng_version, .short, 4, 0), .bytes = &shorts, .version = 0x01060000 },
        .{ .entry = inline16(tags.dng_version, .byte, 3, 0x0000_0601), .bytes = null, .version = null },
        .{ .entry = inline16(tags.dng_version, .ascii, 4, 0x0000_0601), .bytes = null, .version = null },
    };
    for (cases) |case| {
        var entries = [_]Entry{case.entry};
        var cached = [_]?[]u8{case.bytes};
        const dir = Ifd{ .entries = &entries, .next_offset = 0, .offset_width = .classic, .allocator = testing.allocator, .cached_values = &cached };
        try testing.expectEqual(case.version, Dng.fromIfd0(&dir, .little).?.version);
    }
}

test "DNG kinds: FLOAT, SHORT or LONG or RATIONAL, SHORT or RATIONAL, and UTF-8 strings" {
    var four_floats = [_]u8{0} ** 16;
    try expectDngOne(v1_6, inline16(tags.profile_hue_sat_map_dims, .long, 3, 0), @constCast(&[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0 }), null);
    try expectDngOne(v1_6, inline16(tags.baseline_exposure, .rational, 1, 0), @constCast(&[_]u8{ 0, 0, 0, 0, 1, 0, 0, 0 }), .type);
    try expectDngOne(v1_6, inline16(tags.profile_tone_curve, .double, 4, 0), &four_floats, .type);
    // BlackLevel: SHORT, LONG or RATIONAL, not SRATIONAL.
    var rational = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0 };
    try expectDngOne(v1_6, inline16(tags.black_level, .rational, 1, 0), &rational, null);
    try expectDngOne(v1_6, inline16(tags.black_level, .srational, 1, 0), &rational, .type);
    try expectDngOne(v1_6, inline16(tags.black_level, .long, 1, 70000), null, null);
    // AsShotNeutral: SHORT or RATIONAL, so integers hold 16 bits.
    var three_longs = [_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 0x70, 0x11, 1, 0 };
    try expectDngOne(v1_6, inline16(tags.as_shot_neutral, .long, 3, 0), &three_longs, .value);
    // UTF-8 strings, ASCII or BYTE: NUL last, valid UTF-8 before it; inner
    // NULs are not checked (D4).
    const utf8 = struct {
        fn entry(typ: FieldType, len: usize) Entry {
            return inline16(tags.localized_camera_model, typ, len, 0);
        }
    };
    var cafe = [_]u8{ 'C', 'a', 'f', 0xc3, 0xa9, 0 };
    try expectDngOne(v1_6, utf8.entry(.byte, cafe.len), &cafe, null);
    try expectDngOne(v1_6, utf8.entry(.ascii, cafe.len), &cafe, null);
    var unterminated = [_]u8{ 'C', 'a', 'f', 0xc3, 0xa9 };
    try expectDngOne(v1_6, utf8.entry(.byte, unterminated.len), &unterminated, .value);
    var invalid = [_]u8{ 'C', 0xff, 'f', 0 };
    try expectDngOne(v1_6, utf8.entry(.byte, invalid.len), &invalid, .value);
    var inner_nul = [_]u8{ 'A', 0, 'B', 0 };
    try expectDngOne(v1_6, utf8.entry(.byte, inner_nul.len), &inner_nul, null);
    try expectDngOne(v1_6, utf8.entry(.short, 2), @constCast(&[_]u8{ 'A', 0, 0, 0 }), .type);
}

test "DNG count shapes and counts derived from fields in the same IFD" {
    var longs = [_]u8{0} ** 64;
    try expectDngOne(v1_6, inline16(tags.masked_areas, .long, 4, 0), &longs, null);
    try expectDngOne(v1_6, inline16(tags.masked_areas, .long, 8, 0), &longs, null);
    try expectDngOne(v1_6, inline16(tags.masked_areas, .long, 5, 0), &longs, .count);
    var doubles = [_]u8{0} ** 48;
    std.mem.writeInt(u64, doubles[0..8], @bitCast(@as(f64, 1e-5)), .little);
    try expectDngOne(v1_6, inline16(tags.noise_profile, .double, 2, 0), &doubles, null);
    try expectDngOne(v1_6, inline16(tags.noise_profile, .double, 3, 0), &doubles, .count);
    var curve = [_]u8{0} ** 16;
    try expectDngOne(v1_6, inline16(tags.profile_tone_curve, .float, 2, 0), &curve, .count);
    // BlackLevel: BlackLevelRepeatDim 2 x 2, one sample: four values.
    {
        var e = [_]Entry{ inline16(tags.black_level_repeat_dim, .short, 2, 0x0002_0002), inline16(tags.black_level, .long, 4, 0) };
        var c = [_]?[]u8{ null, &longs };
        try expectDng(&e, &c, v1_6, tags.black_level, null);
        e[1].count = 1;
        try expectDng(&e, &c, v1_6, tags.black_level, .count);
    }
    // WhiteLevel: one per sample.
    {
        var e = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 3), inline16(tags.white_level, .long, 1, 255) };
        var c = [_]?[]u8{ null, null };
        try expectDng(&e, &c, v1_6, tags.white_level, .count);
    }
    // BlackLevelDeltaH: one per ActiveArea column, else per image column.
    {
        var area = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 0, 3, 0, 0, 0 };
        var e = [_]Entry{ inline16(tags.black_level_delta_h, .srational, 3, 0), inline16(tags.active_area, .long, 4, 0) };
        var c = [_]?[]u8{ &longs, &area };
        try expectDng(&e, &c, v1_6, tags.black_level_delta_h, null);
        e[0].count = 2;
        try expectDng(&e, &c, v1_6, tags.black_level_delta_h, .count);
        var w = [_]Entry{ inline16(tags.image_width, .long, 1, 2), inline16(tags.black_level_delta_h, .srational, 2, 0) };
        var wc = [_]?[]u8{ null, &longs };
        try expectDng(&w, &wc, v1_6, tags.black_level_delta_h, null);
        var l = [_]Entry{ inline16(tags.image_length, .long, 1, 2), inline16(tags.black_level_delta_v, .srational, 1, 0) };
        var lc = [_]?[]u8{ null, &longs };
        try expectDng(&l, &lc, v1_6, tags.black_level_delta_v, .count);
    }
    // ProfileHueSatMapData1: H * S * V * 3 from ProfileHueSatMapDims.
    {
        var dims = [_]u8{ 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0 };
        var floats = [_]u8{0} ** 48;
        var e = [_]Entry{ inline16(tags.profile_hue_sat_map_dims, .long, 3, 0), inline16(tags.profile_hue_sat_map_data_1, .float, 12, 0) };
        var c = [_]?[]u8{ &dims, &floats };
        try expectDng(&e, &c, v1_6, tags.profile_hue_sat_map_data_1, null);
        e[1].count = 11;
        try expectDng(&e, &c, v1_6, tags.profile_hue_sat_map_data_1, .count);
        // A malformed Dims is its own fault and leaves the data unconstrained.
        e[0].count = 2;
        try expectDng(&e, &c, v1_6, tags.profile_hue_sat_map_dims, .count);
    }
}

test "DNG value rules: DefaultUserCrop, NoiseProfile, ProfileToneCurve, EnhanceParams" {
    const crop = struct {
        fn bytes(r: [4][2]u32) [32]u8 {
            var out: [32]u8 = undefined;
            for (r, 0..) |q, k| {
                std.mem.writeInt(u32, out[8 * k ..][0..4], q[0], .little);
                std.mem.writeInt(u32, out[8 * k + 4 ..][0..4], q[1], .little);
            }
            return out;
        }
    };
    const entry = inline16(tags.default_user_crop, .rational, 4, 0);
    var ok = crop.bytes(.{ .{ 0, 1 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 1 } });
    try expectDngOne(v1_6, entry, &ok, null);
    var inset = crop.bytes(.{ .{ 1, 10 }, .{ 1, 10 }, .{ 9, 10 }, .{ 9, 10 } });
    try expectDngOne(v1_6, entry, &inset, null);
    var empty = crop.bytes(.{ .{ 1, 2 }, .{ 0, 1 }, .{ 1, 2 }, .{ 1, 1 } });
    try expectDngOne(v1_6, entry, &empty, .value);
    var beyond = crop.bytes(.{ .{ 0, 1 }, .{ 0, 1 }, .{ 1, 1 }, .{ 3, 2 } });
    try expectDngOne(v1_6, entry, &beyond, .value);
    var undefined_ratio = crop.bytes(.{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 1 } });
    try expectDngOne(v1_6, entry, &undefined_ratio, .value);
    // NoiseProfile: S > 0, O >= 0.
    const noise = struct {
        fn bytes(s: f64, o: f64) [16]u8 {
            var out: [16]u8 = undefined;
            std.mem.writeInt(u64, out[0..8], @bitCast(s), .little);
            std.mem.writeInt(u64, out[8..16], @bitCast(o), .little);
            return out;
        }
    };
    const n = inline16(tags.noise_profile, .double, 2, 0);
    var good = noise.bytes(1e-5, 0);
    try expectDngOne(v1_6, n, &good, null);
    var zero_s = noise.bytes(0, 0);
    try expectDngOne(v1_6, n, &zero_s, .value);
    var negative_o = noise.bytes(1e-5, -1e-9);
    try expectDngOne(v1_6, n, &negative_o, .value);
    var nan = noise.bytes(std.math.nan(f64), 0);
    try expectDngOne(v1_6, n, &nan, .value);
    // ProfileToneCurve: (0, 0) first, (1, 1) last.
    const curve = struct {
        fn bytes(v: [6]f32) [24]u8 {
            var out: [24]u8 = undefined;
            for (v, 0..) |x, k| std.mem.writeInt(u32, out[4 * k ..][0..4], @bitCast(x), .little);
            return out;
        }
    };
    const t = inline16(tags.profile_tone_curve, .float, 6, 0);
    var straight = curve.bytes(.{ 0, 0, 0.5, 0.6, 1, 1 });
    try expectDngOne(v1_6, t, &straight, null);
    var lifted = curve.bytes(.{ 0, 0.1, 0.5, 0.6, 1, 1 });
    try expectDngOne(v1_6, t, &lifted, .value);
    var short_end = curve.bytes(.{ 0, 0, 0.5, 0.6, 1, 0.9 });
    try expectDngOne(v1_6, t, &short_end, .value);
    // EnhanceParams "is required to be non-null".
    var nul = [_]u8{ 0, 0, 0, 0 };
    try expectDngOne(v1_6, inline16(tags.enhance_params, .ascii, 1, 0), &nul, .value);
    var named = [_]u8{ 'A', 'c', 'm', 'e', 0 };
    try expectDngOne(v1_6, inline16(tags.enhance_params, .ascii, 5, 0), &named, null);
}

test "DNG Chapter 3: BitsPerSample, FillOrder and SampleFormat" {
    var two = [_]u8{ 8, 0, 16, 0 };
    {
        // "The depth must be the same for each sample", whatever the version.
        var e = [_]Entry{ inline16(tags.bits_per_sample, .short, 2, 0), inline16(tags.samples_per_pixel, .short, 1, 2) };
        var c = [_]?[]u8{ &two, null };
        try expectDng(&e, &c, unknown_version, tags.bits_per_sample, .value);
        try expectDng(&e, &c, null, tags.bits_per_sample, null);
    }
    // "Supported values are from 8 to 32" (a closed list).
    try expectDngOne(v1_6, inline16(tags.bits_per_sample, .short, 1, 4), null, .value);
    try expectDngOne(v1_6, inline16(tags.bits_per_sample, .short, 1, 12), null, null);
    try expectDngOne(v1_7, inline16(tags.bits_per_sample, .short, 1, 4), null, null);
    // FillOrder 1 unless every sample is 8, 16 or 32 bits.
    {
        var e = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 12), inline16(tags.fill_order, .short, 1, 2) };
        var c = [_]?[]u8{ null, null };
        try expectDng(&e, &c, v1_6, tags.fill_order, .value);
        try expectDng(&e, &c, unknown_version, tags.fill_order, .value);
        e[0] = inline16(tags.bits_per_sample, .short, 1, 16);
        try expectDng(&e, &c, v1_6, tags.fill_order, null);
    }
    // SampleFormat: 1 before 1.4.0.0; 3 from it, with 16, 24 or 32 bits.
    {
        var e = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 32), inline16(tags.sample_format, .short, 1, 3) };
        var c = [_]?[]u8{ null, null };
        try expectDng(&e, &c, v1_3, tags.sample_format, .value);
        try expectDng(&e, &c, v1_4, tags.sample_format, null);
        e[0] = inline16(tags.bits_per_sample, .short, 1, 8);
        try expectDng(&e, &c, v1_4, tags.bits_per_sample, .value);
        e[1] = inline16(tags.sample_format, .short, 1, 2);
        try expectDng(&e, &c, v1_6, tags.sample_format, .value);
    }
}

test "DNG Chapter 3: Compression and Predictor, gated by edition" {
    const ifd = struct {
        fn of(nst: u32, bits: u32, format: u32, compression: u32, photometric: u32) [5]Entry {
            return .{
                inline16(tags.new_subfile_type, .long, 1, nst),
                inline16(tags.bits_per_sample, .short, 1, bits),
                inline16(tags.compression, .short, 1, compression),
                inline16(tags.photometric, .short, 1, photometric),
                inline16(tags.sample_format, .short, 1, format),
            };
        }
    };
    var c = [_]?[]u8{null} ** 5;
    const cfa = tags.photometric_color_filter_array;
    const linear = tags.photometric_linear_raw;
    // 1 and 7 in every edition; 8 and 34892 only from 1.4.0.0.
    var e = ifd.of(0, 16, 1, 7, cfa);
    try expectDng(&e, &c, v1_2, tags.compression, null);
    e = ifd.of(0, 32, 1, 8, cfa);
    try expectDng(&e, &c, v1_3, tags.compression, .value);
    try expectDng(&e, &c, v1_4, tags.compression, null);
    // Deflate: floating point, 32-bit integer, transparency or depth only.
    e = ifd.of(0, 16, 1, 8, cfa);
    try expectDng(&e, &c, v1_4, tags.compression, .value);
    try expectDng(&e, &c, v1_7, tags.compression, .value);
    e = ifd.of(0, 16, 3, 8, linear);
    try expectDng(&e, &c, v1_4, tags.compression, null);
    e = ifd.of(8, 16, 1, 8, tags.photometric_depth);
    try expectDng(&e, &c, v1_5, tags.compression, null);
    e = ifd.of(4, 16, 1, 8, 1);
    try expectDng(&e, &c, v1_4, tags.compression, null);
    // Lossy JPEG: 8-bit integer LinearRaw or PhotometricMask only.
    e = ifd.of(0, 8, 1, 34892, linear);
    try expectDng(&e, &c, v1_4, tags.compression, null);
    e = ifd.of(0x10004, 8, 1, 34892, tags.photometric_mask);
    try expectDng(&e, &c, v1_4, tags.compression, null);
    e = ifd.of(0, 16, 1, 34892, linear);
    try expectDng(&e, &c, v1_4, tags.compression, .value);
    e = ifd.of(0, 8, 1, 34892, cfa);
    try expectDng(&e, &c, v1_4, tags.compression, .value);
    // Any other compression is a fault up to 1.6.0.0; the list is skipped
    // above it and for an unknown version.
    e = ifd.of(0, 16, 1, 5, cfa);
    try expectDng(&e, &c, v1_6, tags.compression, .value);
    try expectDng(&e, &c, v1_7, tags.compression, null);
    try expectDng(&e, &c, unknown_version, tags.compression, null);
    try expectDng(&e, &c, null, tags.compression, null);
    // Predictor with Deflate: 1, 2, 3, 34892-34895.
    {
        var p = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 32), inline16(tags.compression, .short, 1, 8), inline16(tags.photometric, .short, 1, cfa), inline16(tags.predictor, .short, 1, 34893) };
        var pc = [_]?[]u8{null} ** 4;
        try expectDng(&p, &pc, v1_4, tags.predictor, null);
        p[3] = inline16(tags.predictor, .short, 1, 34896);
        try expectDng(&p, &pc, v1_4, tags.predictor, .value);
    }
}

test "DNG Chapter 3: PhotometricInterpretation by the IFD's role" {
    const pair = struct {
        // 8 bits, with the SamplesPerPixel the photometric implies, so that
        // only the role list is under test.
        fn of(nst: u32, photometric: u32) [4]Entry {
            const ch = impliedChannels(photometric);
            const eights: u32 = @as(u32, 0x0808_0808) >> @intCast(8 * (4 - ch));
            return .{ inline16(tags.new_subfile_type, .long, 1, nst), inline16(tags.bits_per_sample, .byte, ch, eights), inline16(tags.photometric, .short, 1, photometric), inline16(tags.samples_per_pixel, .short, 1, ch) };
        }
    };
    var c = [_]?[]u8{null} ** 4;
    const cases = [_]struct { nst: u32, photometric: u32, ok: bool }{
        .{ .nst = 0, .photometric = tags.photometric_color_filter_array, .ok = true },
        .{ .nst = 0, .photometric = tags.photometric_linear_raw, .ok = true },
        .{ .nst = 0, .photometric = 2, .ok = false },
        .{ .nst = 1, .photometric = 6, .ok = true },
        .{ .nst = 1, .photometric = tags.photometric_linear_raw, .ok = true },
        .{ .nst = 1, .photometric = 5, .ok = false },
        .{ .nst = 0x10001, .photometric = tags.photometric_color_filter_array, .ok = false },
        .{ .nst = 16, .photometric = tags.photometric_linear_raw, .ok = true },
        .{ .nst = 16, .photometric = tags.photometric_color_filter_array, .ok = true },
        .{ .nst = 16, .photometric = 2, .ok = false },
        .{ .nst = 8, .photometric = tags.photometric_depth, .ok = true },
        .{ .nst = 9, .photometric = 1, .ok = false },
        .{ .nst = 0x10004, .photometric = tags.photometric_mask, .ok = true },
        .{ .nst = 0x10004, .photometric = 1, .ok = false },
        // Transparency masks and unknown roles take the union.
        .{ .nst = 4, .photometric = 1, .ok = true },
        .{ .nst = 7, .photometric = tags.photometric_mask, .ok = true },
        .{ .nst = 7, .photometric = 5, .ok = false },
    };
    for (cases) |case| {
        var e = pair.of(case.nst, case.photometric);
        expectDng(&e, &c, v1_6, tags.photometric, if (case.ok) null else .value) catch |err| {
            std.debug.print("NewSubFileType 0x{x}, photometric {d}\n", .{ case.nst, case.photometric });
            return err;
        };
    }
    // No role list without a DNG claim, above 1.6.0.0, or for an unknown version.
    var e = pair.of(0, 2);
    try expectDng(&e, &c, null, tags.photometric, null);
    try expectDng(&e, &c, v1_7, tags.photometric, null);
    try expectDng(&e, &c, unknown_version, tags.photometric, null);
}

test "DNG with an unknown version: type and count only, no value rules (D2)" {
    var empty = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
    const crop = inline16(tags.default_user_crop, .rational, 4, 0);
    try expectDngOne(v1_6, crop, &empty, .value);
    try expectDngOne(v1_7, crop, &empty, .value);
    try expectDngOne(unknown_version, crop, &empty, null);
    try expectDngOne(unknown_version, inline16(tags.default_user_crop, .rational, 3, 0), &empty, .count);
}

test "DNG MaskSubArea: invalid only when out of bounds under both readings" {
    const area = struct {
        fn bytes(t: u32, l: u32, w: u32, h: u32) [16]u8 {
            var out: [16]u8 = undefined;
            for ([_]u32{ t, l, w, h }, 0..) |v, k| std.mem.writeInt(u32, out[4 * k ..][0..4], v, .little);
            return out;
        }
    };
    // A 200 x 100 cropped mask.
    const cases = [_]struct { t: u32, l: u32, w: u32, h: u32, ok: bool }{
        // Fits the consistent reading (T + length <= H, L + width <= W),
        // not the literal one (T + width > H): no fault.
        .{ .t = 0, .l = 0, .w = 200, .h = 100, .ok = true },
        .{ .t = 0, .l = 0, .w = 300, .h = 300, .ok = true },
        // Out of bounds both ways.
        .{ .t = 50, .l = 50, .w = 200, .h = 100, .ok = false },
        .{ .t = 0, .l = 0, .w = 50, .h = 50, .ok = false },
    };
    for (cases) |case| {
        var b = area.bytes(case.t, case.l, case.w, case.h);
        var e = [_]Entry{ inline16(tags.image_width, .long, 1, 200), inline16(tags.image_length, .long, 1, 100), inline16(tags.mask_sub_area, .long, 4, 0) };
        var c = [_]?[]u8{ null, null, &b };
        try expectDng(&e, &c, v1_6, tags.mask_sub_area, if (case.ok) null else .value);
    }
}

test "ISO 8601 complete date-time for PreviewDateTime" {
    for ([_][]const u8{
        "2017-01-31T19:30:23Z\x00",
        "20170131T193023Z\x00",
        "2017-01-31T19:30:23+01:00\x00",
        "20170131T193023-0500\x00",
        "2016-02-29T23:59:60.5-05:00\x00",
        "2017-01-31T19:30:23,25Z\x00",
        "2017-01-31T19:30:23\x00",
        "2017-01-31T24:00:00Z\x00",
        "2000-02-29T00:00:00Z\x00",
    }) |text| {
        if (!isIso8601(text)) {
            std.debug.print("rejected {s}\n", .{text});
            return error.TestExpectedEqual;
        }
    }
    for ([_][]const u8{
        "2017:01:31 19:30:23\x00", // TIFF DateTime
        "2017-01-31 19:30:23Z\x00",
        "2017-01-31T193023Z\x00", // mixed forms
        "2017-01-31T19:30Z\x00", // reduced precision
        "2017-02-29T00:00:00Z\x00",
        "1900-02-29T00:00:00Z\x00",
        "2017-13-01T00:00:00Z\x00",
        "2017-01-31T24:00:01Z\x00",
        "2017-01-31T24:00:00.5Z\x00",
        "2017-01-31T19:30:23+01\x00",
        "2017-01-31T19:30:23+0100\x00", // basic offset in the extended form
        "2017-01-31T19:30:23.Z\x00",
        "2017-01-31T19:30:23Zx\x00",
        "\x00",
    }) |text| {
        if (isIso8601(text)) {
            std.debug.print("accepted {s}\n", .{text});
            return error.TestExpectedEqual;
        }
    }
    var good = "2017-01-31T19:30:23Z\x00".*;
    try expectDngOne(v1_6, inline16(tags.preview_date_time, .ascii, good.len, 0), &good, null);
    var tiff_style = "2017:01:31 19:30:23\x00".*;
    try expectDngOne(v1_6, inline16(tags.preview_date_time, .ascii, tiff_style.len, 0), &tiff_style, .value);
}

test "DNG depth maps and semantic masks: single channel of the stated pixel types" {
    const mask = struct {
        fn of(nst: u32, bits: u32, photometric: u32) [3]Entry {
            return .{ inline16(tags.new_subfile_type, .long, 1, nst), inline16(tags.bits_per_sample, .short, 1, bits), inline16(tags.photometric, .short, 1, photometric) };
        }
    };
    var c3 = [_]?[]u8{null} ** 3;
    const m = tags.photometric_mask;
    const d = tags.photometric_depth;
    var e = mask.of(0x10004, 8, m);
    try expectDng(&e, &c3, v1_6, tags.photometric, null);
    e = mask.of(0x10004, 16, m);
    try expectDng(&e, &c3, v1_6, tags.photometric, null);
    e = mask.of(0x10004, 12, m);
    try expectDng(&e, &c3, v1_6, tags.bits_per_sample, .value);
    // A 32-bit integer mask: only floating point allows 32 bits.
    e = mask.of(0x10004, 32, m);
    try expectDng(&e, &c3, v1_6, tags.bits_per_sample, .value);
    // Gated: masks from 1.6.0.0, closed lists up to 1.6.0.0.
    e = mask.of(0x10004, 12, m);
    try expectDng(&e, &c3, v1_5, tags.bits_per_sample, null);
    try expectDng(&e, &c3, v1_7, tags.bits_per_sample, null);
    // Depth maps from 1.5.0.0: 8 or 16-bit unsigned.
    e = mask.of(8, 16, d);
    try expectDng(&e, &c3, v1_5, tags.photometric, null);
    e = mask.of(9, 12, d);
    try expectDng(&e, &c3, v1_5, tags.bits_per_sample, .value);
    try expectDng(&e, &c3, v1_4, tags.bits_per_sample, null);
    {
        // A 32-bit floating point mask is allowed; a floating point depth map
        // or a 16-bit floating point mask is not.
        var f = [_]Entry{ inline16(tags.new_subfile_type, .long, 1, 0x10004), inline16(tags.bits_per_sample, .short, 1, 32), inline16(tags.photometric, .short, 1, m), inline16(tags.sample_format, .short, 1, 3) };
        var c4 = [_]?[]u8{null} ** 4;
        try expectDng(&f, &c4, v1_6, tags.photometric, null);
        f[1] = inline16(tags.bits_per_sample, .short, 1, 16);
        try expectDng(&f, &c4, v1_6, tags.sample_format, .value);
        f[0] = inline16(tags.new_subfile_type, .long, 1, 8);
        f[1] = inline16(tags.bits_per_sample, .short, 1, 32);
        f[2] = inline16(tags.photometric, .short, 1, d);
        try expectDng(&f, &c4, v1_6, tags.bits_per_sample, .value);
    }
    {
        // Single channel.
        var two = [_]u8{ 8, 0, 8, 0 };
        var s = [_]Entry{ inline16(tags.new_subfile_type, .long, 1, 0x10004), inline16(tags.bits_per_sample, .short, 2, 0), inline16(tags.photometric, .short, 1, m), inline16(tags.samples_per_pixel, .short, 1, 2) };
        var sc = [_]?[]u8{ null, &two, null, null };
        try expectDng(&s, &sc, v1_6, tags.samples_per_pixel, .value);
    }
    {
        // BitsPerSample absent is 1 bit: reported on NewSubFileType.
        var n = [_]Entry{ inline16(tags.new_subfile_type, .long, 1, 0x10004), inline16(tags.photometric, .short, 1, m) };
        var nc = [_]?[]u8{null} ** 2;
        try expectDng(&n, &nc, v1_6, tags.new_subfile_type, .value);
    }
}

test "the pending constraints are pinned" {
    // Removing one of these must come with a row (and its regressions) that
    // checks it, or with a ruling that it is not a constraint.
    const expected = [_][]const u8{
        "NewSubfileType bits",
    };
    try testing.expectEqual(expected.len, pending.len);
    for (expected, pending) |want, got| try testing.expectEqualStrings(want, got.what);
}

test "entry offsets and payload layout" {
    try testing.expectEqual(@as(u64, 8 + 2 + 3 * 12), entryOffset(8, 3, .classic));
    try testing.expectEqual(@as(u64, 16 + 8 + 3 * 20), entryOffset(16, 3, .big));
    var buf: [max_payload_len]u8 = undefined;
    const unsorted = encodePayload(.{ .unsorted = .{ .entry_index = 2, .tag = 296, .prev_tag = 8476 } }, 1, 34, &buf);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 2, 0, 0, 0, 34, 0, 0, 0, 0, 0, 0, 0, 0x28, 0x01, 0x1c, 0x21 }, unsorted);
    const invalid = encodePayload(.{ .field_invalid = .{ .entry_index = 5, .tag = 274, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 257 } }, 0, 70, &buf);
    try testing.expectEqual(@as(usize, field_invalid_payload_len), invalid.len);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x01, 3, 0, 3, 0 }, invalid[16..22]);
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, invalid[22..30], .little));
    try testing.expectEqual(@as(u64, 257), std.mem.readInt(u64, invalid[30..38], .little));
}
