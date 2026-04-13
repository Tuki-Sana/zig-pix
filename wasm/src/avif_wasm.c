/*
 * avif_wasm.c — libavif WASM bridge for pict-zig-engine
 *
 * Exported Emscripten symbols (callable from JS via ccall/cwrap):
 *   avif_encode        — encode raw RGB/RGBA pixels → AVIF bytes
 *   avif_get_out_size  — byte length of the last successful encode
 *   avif_free_output   — free the buffer returned by avif_encode
 *   avif_version       — null-terminated libavif version string
 *
 * Memory contract (JS side):
 *   1. ptr = Module._malloc(width * height * channels)
 *   2. Module.HEAPU8.set(pixelData, ptr)
 *   3. outPtr = Module._avif_encode(ptr, width, height, channels, quality, speed)
 *   4. size   = Module._avif_get_out_size()
 *   5. result = Module.HEAPU8.slice(outPtr, outPtr + size)
 *   6. Module._avif_free_output(outPtr)
 *   7. Module._free(ptr)
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <avif/avif.h>

/* Last successful encode output size — read by avif_get_out_size(). */
static size_t g_last_out_size = 0;

/*
 * Encode raw pixel data to AVIF.
 *
 *   pixels   — tightly-packed row-major pixel data (RGB or RGBA, 8-bit/channel)
 *   width    — image width in pixels
 *   height   — image height in pixels
 *   channels — 3 (RGB) or 4 (RGBA)
 *   quality  — 0..100 (libavif convention: higher = better quality)
 *   speed    — 0..10  (10 = fastest, lowest effort)
 *
 * Returns a malloc'd buffer containing the AVIF bitstream on success,
 * or NULL on failure.  The caller must free it with avif_free_output().
 */
uint8_t *avif_encode(
    uint8_t *pixels,
    uint32_t width,
    uint32_t height,
    int      channels,
    int      quality,
    int      speed)
{
    g_last_out_size = 0;

    if (!pixels || width == 0 || height == 0) return NULL;
    if (channels != 3 && channels != 4) return NULL;
    if (quality < 0 || quality > 100) return NULL;
    if (speed < 0 || speed > 10) return NULL;

    avifImage *image = avifImageCreate(width, height, 8, AVIF_PIXEL_FORMAT_YUV444);
    if (!image) return NULL;

    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format   = (channels == 4) ? AVIF_RGB_FORMAT_RGBA : AVIF_RGB_FORMAT_RGB;
    rgb.pixels   = pixels;
    rgb.rowBytes = (uint32_t)((size_t)width * (size_t)channels);

    avifResult r = avifImageRGBToYUV(image, &rgb);
    if (r != AVIF_RESULT_OK) {
        avifImageDestroy(image);
        return NULL;
    }

    avifEncoder *encoder = avifEncoderCreate();
    if (!encoder) {
        avifImageDestroy(image);
        return NULL;
    }

#ifdef AVIF_QUALITY_LOSSLESS
    encoder->quality      = quality;
    encoder->qualityAlpha = AVIF_QUALITY_LOSSLESS;
#else
    int quantizer = ((100 - quality) * 63) / 100;
    encoder->minQuantizer      = quantizer;
    encoder->maxQuantizer      = quantizer;
    encoder->minQuantizerAlpha = AVIF_QUANTIZER_LOSSLESS;
    encoder->maxQuantizerAlpha = AVIF_QUANTIZER_LOSSLESS;
#endif
    encoder->speed = speed;

    avifRWData output = AVIF_DATA_EMPTY;
    avifResult enc = avifEncoderWrite(encoder, image, &output);
    avifEncoderDestroy(encoder);
    avifImageDestroy(image);

    if (enc != AVIF_RESULT_OK || output.size == 0) {
        avifRWDataFree(&output);
        return NULL;
    }

    uint8_t *buf = (uint8_t *)malloc(output.size);
    if (!buf) {
        avifRWDataFree(&output);
        return NULL;
    }
    memcpy(buf, output.data, output.size);
    g_last_out_size = output.size;
    avifRWDataFree(&output);

    return buf;
}

/* Returns the byte length of the buffer from the last avif_encode() call. */
size_t avif_get_out_size(void) {
    return g_last_out_size;
}

/* Free a buffer returned by avif_encode(). */
void avif_free_output(uint8_t *ptr) {
    free(ptr);
}

/* Null-terminated libavif version string for feature detection. */
const char *avif_version(void) {
    return avifVersion();
}
