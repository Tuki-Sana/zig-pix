/*
 * webp_decode.c — libwebp C bridge for pict-zig-engine (decode path)
 *
 * Still-image WebP only (RIFF container). Animated WebP is rejected.
 *
 * Exported symbols:
 *   pict_webp_decode      — decode WebP bytes → tightly-packed RGB or RGBA
 *   pict_webp_decode_free — free buffer allocated by pict_webp_decode
 */

#include <stdlib.h>
#include <stdint.h>
#include "src/webp/decode.h"
#include "src/webp/types.h"

/*
 * Decode WebP bitstream to raw pixels.
 *
 * Returns  0 on success.
 *         -1 on invalid/corrupt/unsupported data (including animated WebP).
 *         -2 on allocation failure.
 *
 * On success, *out_data is malloc()'d and must be freed with pict_webp_decode_free().
 * Output is RGB (channels=3) if the bitstream has no alpha, else RGBA (channels=4).
 */
int pict_webp_decode(
    const uint8_t *src,
    unsigned long  src_len,
    uint8_t       **out_data,
    unsigned int   *out_width,
    unsigned int   *out_height,
    unsigned int   *out_channels)
{
    WebPBitstreamFeatures features;
    VP8StatusCode         st;

    if (src == NULL || out_data == NULL || out_width == NULL ||
        out_height == NULL || out_channels == NULL) {
        return -1;
    }

    st = WebPGetFeatures(src, (size_t)src_len, &features);
    if (st != VP8_STATUS_OK) return -1;

    if (features.has_animation) return -1;

    if (features.width <= 0 || features.height <= 0) return -1;

    unsigned int w = (unsigned int)features.width;
    unsigned int h = (unsigned int)features.height;

    unsigned int ch = features.has_alpha ? 4u : 3u;

    if (w > 0 && h > (size_t)-1 / (size_t)w) return -1;
    size_t wh = (size_t)w * (size_t)h;
    if (ch > 0 && wh > (size_t)-1 / ch) return -1;
    size_t total = wh * (size_t)ch;

    uint8_t *buf = (uint8_t *)malloc(total);
    if (buf == NULL) return -2;

    uint8_t *dec;
    if (features.has_alpha) {
        dec = WebPDecodeRGBAInto(src, (size_t)src_len, buf, total, (int)(w * 4));
    } else {
        dec = WebPDecodeRGBInto(src, (size_t)src_len, buf, total, (int)(w * 3));
    }

    if (dec == NULL) {
        free(buf);
        return -1;
    }

    *out_data      = buf;
    *out_width     = w;
    *out_height    = h;
    *out_channels  = ch;
    return 0;
}

void pict_webp_decode_free(uint8_t *data) {
    free(data);
}
