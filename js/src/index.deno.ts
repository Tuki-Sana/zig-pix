/**
 * zenpix — High-performance image processing (Zig-powered native binding)
 * Deno entry point using Deno.dlopen
 *
 * Supported operations:
 *   decode()     — JPEG / PNG / still WebP → raw pixels（埋め込み ICC があれば返す）
 *   resize()     — Lanczos-3 high-quality resize
 *   encodeWebP() — WebP encode (lossy / lossless)
 *   encodeAvif() — AVIF encode
 *   encodePng()  — PNG encode with optional ICC passthrough
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
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

// ── Library path resolution ───────────────────────────────────────────────────
// 解決順は index.ts の resolveLibPath と同じ（ZENPIX_LIB → ../../zig-out → optional。npm optional は darwin arm64/x64・linux x64・win32 x64 の 4 件。win32+arm64 のみ optional なし）。

function resolveLibPath(): string {
  const plat = process.platform;
  const cpu  = process.arch;

  if (plat !== "darwin" && plat !== "linux" && plat !== "win32") {
    throw new Error(`zenpix: unsupported platform: ${plat} (supported: darwin, linux, win32)`);
  }
  if (cpu !== "arm64" && cpu !== "x64") {
    throw new Error(`zenpix: unsupported architecture: ${cpu} (supported: arm64, x64)`);
  }

  const ext     = plat === "darwin" ? "dylib" : plat === "win32" ? "dll" : "so";
  const pkgName = `zenpix-${plat}-${cpu}`;

  const fromEnv = process.env.ZENPIX_LIB?.trim();
  if (fromEnv && existsSync(fromEnv)) {
    return fromEnv;
  }

  const __dirname = dirname(fileURLToPath(import.meta.url));
  const winZigOutDir =
    plat === "win32" && cpu === "arm64" ? "windows-aarch64" : "windows-x86_64";
  const zigOut =
    plat === "win32"
      ? join(__dirname, "../../zig-out", winZigOutDir, "libpict.dll")
      : join(__dirname, `../../zig-out/lib/libpict.${ext}`);
  if (existsSync(zigOut)) {
    return zigOut;
  }

  if (plat === "win32" && cpu === "arm64") {
    throw new Error(
      `zenpix: Windows on ARM64 向けの npm optional は提供していません。` +
        `自前ビルドの zig-out/windows-aarch64/libpict.dll を置くか ZENPIX_LIB で指定するか、` +
        `x64 版 Node.js と zenpix-win32-x64 を利用してください。`,
    );
  }

  try {
    const req     = createRequire(import.meta.url);
    const pkgRoot = dirname(req.resolve(`${pkgName}/package.json`));
    return join(pkgRoot, `libpict.${ext}`);
  } catch {
    throw new Error(
      `zenpix: libpict.${ext} が見つかりません。` +
        `\`zig build lib\` で ${zigOut} を生成するか、ZENPIX_LIB を設定するか、optional ${pkgName} を入れてください。`,
    );
  }
}

// ── Deno.dlopen FFI bindings ──────────────────────────────────────────────────

const _lib = Deno.dlopen(resolveLibPath(), {
  pict_decode_v3: {
    parameters: [
      "pointer", // const uint8 *data
      "u64",     // uint64 len
      "pointer", // uint32 *out_w
      "pointer", // uint32 *out_h
      "pointer", // uint8  *out_ch
      "pointer", // uint64 *out_len
      "pointer", // uint8 **out_icc  (usize 格納の 8 バイト)
      "pointer", // uint64 *out_icc_len
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
  pict_encode_webp_v2: {
    parameters: [
      "pointer", // const uint8 *pixels
      "u32",     // width
      "u32",     // height
      "u8",      // channels
      "f32",     // quality
      "bool",    // lossless
      "pointer", // icc (nullable)
      "u64",     // icc_len
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
  pict_encode_png: {
    parameters: [
      "pointer", // const uint8 *pixels
      "u32",     // uint32 width
      "u32",     // uint32 height
      "u8",      // uint8 channels
      "u8",      // uint8 compression
      "pointer", // icc (nullable)
      "u64",     // icc_len
      "pointer", // uint64 *out_len
    ],
    result: "pointer",
  },
  pict_crop: {
    parameters: [
      "pointer", // const uint8 *pixels
      "u32",     // uint32 src_w
      "u32",     // uint32 src_h
      "u8",      // uint8 channels
      "u32",     // uint32 left
      "u32",     // uint32 top
      "u32",     // uint32 crop_w
      "u32",     // uint32 crop_h
      "pointer", // uint64 *out_len
    ],
    result: "pointer",
  },
  pict_jpeg_orientation: {
    parameters: [
      "pointer", // const uint8 *data
      "u64",     // uint64 len
    ],
    result: "u8",
  },
  pict_rotate: {
    parameters: [
      "pointer", // const uint8 *pixels
      "u32",     // uint32 src_w
      "u32",     // uint32 src_h
      "u8",      // uint8 channels
      "u8",      // uint8 orientation
      "pointer", // uint32 *out_w
      "pointer", // uint32 *out_h
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
  if (ptr === null) throw new Error("zenpix: unexpected null pointer in copyAndFree");
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
  /** 埋め込み ICC（無い場合は省略） */
  icc?: Uint8Array;
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

