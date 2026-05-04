/*
 * gif_decode.c — GIF decode bridge using stb_image
 *
 * Decodes the first frame of a GIF (GIF87a / GIF89a) to raw RGB8 pixels.
 * Animated GIFs are accepted; only the first frame is decoded.
 *
 * Exported symbols:
 *   pict_gif_decode      — decode GIF bytes → RGB8 pixels (malloc'd)
 *   pict_gif_decode_free — free output from pict_gif_decode
 */

#define STBI_NO_JPEG
#define STBI_NO_PNG
#define STBI_NO_BMP
#define STBI_NO_PSD
#define STBI_NO_TGA
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_FAILURE_USERMSG
#define STB_IMAGE_IMPLEMENTATION
#include "../../vendor/stb/stb_image.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/*
 * Decode GIF bytes to raw RGB8 pixel data (first frame only).
 *
 *   src      — GIF file bytes
 *   src_len  — byte length of src
 *   out_data — set to newly-allocated RGB8 pixel buffer (row-major)
 *   out_w    — image width in pixels
 *   out_h    — image height in pixels
 *
 * Returns 0 on success, -1 on failure.
 * Output is always RGB (3 channels); alpha is discarded.
 * On success, *out_data must be freed with pict_gif_decode_free().
 */
int pict_gif_decode(
    const uint8_t *src,
    size_t         src_len,
    uint8_t      **out_data,
    uint32_t      *out_w,
    uint32_t      *out_h)
{
    if (!src || !out_data || !out_w || !out_h || src_len == 0) return -1;

    int w = 0, h = 0, orig_ch = 0;
    /* Request 3 channels (RGB). stb_image discards alpha for GIF. */
    uint8_t *pixels = stbi_load_from_memory(
        (const stbi_uc *)src, (int)src_len,
        &w, &h, &orig_ch, 3);
    if (!pixels || w <= 0 || h <= 0) return -1;

    size_t total = (size_t)w * (size_t)h * 3;
    uint8_t *buf = (uint8_t *)malloc(total);
    if (!buf) {
        stbi_image_free(pixels);
        return -1;
    }
    memcpy(buf, pixels, total);
    stbi_image_free(pixels);

    *out_data = buf;
    *out_w    = (uint32_t)w;
    *out_h    = (uint32_t)h;
    return 0;
}

void pict_gif_decode_free(uint8_t *data) {
    free(data);
}
