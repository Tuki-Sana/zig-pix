/*
 * jpeg_decode.c — libjpeg-turbo C bridge for pict-zig-engine
 *
 * Provides a safe, malloc-based wrapper around the libjpeg decompress/compress
 * API. Error handling uses setjmp/longjmp so that JPEG errors do not abort().
 *
 * Exported symbols:
 *   pict_jpeg_decode           — decode JPEG bytes → raw RGB + optional ICC (APP2)
 *   pict_jpeg_free             — free pixel buffer from decode / JPEG from encode
 *   pict_jpeg_icc_free         — free ICC buffer from pict_jpeg_decode (malloc)
 *   pict_jpeg_encode           — encode raw RGB → JPEG bytes (used by tests)
 *   pict_jpeg_encode_with_icc  — encode RGB → JPEG with embedded ICC (tests)
 */

#include <stdio.h>   /* jpeglib.h needs FILE */
#include <stdlib.h>
#include <setjmp.h>
#include <jpeglib.h>
#include <jerror.h>

/* ── Extended error manager ─────────────────────────────────────────────── */

typedef struct {
    struct jpeg_error_mgr pub; /* must be first */
    jmp_buf               jmpbuf;
} PictJpegErr;

static void pict_error_exit(j_common_ptr cinfo) {
    PictJpegErr *err = (PictJpegErr *)cinfo->err;
    longjmp(err->jmpbuf, 1);
}

/* ── Decode: in-memory JPEG → raw RGB pixels ────────────────────────────── */

/*
 * Returns  0  on success.
 *         -1  on JPEG error (corrupt/unsupported data).
 *         -2  on allocation failure (OOM).
 *
 * On success, *out_data is allocated with malloc() and must be freed with
 * pict_jpeg_free().  The pixel layout is tightly-packed, row-major RGB:
 *   byte offset = row * width * 3 + col * 3
 *
 * If out_icc and out_icc_len are both non-NULL, APP2 ICC markers are preserved
 * during read_header; after scanlines, jpeg_read_icc_profile() fills
 * *out_icc (malloc) and *out_icc_len, or leaves *out_icc = NULL / len 0 if none.
 * Free *out_icc with pict_jpeg_icc_free() when non-NULL.
 */
int pict_jpeg_decode(
    const unsigned char *src,
    unsigned long        src_len,
    unsigned char      **out_data,
    unsigned int        *out_width,
    unsigned int        *out_height,
    unsigned int        *out_channels,
    unsigned char      **out_icc,
    unsigned int        *out_icc_len)
{
    PictJpegErr jerr;
    struct jpeg_decompress_struct cinfo;

    cinfo.err              = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit    = pict_error_exit;

    if (setjmp(jerr.jmpbuf)) {
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }

    if (out_icc)
        *out_icc = NULL;
    if (out_icc_len)
        *out_icc_len = 0;

    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, src, src_len);
    if (out_icc && out_icc_len)
        jpeg_save_markers(&cinfo, JPEG_APP0 + 2, 0xFFFF);
    (void)jpeg_read_header(&cinfo, TRUE);

    cinfo.out_color_space = JCS_RGB;
    (void)jpeg_start_decompress(&cinfo);

    unsigned int  w  = cinfo.output_width;
    unsigned int  h  = cinfo.output_height;
    unsigned int  ch = (unsigned int)cinfo.output_components; /* 3 for JCS_RGB */

    /* Overflow-safe size calculation: reject if w*ch or h*row_stride wraps. */
    if (ch != 0 && w > (size_t)-1 / ch) {
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    unsigned long row_stride = (unsigned long)w * ch;
    if (h != 0 && row_stride > (size_t)-1 / h) {
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    unsigned long total = (unsigned long)h * row_stride;

    unsigned char *data = malloc(total);
    if (!data) {
        (void)jpeg_finish_decompress(&cinfo);
        jpeg_destroy_decompress(&cinfo);
        return -2;
    }

    while (cinfo.output_scanline < cinfo.output_height) {
        unsigned char *row = data + (unsigned long)cinfo.output_scanline * row_stride;
        (void)jpeg_read_scanlines(&cinfo, &row, 1);
    }

    if (out_icc && out_icc_len) {
        JOCTET *icc_profile = NULL;
        unsigned int icc_len = 0;
        if (jpeg_read_icc_profile(&cinfo, &icc_profile, &icc_len)) {
            *out_icc = (unsigned char *)icc_profile;
            *out_icc_len = icc_len;
        }
    }

    (void)jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);

    *out_data     = data;
    *out_width    = w;
    *out_height   = h;
    *out_channels = ch;
    return 0;
}

