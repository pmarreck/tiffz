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
};

const Rule = struct {
    tag: u16,
    kind: Kind,
    count: Count,
    /// Inclusive public-range value ranges, or null when unconstrained.
    values: ?[]const [2]u16 = null,
    extras: []const Extra = &.{},
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
    .{ .tag = tags.image_layer, .kind = .unsigned_long, .count = .two, .extras = &.{.image_layer}, .citation = "RFC 3949 p. 68 (RFC 2301: SHORT or LONG, which p. 16 widening also allows)" },
    .{ .tag = tags.image_source_data, .kind = .undefined, .count = .any, .citation = "Adobe Photoshop TIFF Technical Notes (2002)" },
};

/// Constraints a claimed specification states that are not yet checked,
/// each waiting for a named reason. Kept as data so that none silently
/// disappears; a test pins this list.
pub const Pending = struct { what: []const u8, citation: []const u8, waits_for: []const u8 };
pub const pending = [_]Pending{
    .{ .what = "NewSubfileType bits", .citation = "TIFF 6.0 p. 36", .waits_for = "DNG (TIFF-FX adds bit 4, MRC, RFC 3949 p. 64)" },
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

/// Append every fault in `dir` to `out`, in entry order.
pub fn check(
    allocator: std.mem.Allocator,
    dir: *const Ifd,
    endian: Endian,
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
        if (fieldReason(dir, i, rule.*, endian)) |reason| {
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

fn fieldReason(dir: *const Ifd, index: usize, rule: Rule, endian: Endian) ?Reason {
    const entry = dir.entries[index];
    const type_ok = switch (rule.kind) {
        .unsigned_short, .unsigned_long => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long,
        .offsets_or_counts => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long or
            (entry.field_type == .long8 and dir.offset_width == .big),
        .rational => entry.field_type == .rational,
        .srational => entry.field_type == .srational,
        .unsigned_byte => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long,
        .integer32 => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long or entry.field_type == .slong,
        .bytes => entry.field_type == .byte,
        .undefined => entry.field_type == .undefined,
        .ifd_offsets => entry.field_type == .long or entry.raw_type == 13 or
            (entry.field_type == .ifd8 and dir.offset_width == .big),
        .ascii => entry.field_type == .ascii,
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
    };
    if (!count_ok) return .count;

    const bytes = dir.entryValueSlice(index);
    switch (rule.kind) {
        .rational, .srational, .bytes, .undefined, .ifd_offsets, .integer32 => return null,
        .ascii => {
            if (!isAscii(bytes)) return .value;
            if (hasExtra(rule, .date_time) and !isDateTime(bytes)) return .value;
            return null;
        },
        .unsigned_byte, .unsigned_short, .unsigned_long, .offsets_or_counts => {},
    }
    const max: u64 = switch (rule.kind) {
        .unsigned_byte => std.math.maxInt(u8),
        .unsigned_short => std.math.maxInt(u16),
        .unsigned_long => std.math.maxInt(u32),
        else => std.math.maxInt(u64),
    };
    var i: usize = 0;
    while (i < entry.count) : (i += 1) {
        const value = element(bytes, entry.field_type, i, endian) orelse return .count;
        if (value > max) return .value;
        if (hasExtra(rule, .multiple_of_16) and value % 16 != 0) return .value;
        const ranges = rule.values orelse continue;
        if (value >= 32768) continue; // private range, not a violation
        if (!inRanges(@intCast(value), ranges)) return .value;
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
        .multiple_of_16, .date_time => {},
    };
    return null;
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

fn inRanges(value: u16, ranges: []const [2]u16) bool {
    for (ranges) |range| {
        if (value >= range[0] and value <= range[1]) return true;
    }
    return false;
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
    const dir = Ifd{
        .entries = entries,
        .next_offset = 0,
        .offset_width = .classic,
        .allocator = testing.allocator,
        .cached_values = cached,
    };
    var out: std.ArrayListUnmanaged(Fault) = .empty;
    try check(testing.allocator, &dir, .little, &out);
    return out;
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
        for (ranges) |range| {
            for ([_]u16{ range[0], range[1] }) |v| {
                if (rule.tag == tags.photometric) {
                    // With the SamplesPerPixel the photometric implies.
                    var ok = [_]Entry{ inline16(rule.tag, .short, 1, v), inline16(tags.samples_per_pixel, .short, 1, impliedChannels(v)) };
                    try expectFaults(&ok, &.{});
                } else {
                    var ok = [_]Entry{inline16(rule.tag, .short, 1, v)};
                    try expectFaults(&ok, &.{});
                }
            }
            for ([_]u32{ range[0] -% 1, range[1] + 1 }) |v| {
                if (v >= 32768) continue; // private, never a fault
                var inside = false;
                for (ranges) |other| inside = inside or (v >= other[0] and v <= other[1]);
                if (inside) continue;
                var bad = [_]Entry{inline16(rule.tag, .short, 1, v)};
                try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = rule.tag, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = v } }});
            }
            checked += 1;
        }
        var two = [_]Entry{inline16(rule.tag, .short, 2, ranges[0][0] | (@as(u32, ranges[0][0]) << 16))};
        try expectFaults(&two, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = rule.tag, .reason = .count, .raw_type = 3, .raw_count = 2, .raw_slot = ranges[0][0] | (@as(u32, ranges[0][0]) << 16) } }});
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
    var buf: [64]u8 = undefined;
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
    for ([_]u16{ 0, 253, 257 + 10000, 34737, 65535 }) |tag| try testing.expect(ruleFor(tag) == null);
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
            try check(testing.allocator, &dir, .little, &out);
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
