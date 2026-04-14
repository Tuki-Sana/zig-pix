/*
 * webp_decode.c — libwebp C bridge for pict-zig-engine (decode path)
 *
 * Still-image WebP only (RIFF container). Animated WebP is rejected.
 *
 * Exported symbols:
 *   pict_webp_decode       — decode WebP bytes → tightly-packed RGB or RGBA + optional ICC
 *   pict_webp_decode_free  — free pixel buffer from pict_webp_decode
 *   pict_webp_icc_free     — free ICC buffer from pict_webp_decode (malloc)
 */

#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "src/webp/decode.h"
#include "src/webp/demux.h"
#include "src/webp/mux_types.h"
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
 *
 * If out_icc and out_icc_len are non-NULL, an ICCP chunk (if any) is copied into
 * *out_icc (malloc) with length *out_icc_len; otherwise *out_icc = NULL, len 0.
 * Free *out_icc with pict_webp_icc_free().
 */
int pict_webp_decode(
    const uint8_t *src,
    unsigned long  src_len,
    uint8_t       **out_data,
    unsigned int   *out_width,
    unsigned int   *out_height,
    unsigned int   *out_channels,
    uint8_t       **out_icc,
    unsigned int   *out_icc_len)
{
    WebPBitstreamFeatures features;
    VP8StatusCode         st;

    if (src == NULL || out_data == NULL || out_width == NULL ||
        out_height == NULL || out_channels == NULL) {
        return -1;
    }
    if (out_icc)
        *out_icc = NULL;
    if (out_icc_len)
        *out_icc_len = 0;

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

    if (out_icc && out_icc_len) {
        WebPData           webp_data = { src, (size_t)src_len };
        WebPDemuxer       *dmux      = WebPDemux(&webp_data);
        if (dmux != NULL) {
            uint32_t flags = WebPDemuxGetI(dmux, WEBP_FF_FORMAT_FLAGS);
            if (flags & ICCP_FLAG) {
                WebPChunkIterator chunk_iter;
                if (WebPDemuxGetChunk(dmux, "ICCP", 1, &chunk_iter)) {
                    const uint8_t *icc_src = chunk_iter.chunk.bytes;
                    size_t           icc_sz = chunk_iter.chunk.size;
                    if (icc_src != NULL && icc_sz > 0 && icc_sz <= 0xffffffffu) {
                        uint8_t *icc_copy = (uint8_t *)malloc(icc_sz);
                        if (icc_copy != NULL) {
                            memcpy(icc_copy, icc_src, icc_sz);
                            *out_icc     = icc_copy;
                            *out_icc_len = (unsigned int)icc_sz;
                        }
                    }
                    WebPDemuxReleaseChunkIterator(&chunk_iter);
                }
            }
            WebPDemuxDelete(dmux);
        }
    }

    return 0;
}

void pict_webp_decode_free(uint8_t *data) {
    free(data);
}

void pict_webp_icc_free(uint8_t *icc) {
    free(icc);
}