export interface PngOptions {
  /** zlib compression level 0–9 (default: 6) */
  compression?: number;
}

export interface CropOptions {
  left: number;
  top: number;
  width: number;
  height: number;
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Decode a JPEG, PNG, or still-image WebP buffer into raw pixel data.
 * HEIC/HEIF, animated WebP, and other formats are not supported.
 * Embedded ICC (if any) is returned in `icc`.
 * JPEG EXIF Orientation (2–8) is applied automatically.
 * @throws {Error} if the input cannot be decoded, or if EXIF rotation fails (OOM)
 */
export function decode(input: Uint8Array): ImageBuffer {
  const outWBuf   = new Uint8Array(4);
  const outHBuf   = new Uint8Array(4);
  const outChBuf  = new Uint8Array(1);
  const outLenBuf = new Uint8Array(8);
  const iccPtrSlot = new BigUint64Array(1);
  const iccLenBuf  = new BigUint64Array(1);

  const pixPtr = _lib.symbols.pict_decode_v3(
    Deno.UnsafePointer.of(input),
    BigInt(input.byteLength),
    Deno.UnsafePointer.of(outWBuf),
    Deno.UnsafePointer.of(outHBuf),
    Deno.UnsafePointer.of(outChBuf),
    Deno.UnsafePointer.of(outLenBuf),
    Deno.UnsafePointer.of(iccPtrSlot),
    Deno.UnsafePointer.of(iccLenBuf),
  );

  if (pixPtr === null) {
    throw new Error("zenpix: decode failed (unsupported format or corrupt data)");
  }

  const orientation: number = _lib.symbols.pict_jpeg_orientation(
    Deno.UnsafePointer.of(input),
    BigInt(input.byteLength),
  );

  let finalPtr: Deno.PointerValue = pixPtr;
  let finalLen = readU64(outLenBuf);
  let finalW   = readU32(outWBuf);
  let finalH   = readU32(outHBuf);
  const channels = outChBuf[0];

  if (orientation !== 1) {
    const rotOutWBuf   = new Uint8Array(4);
    const rotOutHBuf   = new Uint8Array(4);
    const rotOutLenBuf = new Uint8Array(8);
    const rotPtr = _lib.symbols.pict_rotate(
      pixPtr,
      finalW, finalH, channels,
      orientation,
      Deno.UnsafePointer.of(rotOutWBuf),
      Deno.UnsafePointer.of(rotOutHBuf),
      Deno.UnsafePointer.of(rotOutLenBuf),
    );
    if (rotPtr === null) {
      _lib.symbols.pict_free_buffer(pixPtr, finalLen);
      const iccBits = iccPtrSlot[0];
      if (iccBits !== 0n && iccLenBuf[0] > 0n) {
        _lib.symbols.pict_free_buffer(Deno.UnsafePointer.create(iccBits), iccLenBuf[0]);
      }
      throw new Error("zenpix: EXIF rotation failed (out of memory)");
    }
    _lib.symbols.pict_free_buffer(pixPtr, finalLen);
    finalPtr = rotPtr;
    finalLen = readU64(rotOutLenBuf);
    finalW   = readU32(rotOutWBuf);
    finalH   = readU32(rotOutHBuf);
  }

  const out: ImageBuffer = {
    data:     copyAndFree(finalPtr, finalLen),
    width:    finalW,
    height:   finalH,
    channels,
  };

  const iccBits = iccPtrSlot[0];
  const iccLen = iccLenBuf[0];
  if (iccBits !== 0n && iccLen > 0n) {
    const iccPtr = Deno.UnsafePointer.create(iccBits);
    out.icc = copyAndFree(iccPtr, iccLen);
  }

  return out;
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
    throw new Error("zenpix: resize requires at least one of width or height");
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

  if (ptr === null) throw new Error("zenpix: resize failed");

  const len = readU64(outLenBuf);
  const out: ImageBuffer = {
    data:     copyAndFree(ptr, len),
    width,
    height,
    channels: image.channels,
  };
  if (image.icc !== undefined && image.icc.byteLength > 0) {
    out.icc = new Uint8Array(image.icc);
  }
  return out;
}

/**
 * Encode pixel data as WebP.
 * @throws {Error} if encoding fails
 */
export function encodeWebP(image: ImageBuffer, options: WebPOptions = {}): Uint8Array {
  const { quality = 92, lossless = false } = options;

  const outLenBuf = new Uint8Array(8);
  const hasIcc = image.icc !== undefined && image.icc.byteLength > 0;
  const ptr = _lib.symbols.pict_encode_webp_v2(
    Deno.UnsafePointer.of(image.data),
    image.width, image.height, image.channels,
    quality, lossless,
    hasIcc ? Deno.UnsafePointer.of(image.icc!) : null,
    hasIcc ? BigInt(image.icc!.byteLength) : 0n,
    Deno.UnsafePointer.of(outLenBuf),
  );

  if (ptr === null) throw new Error("zenpix: WebP encoding failed");

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

/**
 * Encode pixel data as PNG.
 * @throws {Error} if compression is not an integer 0–9, or if encoding fails
 */
export function encodePng(image: ImageBuffer, options: PngOptions = {}): Uint8Array {
  const { compression = 6 } = options;

  if (!Number.isInteger(compression) || compression < 0 || compression > 9) {
    throw new Error("zenpix: compression must be an integer 0–9");
  }

  const hasIcc = image.icc !== undefined && image.icc.byteLength > 0;
  const outLenBuf = new Uint8Array(8);
  const ptr = _lib.symbols.pict_encode_png(
    Deno.UnsafePointer.of(image.data),
    image.width, image.height, image.channels,
    compression,
    hasIcc ? Deno.UnsafePointer.of(image.icc!) : null,
    hasIcc ? BigInt(image.icc!.byteLength) : 0n,
    Deno.UnsafePointer.of(outLenBuf),
  );

  if (ptr === null) throw new Error("zenpix: PNG encoding failed");

  const len = readU64(outLenBuf);
  return copyAndFree(ptr, len);
}

/**
 * Crop a rectangular region from pixel data.
 * ICC profile is carried through to the output.
 * @throws {Error} if options are invalid or the crop region is out of bounds
 */
export function crop(image: ImageBuffer, options: CropOptions): ImageBuffer {
  const { left, top, width, height } = options;

  for (const [name, val] of [["left", left], ["top", top], ["width", width], ["height", height]] as [string, number][]) {
    if (!Number.isInteger(val) || val < 0 || val > 0xFFFFFFFF) {
      throw new Error(`zenpix: crop ${name} must be a non-negative integer ≤ 4294967295`);
    }
  }
  if (width === 0 || height === 0) {
    throw new Error("zenpix: crop width and height must be > 0");
  }

  const outLenBuf = new Uint8Array(8);
  const ptr = _lib.symbols.pict_crop(
    Deno.UnsafePointer.of(image.data),
    image.width, image.height, image.channels,
    left, top, width, height,
    Deno.UnsafePointer.of(outLenBuf),
  );

  if (ptr === null) throw new Error("zenpix: crop failed (region out of bounds or invalid input)");

  const len = readU64(outLenBuf);
  const out: ImageBuffer = {
    data:     copyAndFree(ptr, len),
    width,
    height,
    channels: image.channels,
  };
  if (image.icc !== undefined && image.icc.byteLength > 0) {
    out.icc = new Uint8Array(image.icc);
  }
  return out;
}
