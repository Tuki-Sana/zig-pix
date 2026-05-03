/*
 * png_decode.c — libpng C bridge for pict-zig-engine
 *
 * Exported symbols:
 *   pict_png_decode     — decode PNG bytes → raw RGB/RGBA pixels + optional ICC (iCCP)
 *   pict_png_free       — free pixel buffer from pict_png_decode
 *   pict_png_icc_free   — free ICC buffer from pict_png_decode (malloc)
 *   pict_png_encode     — encode raw RGB/RGBA → PNG bytes (compression, ICC embedding)
 */

#include <stdio.h>   /* libpng may need FILE */
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <png.h>

void pict_png_icc_free(unsigned char *icc);

/* ── In-memory read state ───────────────────────────────────────────────── */

typedef struct {
    const unsigned char *data;
    unsigned long        len;
    unsigned long        offset;
} PngReadState;

static void png_mem_read(png_structp png_ptr, png_bytep out, size_t length) {
    PngReadState *s = (PngReadState *)png_get_io_ptr(png_ptr);
    /* Compare via subtraction to avoid addition overflow: length > remaining */
    if (length > s->len - s->offset)
        png_error(png_ptr, "PNG: read past end of buffer");
    memcpy(out, s->data + s->offset, length);
    s->offset += (unsigned long)length;
}

/* ── In-memory write state (for test encoder) ───────────────────────────── */

typedef struct {
    unsigned char *data;
    unsigned long  len;
    unsigned long  cap;
} PngWriteState;

static void png_mem_write(png_structp png_ptr, png_bytep in, size_t length) {
    PngWriteState *s = (PngWriteState *)png_get_io_ptr(png_ptr);
    /* Guard new_len addition against overflow. */
    if (length > (size_t)-1 - s->len)
        png_error(png_ptr, "PNG: write buffer overflow");
    unsigned long new_len = s->len + (unsigned long)length;
    if (new_len > s->cap) {
        /* Guard new_cap * 2 against overflow; fall back to new_len if needed. */
        unsigned long new_cap = (new_len <= (size_t)-1 / 2) ? new_len * 2 : new_len;
        if (new_cap < 4096) new_cap = 4096;
        unsigned char *nd = (unsigned char *)realloc(s->data, new_cap);
        if (!nd) png_error(png_ptr, "PNG: OOM during write");
        s->data = nd;
        s->cap  = new_cap;
    }
    memcpy(s->data + s->len, in, length);
    s->len = new_len;
}

static void png_mem_flush(png_structp png_ptr) { (void)png_ptr; }

/* ── Decode: in-memory PNG → raw RGB/RGBA pixels ────────────────────────── */

/*
 * Returns  0  on success.
 *         -1  on PNG error (corrupt/unsupported).
 *         -2  on OOM.
 *
 * On success, *out_data is allocated with malloc() and must be freed with
 * pict_png_free().  Pixels are tightly-packed, row-major:
 *   byte offset = row * width * channels + col * channels
 *
 * If out_icc / out_icc_len are non-NULL and the PNG has an iCCP chunk,
 * *out_icc is set to a malloc()'d copy of the profile and *out_icc_len set.
 * Otherwise *out_icc = NULL and *out_icc_len = 0.
 * When non-NULL, free *out_icc with pict_png_icc_free().
 *
 * Output is always 8-bit.  channels = 3 (RGB) or 4 (RGBA).
 * Grayscale images are converted to RGB via PNG_TRANSFORM_GRAY_TO_RGB.
 * 16-bit images are reduced to 8-bit via PNG_TRANSFORM_STRIP_16.
 */
