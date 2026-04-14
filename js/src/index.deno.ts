/**
 * zigpix — High-performance image processing (Zig-powered native binding)
 * Deno entry point using Deno.dlopen
 *
 * Supported operations:
 *   decode()     — JPEG / PNG → raw pixels
 *   resize()     — Lanczos-3 high-quality resize
 *   encodeWebP() — WebP encode (lossy / lossless)
 *   encodeAvif() — AVIF encode
 *
 * Memory model:
 *   All returned Uint8Arrays are independently owned (copied from native memory).
 *   The native Zig allocations are freed before returning via pict_free_buffer.
 *
 * AVIF note:
 *   libavif and libaom are statically linked in the distributed npm packages.
 *   No system-level installation is required when using the npm packages.
 *   encodeAvif() returns null if the build was compiled without AVIF support,
 *   or if quality/speed options are out of range.
 *
 * Run with:
 *   deno run --allow-read --allow-ffi your_script.ts
 */

import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

// ── Library path resolution ───────────────────────────────────────────────────

function resolveLibPath(): string {
  const plat = process.platform;
  const cpu  = process.arch;

  if (plat !== "darwin" && plat !== "linux") {
    throw new Error(`zigpix: unsupported platform: ${plat} (supported: darwin, linux)`);
  }
  if (cpu !== "arm64" && cpu !== "x64") {
    throw new Error(`zigpix: unsupported architecture: ${cpu} (supported: arm64, x64)`);
  }

  const ext     = plat === "darwin" ? "dylib" : "so";
  const pkgName = `zigpix-${plat}-${cpu}`;

  try {
    // Production: loaded from optional npm platform package
    const req     = createRequire(import.meta.url);
    const pkgRoot = dirname(req.resolve(`${pkgName}/package.json`));
    return join(pkgRoot, `libpict.${ext}`);
  } catch {
    // Development fallback: local zig-out from source build
    const __dirname = dirname(fileURLToPath(import.meta.url));
    return join(__dirname, `../../zig-out/lib/libpict.${ext}`);
  }
}

// ── Deno.dlopen FFI bindings ──────────────────────────────────────────────────

const _lib = Deno.dlopen(resolveLibPath(), {
  pict_decode_v2: {
    parameters: [
      "pointer", // const uint8 *data
      "u64",     // uint64 len
      "pointer", // uint32 *out_w
      "pointer", // uint32 *out_h
      "pointer", // uint8  *out_ch
      "pointer", // uint64 *out_len
    ],
    result: "pointer",
  },
  pict_resize: {
    parameters: [
      "pointer", // const uint8 *src
      "u32",     // uint32 src_w
      "u32",     // uint32 src_h
      "u8",      // uint8 channels
      "u32",     // uint32 dst_w
      "u32",     // uint32 dst_h
      "u32",     // uint32 n_threads
      "pointer", // uint64 *out_len
    ],
    result: "pointer",
  },
  pict_encode_webp: {
    parameters: [
      "pointer", // const uint8 *pixels
      "u32",     // uint32 width
      "u32",     // uint32 height
      "u8",      // uint8 channels
      "f32",     // float quality
      "bool",    // bool lossless
      "pointer", // uint64 *out_len
    ],
    result: "pointer",
  },
  pict_encode_avif: {
    parameters: [
      "pointer", // const uint8 *pixels
      "u32",     // uint32 width
      "u32",     // uint32 height
      "u8",      // uint8 channels
      "u8",      // uint8 quality
      "u8",      // uint8 speed
      "pointer", // uint64 *out_len
    ],
    result: "pointer",
  },
  pict_free_buffer: {
    parameters: [
      "pointer", // uint8 *ptr
      "u64",     // uint64 len
    ],
    result: "void",
  },
} as const);

// ── Internal helper ───────────────────────────────────────────────────────────

/**
 * Copy bytes from native memory into a JS Uint8Array, then free native memory.
 * This mirrors koffi's copyAndFree pattern in index.ts.
 */
function copyAndFree(ptr: Deno.PointerValue, len: bigint): Uint8Array {
  if (ptr === null) throw new Error("zigpix: unexpected null pointer in copyAndFree");
  const size = Number(len);
  const view = new Deno.UnsafePointerView(ptr as NonNullable<Deno.PointerValue>);
  const out  = new Uint8Array(size);
  view.copyInto(out, 0);
  _lib.symbols.pict_free_buffer(ptr, len);
  return out;
}

/** Read a uint32 written into a 4-byte output buffer. */
function readU32(buf: Uint8Array): number {
  return new DataView(buf.buffer).getUint32(0, true);
}

/** Read a uint64 written into an 8-byte output buffer. */
function readU64(buf: Uint8Array): bigint {
  return new DataView(buf.buffer).getBigUint64(0, true);
}

// ── Public types ──────────────────────────────────────────────────────────────

