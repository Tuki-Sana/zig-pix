/*
 * avif_encode.c — libavif C bridge for pict-zig-engine
 *
 * Converts RGBA8 pixel data to AVIF using libavif with the aom (libaom)
 * AV1 encoder backend (Homebrew bottle default).
 *
 * Exported symbols:
 *   pict_avif_encode — encode raw RGBA8 → AVIF bytes
 *   pict_avif_free   — free output allocated by pict_avif_encode
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <avif/avif.h>

/*
 * Encode raw RGB8 or RGBA8 pixels to AVIF.
 *
 *   pixels   — tightly-packed, row-major pixel data
 *   width    — image width in pixels
 *   height   — image height in pixels
 *   channels — 3 (RGB) or 4 (RGBA)
 *   quality  — 0..100  (libavif convention: higher = better quality)
 *   speed    — 0..10   (10 = fastest / lowest quality encoder effort)
 *   out_data — set to newly-allocated AVIF bitstream on success
 *   out_size — byte length of *out_data on success
 *
 * Returns 0 on success, -1 on failure.
 * On success, *out_data must be freed with pict_avif_free().
 */
int pict_avif_encode(
    const uint8_t *pixels,
    uint32_t       width,
    uint32_t       height,
    int            channels,
    int            quality,
    int            speed,
    uint8_t      **out_data,
    size_t        *out_size)
{
    if (!pixels || !out_data || !out_size) return -1;
    if (channels != 3 && channels != 4) return -1;

    avifImage *image = avifImageCreate(width, height, 8, AVIF_PIXEL_FORMAT_YUV444);
    if (!image) return -1;

    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format   = (channels == 4) ? AVIF_RGB_FORMAT_RGBA : AVIF_RGB_FORMAT_RGB;
    rgb.pixels   = (uint8_t *)pixels;
    rgb.rowBytes = (uint32_t)((size_t)width * (size_t)channels);

    avifResult conv_result = avifImageRGBToYUV(image, &rgb);
    if (conv_result != AVIF_RESULT_OK) {
        avifImageDestroy(image);
        return -1;
    }

    avifEncoder *encoder = avifEncoderCreate();
    if (!encoder) {
        avifImageDestroy(image);
        return -1;
    }
    /* AVIF_QUALITY_LOSSLESS was introduced in libavif 1.0.0.
     * Older versions (< 1.0.0) use the quantizer-based API (0-63, lower = better quality). */
#ifdef AVIF_QUALITY_LOSSLESS
    encoder->quality      = quality;
    encoder->qualityAlpha = AVIF_QUALITY_LOSSLESS;
#else
    /* Map quality 0-100 → quantizer 63-0 (inverse scale). */
    int quantizer = ((100 - quality) * 63) / 100;
    encoder->minQuantizer      = quantizer;
    encoder->maxQuantizer      = quantizer;
    encoder->minQuantizerAlpha = AVIF_QUANTIZER_LOSSLESS;
    encoder->maxQuantizerAlpha = AVIF_QUANTIZER_LOSSLESS;
#endif
    encoder->speed = speed;

    avifRWData output = AVIF_DATA_EMPTY;
    avifResult enc_result = avifEncoderWrite(encoder, image, &output);
    avifEncoderDestroy(encoder);
    avifImageDestroy(image);

    if (enc_result != AVIF_RESULT_OK || output.size == 0) {
        avifRWDataFree(&output);
        return -1;
    }

    size_t sz = output.size;
    uint8_t *buf = (uint8_t *)malloc(sz);
    if (!buf) {
        avifRWDataFree(&output);
        return -1;
    }
    memcpy(buf, output.data, sz);
    avifRWDataFree(&output);

    *out_data = buf;
    *out_size = sz;
    return 0;
}

void pict_avif_free(uint8_t *data) {
    free(data);
}