int pict_png_decode(
    const unsigned char *src,
    unsigned long        src_len,
    unsigned char      **out_data,
    unsigned int        *out_width,
    unsigned int        *out_height,
    unsigned int        *out_channels,
    unsigned char      **out_icc,
    unsigned int        *out_icc_len)
{
    png_structp    png_ptr  = NULL;
    png_infop      info_ptr = NULL;
    unsigned char *data     = NULL;

    if (out_icc) *out_icc = NULL;
    if (out_icc_len) *out_icc_len = 0;

    png_ptr = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png_ptr) return -1;

    info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_read_struct(&png_ptr, NULL, NULL);
        return -1;
    }

    if (setjmp(png_jmpbuf(png_ptr))) {
        free(data);
        if (out_icc && *out_icc) {
            pict_png_icc_free(*out_icc);
            *out_icc = NULL;
        }
        if (out_icc_len) *out_icc_len = 0;
        png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
        return -1;
    }

    PngReadState rs = { src, src_len, 0 };
    png_set_read_fn(png_ptr, &rs, png_mem_read);

    /*
     * Transforms applied in a single png_read_png call:
     *   STRIP_16    → 16-bit samples → 8-bit
     *   EXPAND      → palette / bit-depth / tRNS expansion
     *   GRAY_TO_RGB → grayscale → RGB (uniform 3- or 4-channel output)
     *   PACKING     → sub-byte samples → byte-aligned
     */
    png_read_png(png_ptr, info_ptr,
        PNG_TRANSFORM_STRIP_16
      | PNG_TRANSFORM_EXPAND
      | PNG_TRANSFORM_GRAY_TO_RGB
      | PNG_TRANSFORM_PACKING,
        NULL);

    unsigned int w  = png_get_image_width(png_ptr, info_ptr);
    unsigned int h  = png_get_image_height(png_ptr, info_ptr);
    png_byte     ct = png_get_color_type(png_ptr, info_ptr);
    /* After transforms: ct is PNG_COLOR_TYPE_RGB or PNG_COLOR_TYPE_RGBA */
    unsigned int ch = (ct & PNG_COLOR_MASK_ALPHA) ? 4u : 3u;

    /* Overflow-safe size calculation. */
    if (ch != 0 && w > (size_t)-1 / ch) {
        png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
        return -1;
    }
    unsigned long row_stride = (unsigned long)w * ch;
    if (h != 0 && row_stride > (size_t)-1 / h) {
        png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
        return -1;
    }
    unsigned long total = (unsigned long)h * row_stride;

    data = (unsigned char *)malloc(total);
    if (!data) {
        png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
        return -2;
    }

    png_bytepp rows = png_get_rows(png_ptr, info_ptr);
    for (unsigned int y = 0; y < h; y++)
        memcpy(data + (unsigned long)y * row_stride, rows[y], row_stride);

    /* Optional iCCP (must copy before png_destroy_read_struct invalidates profile pointer) */
    if (out_icc && out_icc_len && png_get_valid(png_ptr, info_ptr, PNG_INFO_iCCP)) {
        png_charp     icc_name = NULL;
        int           compression_type = 0;
        png_bytep     profile = NULL;
        png_uint_32   proflen = 0;
        if (png_get_iCCP(png_ptr, info_ptr, &icc_name, &compression_type, &profile, &proflen)
            && profile != NULL && proflen > 0) {
            unsigned char *icc_copy = (unsigned char *)malloc((size_t)proflen);
            if (!icc_copy) {
                free(data);
                png_destroy_read_struct(&png_ptr, &info_ptr, NULL);
                return -2;
            }
            memcpy(icc_copy, profile, (size_t)proflen);
            *out_icc     = icc_copy;
            *out_icc_len = (unsigned int)proflen;
        }
    }

    png_destroy_read_struct(&png_ptr, &info_ptr, NULL);

    *out_data     = data;
    *out_width    = w;
    *out_height   = h;
    *out_channels = ch;
    return 0;
}

void pict_png_free(unsigned char *data) { free(data); }

void pict_png_icc_free(unsigned char *icc) { free(icc); }

/* ── Encode: raw RGB/RGBA pixels → PNG bytes ────────────────────────────── */

/*
 * Encode raw RGB/RGBA pixels to PNG in memory.
 * channels must be 3 (RGB) or 4 (RGBA); any other value returns -1.
 * compression: zlib level 0-9 (out-of-range is clamped to 6).
 * icc / icc_len: optional ICC profile embedded as iCCP chunk (NULL to skip).
 * Returns 0 on success, -1 on error.
 * *out_png allocated with malloc; free with pict_png_free().
 */
int pict_png_encode(
    const unsigned char *pixels,
    unsigned int         width,
    unsigned int         height,
    unsigned int         channels,
    int                  compression,
    const unsigned char *icc,
    size_t               icc_len,
    unsigned char      **out_png,
    size_t              *out_len)
{
    if (!pixels || !out_png || !out_len) return -1;
    if (channels != 3 && channels != 4) return -1;
    if (width == 0 || height == 0) return -1;
    /* Overflow-safe row stride check */
    if (width > (size_t)-1 / channels) return -1;

    if (compression < 0 || compression > 9) compression = 6;

    png_structp png_ptr  = NULL;
    png_infop   info_ptr = NULL;

    png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png_ptr) return -1;

    info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_write_struct(&png_ptr, NULL);
        return -1;
    }

    PngWriteState ws = { NULL, 0, 0 };
    if (setjmp(png_jmpbuf(png_ptr))) {
        free(ws.data);
        png_destroy_write_struct(&png_ptr, &info_ptr);
        return -1;
    }

    png_set_write_fn(png_ptr, &ws, png_mem_write, png_mem_flush);
    png_set_compression_level(png_ptr, compression);

    int color_type = (channels == 4) ? PNG_COLOR_TYPE_RGBA : PNG_COLOR_TYPE_RGB;
    png_set_IHDR(png_ptr, info_ptr,
        width, height, 8, color_type,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT);

    if (icc && icc_len > 0 && icc_len <= (png_uint_32)-1)
        png_set_iCCP(png_ptr, info_ptr, "ICC", PNG_COMPRESSION_TYPE_DEFAULT,
                     (png_const_bytep)icc, (png_uint_32)icc_len);

    png_write_info(png_ptr, info_ptr);

    size_t row_stride = (size_t)width * channels;
    for (unsigned int y = 0; y < height; y++)
        png_write_row(png_ptr, (png_const_bytep)(pixels + (size_t)y * row_stride));

    png_write_end(png_ptr, info_ptr);
    png_destroy_write_struct(&png_ptr, &info_ptr);

    *out_png = ws.data;
    *out_len = (size_t)ws.len;
    return 0;
}