/** Decoded image in raw pixel format */
export interface ImageBuffer {
  /** Raw pixel data: tightly packed, row-major, top-left origin */
  data: Uint8Array;
  width: number;
  height: number;
  /** 3 = RGB, 4 = RGBA */
  channels: number;
}

export interface ResizeOptions {
  /**
   * Target width in pixels.
   * If omitted, calculated from height to preserve aspect ratio.
   */
  width?: number;
  /**
   * Target height in pixels.
   * If omitted, calculated from width to preserve aspect ratio.
   */
  height?: number;
  /** Number of parallel threads (default: 1) */
  threads?: number;
}

export interface WebPOptions {
  /** Quality 0–100 (default: 92) */
  quality?: number;
  /** Lossless mode (default: false) */
  lossless?: boolean;
}

export interface AvifOptions {
  /** Quality 0–100 (default: 60) */
  quality?: number;
  /**
   * Encoder speed 0–10 (default: 6).
   * 10 = fastest (lower quality), 0 = slowest (best quality).
   */
  speed?: number;
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Decode a JPEG, PNG, or still-image WebP buffer into raw pixel data.
 * HEIC/HEIF, animated WebP, and other formats are not supported.
 * @throws {Error} if the input cannot be decoded
 */
export function decode(input: Uint8Array): ImageBuffer {
  const outWBuf   = new Uint8Array(4);
  const outHBuf   = new Uint8Array(4);
  const outChBuf  = new Uint8Array(1);
  const outLenBuf = new Uint8Array(8);

  const ptr = _lib.symbols.pict_decode_v2(
    Deno.UnsafePointer.of(input),
    BigInt(input.byteLength),
    Deno.UnsafePointer.of(outWBuf),
    Deno.UnsafePointer.of(outHBuf),
    Deno.UnsafePointer.of(outChBuf),
    Deno.UnsafePointer.of(outLenBuf),
  );

  if (ptr === null) {
    throw new Error("zigpix: decode failed (unsupported format or corrupt data)");
  }

  const len = readU64(outLenBuf);
  return {
    data:     copyAndFree(ptr, len),
    width:    readU32(outWBuf),
    height:   readU32(outHBuf),
    channels: outChBuf[0],
  };
}

/**
 * Resize pixel data using Lanczos-3 filter.
 * At least one of width or height must be specified.
 * The missing dimension is calculated to preserve the aspect ratio.
 * @throws {Error} if options are invalid or the resize fails
 */
export function resize(image: ImageBuffer, options: ResizeOptions): ImageBuffer {
  let { width, height, threads = 1 } = options;

  if (!width && !height) {
    throw new Error("zigpix: resize requires at least one of width or height");
  }

  if (!width)  width  = Math.round((image.width  / image.height) * height!);
  if (!height) height = Math.round((image.height / image.width)  * width);

  const outLenBuf = new Uint8Array(8);
  const ptr = _lib.symbols.pict_resize(
    Deno.UnsafePointer.of(image.data),
    image.width, image.height, image.channels,
    width, height,
    threads,
    Deno.UnsafePointer.of(outLenBuf),
  );

  if (ptr === null) throw new Error("zigpix: resize failed");

  const len = readU64(outLenBuf);
  return {
    data:     copyAndFree(ptr, len),
    width,
    height,
    channels: image.channels,
  };
}

/**
 * Encode pixel data as WebP.
 * @throws {Error} if encoding fails
 */
export function encodeWebP(image: ImageBuffer, options: WebPOptions = {}): Uint8Array {
  const { quality = 92, lossless = false } = options;

  const outLenBuf = new Uint8Array(8);
  const ptr = _lib.symbols.pict_encode_webp(
    Deno.UnsafePointer.of(image.data),
    image.width, image.height, image.channels,
    quality, lossless,
    Deno.UnsafePointer.of(outLenBuf),
  );

  if (ptr === null) throw new Error("zigpix: WebP encoding failed");

  const len = readU64(outLenBuf);
  return copyAndFree(ptr, len);
}

/**
 * Encode pixel data as AVIF.
 *
 * libavif and libaom are statically linked in the distributed npm packages.
 * No system-level installation is required.
 *
 * Returns null if:
 *   - This build was compiled without AVIF support
 *   - quality is not an integer in range 0–100
 *   - speed is not an integer in range 0–10
 * @throws {Error} if encoding fails for a reason other than the above
 */
export function encodeAvif(image: ImageBuffer, options: AvifOptions = {}): Uint8Array | null {
  const { quality = 60, speed = 6 } = options;

  if (!Number.isInteger(quality) || quality < 0 || quality > 100) return null;
  if (!Number.isInteger(speed)   || speed   < 0 || speed   > 10)  return null;

  const outLenBuf = new Uint8Array(8);
  const ptr = _lib.symbols.pict_encode_avif(
    Deno.UnsafePointer.of(image.data),
    image.width, image.height, image.channels,
    quality, speed,
    Deno.UnsafePointer.of(outLenBuf),
  );

  if (ptr === null) return null;

  const len = readU64(outLenBuf);
  return copyAndFree(ptr, len);
}
