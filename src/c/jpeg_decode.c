/*
 * jpeg_decode.c — libjpeg-turbo C bridge for pict-zig-engine
 *
 * Provides a safe, malloc-based wrapper around the libjpeg decompress/compress
 * API. Error handling uses setjmp/longjmp so that JPEG errors do not abort().
 *
 * Exported symbols:
 *   pict_jpeg_decode   — decode JPEG bytes → raw RGB pixels
 *   pict_jpeg_free     — free buffers allocated by this module
 *   pict_jpeg_encode   — encode raw RGB → JPEG bytes (used by tests)
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
 */
int pict_jpeg_decode(
    const unsigned char *src,
    unsigned long        src_len,
    unsigned char      **out_data,
    unsigned int        *out_width,
    unsigned int        *out_height,
    unsigned int        *out_channels)
{
    PictJpegErr jerr;
    struct jpeg_decompress_struct cinfo;

    cinfo.err              = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit    = pict_error_exit;

    if (setjmp(jerr.jmpbuf)) {
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }

    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, src, src_len);
    (void)jpeg_read_header(&cinfo, TRUE);

    cinfo.out_color_space = JCS_RGB;
    (void)jpeg_start_decompress(&cinfo);

    unsigned int  w          = cinfo.output_width;
    unsigned int  h          = cinfo.output_height;
    unsigned int  ch         = (unsigned int)cinfo.output_components; /* 3 for JCS_RGB */
    unsigned long row_stride = (unsigned long)w * ch;
    unsigned long total      = (unsigned long)h * row_stride;

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