/* Free a buffer allocated by pict_jpeg_decode or pict_jpeg_encode. */
void pict_jpeg_free(unsigned char *data) {
    free(data);
}

void pict_jpeg_icc_free(unsigned char *icc) {
    free(icc);
}

/* ── Encode: raw RGB → in-memory JPEG (used by tests) ───────────────────── */

/*
 * Returns  0  on success.
 *         -1  on JPEG error.
 *
 * On success, *out_jpeg is allocated by libjpeg internals (malloc) and must
 * be freed with pict_jpeg_free().  quality is in [1, 100].
 */
int pict_jpeg_encode(
    const unsigned char *rgb,
    unsigned int         width,
    unsigned int         height,
    int                  quality,
    unsigned char      **out_jpeg,
    unsigned long       *out_len)
{
    PictJpegErr jerr;
    struct jpeg_compress_struct cinfo;

    cinfo.err           = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = pict_error_exit;

    if (setjmp(jerr.jmpbuf)) {
        jpeg_destroy_compress(&cinfo);
        return -1;
    }

    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, out_jpeg, out_len);

    cinfo.image_width      = width;
    cinfo.image_height     = height;
    cinfo.input_components = 3;
    cinfo.in_color_space   = JCS_RGB;

    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);
    jpeg_start_compress(&cinfo, TRUE);

    unsigned long row_stride = (unsigned long)width * 3;
    while (cinfo.next_scanline < cinfo.image_height) {
        const unsigned char *row = rgb + (unsigned long)cinfo.next_scanline * row_stride;
        (void)jpeg_write_scanlines(&cinfo, (JSAMPARRAY)&row, 1);
    }

    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    return 0;
}

/*
 * Like pict_jpeg_encode but embeds an ICC profile via APP2 (jpeg_write_icc_profile).
 * icc must be non-NULL and icc_len > 0. Used by unit tests for ICC round-trip.
 */
int pict_jpeg_encode_with_icc(
    const unsigned char *rgb,
    unsigned int         width,
    unsigned int         height,
    int                  quality,
    const unsigned char *icc,
    unsigned int         icc_len,
    unsigned char      **out_jpeg,
    unsigned long       *out_len)
{
    PictJpegErr jerr;
    struct jpeg_compress_struct cinfo;

    if (!icc || icc_len == 0)
        return -1;

    cinfo.err           = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = pict_error_exit;

    if (setjmp(jerr.jmpbuf)) {
        jpeg_destroy_compress(&cinfo);
        return -1;
    }

    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, out_jpeg, out_len);

    cinfo.image_width      = width;
    cinfo.image_height     = height;
    cinfo.input_components = 3;
    cinfo.in_color_space   = JCS_RGB;

    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);
    jpeg_start_compress(&cinfo, TRUE);
    jpeg_write_icc_profile(&cinfo, icc, icc_len);

    unsigned long row_stride = (unsigned long)width * 3;
    while (cinfo.next_scanline < cinfo.image_height) {
        const unsigned char *row = rgb + (unsigned long)cinfo.next_scanline * row_stride;
        (void)jpeg_write_scanlines(&cinfo, (JSAMPARRAY)&row, 1);
    }

    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    return 0;
}
