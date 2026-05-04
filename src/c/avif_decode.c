/*
 * avif_decode.c — libavif C bridge for AVIF decoding
 *
 * Converts AVIF bitstream to raw RGBA8/RGB8 pixel data.
 *
 * Exported symbols:
 *   pict_avif_decode      — decode AVIF bytes → raw pixels (malloc'd)
 *   pict_avif_decode_free — free output from pict_avif_decode
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <avif/avif.h>

/*
 * Decode AVIF bitstream to raw pixel data.
 *
 *   src      — AVIF bitstream bytes
 *   src_len  — byte length of src
 *   out_data — set to newly-allocated pixel buffer (RGB or RGBA, 8-bit, row-major)
 *   out_w    — image width in pixels
 *   out_h    — image height in pixels
 *   out_ch   — channels (3=RGB, 4=RGBA)
 *
 * Returns 0 on success, -1 on failure.
 * On success, *out_data must be freed with pict_avif_decode_free().
 */
int pict_avif_decode(
    const uint8_t *src,
    size_t         src_len,
    uint8_t      **out_data,
    uint32_t      *out_w,
    uint32_t      *out_h,
    uint32_t      *out_ch)
{
    if (!src || !out_data || !out_w || !out_h || !out_ch || src_len == 0) return -1;

    avifDecoder *decoder = avifDecoderCreate();
    if (!decoder) return -1;

    if (avifDecoderSetIOMemory(decoder, src, src_len) != AVIF_RESULT_OK) {
        avifDecoderDestroy(decoder);
        return -1;
    }

    if (avifDecoderParse(decoder) != AVIF_RESULT_OK) {
        avifDecoderDestroy(decoder);
        return -1;
    }

    if (avifDecoderNextImage(decoder) != AVIF_RESULT_OK) {
        avifDecoderDestroy(decoder);
        return -1;
    }

    avifImage *image = decoder->image;
    int has_alpha = (image->alphaPlane != NULL);
    int channels  = has_alpha ? 4 : 3;

    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format = has_alpha ? AVIF_RGB_FORMAT_RGBA : AVIF_RGB_FORMAT_RGB;
    rgb.depth  = 8;

    if (avifRGBImageAllocatePixels(&rgb) != AVIF_RESULT_OK) {
        avifDecoderDestroy(decoder);
        return -1;
    }

    if (avifImageYUVToRGB(image, &rgb) != AVIF_RESULT_OK) {
        avifRGBImageFreePixels(&rgb);
        avifDecoderDestroy(decoder);
        return -1;
    }

    size_t total = (size_t)rgb.width * (size_t)rgb.height * (size_t)channels;
    uint8_t *buf = (uint8_t *)malloc(total);
    if (!buf) {
        avifRGBImageFreePixels(&rgb);
        avifDecoderDestroy(decoder);
        return -1;
    }
    memcpy(buf, rgb.pixels, total);

    uint32_t w = rgb.width;
    uint32_t h = rgb.height;
    avifRGBImageFreePixels(&rgb);
    avifDecoderDestroy(decoder);

    *out_data = buf;
    *out_w    = w;
    *out_h    = h;
    *out_ch   = (uint32_t)channels;
    return 0;
}

void pict_avif_decode_free(uint8_t *data) {
    free(data);
}
