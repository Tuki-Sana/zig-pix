/*
 * webp_encode.c — libwebp C bridge for pict-zig-engine
 *
 * Uses the simple one-shot API (WebPEncodeRGB / WebPEncodeRGBA /
 * WebPEncodeLosslessRGB / WebPEncodeLosslessRGBA).  Output is allocated by
 * libwebp and must be freed with pict_webp_free().
 *
 * Exported symbols:
 *   pict_webp_encode            — encode raw RGB/RGBA → WebP bytes
 *   pict_webp_encode_with_icc   — encode + embed ICCP (mux; tests)
 *   pict_webp_free              — free output allocated by pict_webp_encode*
 */

#include <stddef.h>
#include <stdint.h>
/* libwebp include path is vendor/libwebp; public headers live under src/webp/ */
#include "src/webp/encode.h"
#include "src/webp/mux.h"
#include "src/webp/mux_types.h"
#include "src/webp/types.h"

/*
 * Encode raw pixels to WebP.
 *
 *   pixels   — tightly-packed, row-major pixel data
 *   width    — image width in pixels
 *   height   — image height in pixels
 *   channels — 3 (RGB) or 4 (RGBA)
 *   quality  — 0..100 lossy quality, ignored when lossless != 0
 *   lossless — 0 = lossy, non-zero = lossless
 *   out_data — set to newly-allocated WebP bitstream on success
 *   out_len  — byte length of *out_data on success
 *
 * Returns 0 on success, -1 on encoding error.
 * On success, *out_data must be freed with pict_webp_free().
 */
int pict_webp_encode(
    const uint8_t *pixels,
    int            width,
    int            height,
    int            channels,
    float          quality,
    int            lossless,
    uint8_t      **out_data,
    size_t        *out_len)
{
    int stride = width * channels;
    size_t encoded = 0;
    uint8_t *output = NULL;

    if (channels == 4) {
        encoded = lossless
            ? WebPEncodeLosslessRGBA(pixels, width, height, stride, &output)
            : WebPEncodeRGBA(pixels, width, height, stride, quality, &output);
    } else {
        encoded = lossless
            ? WebPEncodeLosslessRGB(pixels, width, height, stride, &output)
            : WebPEncodeRGB(pixels, width, height, stride, quality, &output);
    }

    if (encoded == 0 || output == NULL) return -1;

    *out_data = output;
    *out_len  = encoded;
    return 0;
}

void pict_webp_free(uint8_t *data) {
    WebPFree(data);
}

/*
 * Lossy or lossless encode then wrap in RIFF with VP8X + ICCP via libwebpmux.
 * icc must be non-NULL, icc_len > 0.
 * On success *out_data is WebPMalloc'd; free with pict_webp_free().
 */
int pict_webp_encode_with_icc(
    const uint8_t *pixels,
    int            width,
    int            height,
    int            channels,
    float          quality,
    int            lossless,
    const uint8_t *icc,
    unsigned int   icc_len,
    uint8_t      **out_data,
    size_t        *out_len)
{
    uint8_t *encoded = NULL;
    size_t   enc_size = 0;
    int      stride   = width * channels;

    if (!icc || icc_len == 0 || !out_data || !out_len)
        return -1;

    if (channels == 4) {
        enc_size = lossless
            ? WebPEncodeLosslessRGBA(pixels, width, height, stride, &encoded)
            : WebPEncodeRGBA(pixels, width, height, stride, quality, &encoded);
    } else if (channels == 3) {
        enc_size = lossless
            ? WebPEncodeLosslessRGB(pixels, width, height, stride, &encoded)
            : WebPEncodeRGB(pixels, width, height, stride, quality, &encoded);
    } else {
        return -1;
    }

    if (enc_size == 0 || encoded == NULL)
        return -1;

    WebPData image = { encoded, enc_size };
    WebPMux *mux   = WebPMuxNew();
    if (mux == NULL) {
        WebPFree(encoded);
        return -2;
    }

    WebPData      icc_data = { icc, (size_t)icc_len };
    WebPData      assembled;
    WebPMuxError  err;

    WebPDataInit(&assembled);

    err = WebPMuxSetImage(mux, &image, 1);
    WebPFree(encoded);
    encoded = NULL;

    if (err != WEBP_MUX_OK) {
        WebPMuxDelete(mux);
        return -1;
    }

    err = WebPMuxSetChunk(mux, "ICCP", &icc_data, 1);
    if (err != WEBP_MUX_OK) {
        WebPMuxDelete(mux);
        return -1;
    }

    err = WebPMuxAssemble(mux, &assembled);
    WebPMuxDelete(mux);

    if (err != WEBP_MUX_OK) {
        WebPDataClear(&assembled);
        return -1;
    }

    if (assembled.bytes == NULL || assembled.size == 0) {
        WebPDataClear(&assembled);
        return -1;
    }

    *out_data = (uint8_t *)assembled.bytes;
    *out_len  = assembled.size;
    assembled.bytes = NULL;
    assembled.size  = 0;
    WebPDataClear(&assembled);
    return 0;
}
