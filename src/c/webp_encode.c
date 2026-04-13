/*
 * webp_encode.c — libwebp C bridge for pict-zig-engine
 *
 * Uses the simple one-shot API (WebPEncodeRGB / WebPEncodeRGBA /
 * WebPEncodeLosslessRGB / WebPEncodeLosslessRGBA).  Output is allocated by
 * libwebp and must be freed with pict_webp_free().
 *
 * Exported symbols:
 *   pict_webp_encode   — encode raw RGB/RGBA → WebP bytes
 *   pict_webp_free     — free output allocated by pict_webp_encode
 */

#include <stddef.h>
#include <stdint.h>
/* libwebp include path is vendor/libwebp; public headers live under src/webp/ */
#include "src/webp/encode.h"
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
