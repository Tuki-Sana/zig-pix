/**
 * zigpix — High-performance image processing (Zig-powered native binding)
 *
 * Supported operations:
 *   decode()     — JPEG / PNG / still WebP → raw pixels（埋め込み ICC があれば返す）
 *   resize()     — Lanczos-3 high-quality resize
 *   encodeWebP() — WebP encode (lossy / lossless)
 *   encodeAvif() — AVIF encode (requires libavif on the system)
 *
 * Memory model:
 *   All returned Buffers are independently owned by Node.js GC.
 *   The native Zig allocations are freed before returning.
 *
 * AVIF note:
 *   libavif and libaom are statically linked in the distributed npm packages.
 *   No system-level installation is required when using npm install zigpix.
 *   encodeAvif() returns null if the build was compiled without AVIF support,
 *   or if quality/speed options are out of range.
 */

import koffi from "koffi";
import { existsSync } from "fs";
import { platform, arch } from "os";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { createRequire } from "module";

// ── Library loading ───────────────────────────────────────────────────────────
//
// 解決順（リリース初期: リポジトリ内のビルド成果物を優先し、古い optional より新シンボルを使いやすくする）:
//   1. 環境変数 ZIGPIX_LIB（存在するファイルパスのみ）
//   2. このモジュールからの相対 ../../zig-out/lib/libpict.{dylib,so} または zig-out/windows-x86_64/libpict.dll（zig build 済みなら）
//   3. optionalDependency zigpix-<platform>-<arch> 内の libpict
//
// 本番 npm のみの環境では 2 が無いので 3 が使われる。プラットフォームパッケージは新 lib で再 publish すること。

function resolveLibPath(): string {
  const plat = platform();
  const cpu = arch();

  if (plat !== "darwin" && plat !== "linux" && plat !== "win32") {
    throw new Error(`zigpix: unsupported platform: ${plat} (supported: darwin, linux, win32)`);
  }
  if (cpu !== "arm64" && cpu !== "x64") {
    throw new Error(`zigpix: unsupported architecture: ${cpu} (supported: arm64, x64)`);
  }

  const ext = plat === "darwin" ? "dylib" : plat === "win32" ? "dll" : "so";
  const pkgName = `zigpix-${plat}-${cpu}`;

  const fromEnv = process.env.ZIGPIX_LIB?.trim();
  if (fromEnv && existsSync(fromEnv)) {
    return fromEnv;
  }

  const __dirname = dirname(fileURLToPath(import.meta.url));
  const zigOut =
    plat === "win32"
      ? join(__dirname, "../../zig-out/windows-x86_64/libpict.dll")
      : join(__dirname, `../../zig-out/lib/libpict.${ext}`);
  if (existsSync(zigOut)) {
    return zigOut;
  }

  try {
    const req = createRequire(import.meta.url);
    const pkgRoot = dirname(req.resolve(`${pkgName}/package.json`));
    return join(pkgRoot, `libpict.${ext}`);
  } catch {
    throw new Error(
      `zigpix: libpict.${ext} が見つかりません。` +
        `リポジトリなら \`zig build lib\` で ${zigOut} を生成するか、` +
        `環境変数 ZIGPIX_LIB にフルパスを設定するか、optional ${pkgName} を入れてください。`,
    );
  }
}

const _lib = koffi.load(resolveLibPath());

// ── FFI bindings (internal) ───────────────────────────────────────────────────

const _decode_v3 = _lib.func(
  "uint8 *pict_decode_v3(const uint8 *data, uint64 len, uint32 *out_w, uint32 *out_h, uint8 *out_ch, uint64 *out_len, _Out_ uint8 **out_icc, uint64 *out_icc_len)"
);

const _resize = _lib.func(
  "uint8 *pict_resize(const uint8 *src, uint32 src_w, uint32 src_h, uint8 channels, uint32 dst_w, uint32 dst_h, uint32 n_threads, uint64 *out_len)"
);

const _encode_webp_v2 = _lib.func(
  "uint8 *pict_encode_webp_v2(const uint8 *pixels, uint32 width, uint32 height, uint8 channels, float quality, bool lossless, uint8 *icc, uint64 icc_len, uint64 *out_len)"
);

const _encode_avif = _lib.func(
  "uint8 *pict_encode_avif(const uint8 *pixels, uint32 width, uint32 height, uint8 channels, uint8 quality, uint8 speed, uint64 *out_len)"
);

const _free = _lib.func("void pict_free_buffer(uint8 *ptr, uint64 len)");

// ── Internal helper ───────────────────────────────────────────────────────────

function copyAndFree(ptr: unknown, len: bigint): Buffer {
  const size = Number(len);
  const bytes = koffi.decode(ptr, "uint8", size) as number[];
  _free(ptr, len);
  return Buffer.from(bytes);
}

// ── Public types ──────────────────────────────────────────────────────────────

/** Decoded image in raw pixel format */
export interface ImageBuffer {
  /** Raw pixel data: tightly packed, row-major, top-left origin */
  data: Buffer;
  width: number;
  height: number;
  /** 3 = RGB, 4 = RGBA */
  channels: number;
  /**
   * 埋め込み ICC プロファイル（JPEG APP2 / PNG iCCP / WebP ICCP 等）。
   * 無い画像では省略される。
   */
  icc?: Buffer;
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
 * When the file contains an embedded ICC profile, it is copied into `icc`
 * (same memory contract as `data`: native memory is freed before return).
 * @throws {Error} if the input cannot be decoded
 */
export function decode(input: Buffer | Uint8Array): ImageBuffer {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input);

  const outW   = new Uint32Array(1);
  const outH   = new Uint32Array(1);
  const outCh  = new Uint8Array(1);
  const outLen = new BigUint64Array(1);
  const iccPtrSlot: unknown[] = [null];
  const iccLen = new BigUint64Array(1);

  const ptr = _decode_v3(buf, BigInt(buf.byteLength), outW, outH, outCh, outLen, iccPtrSlot, iccLen);
  if (ptr === null) {
    throw new Error("zigpix: decode failed (unsupported format or corrupt data)");
  }

  const out: ImageBuffer = {
    data: copyAndFree(ptr, outLen[0]),
    width:    outW[0],
    height:   outH[0],
    channels: outCh[0],
  };

  const iccNative = iccPtrSlot[0];
  if (iccNative != null && iccLen[0] > 0n) {
    out.icc = copyAndFree(iccNative, iccLen[0]);
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
    throw new Error("zigpix: resize requires at least one of width or height");
  }

  if (!width)  width  = Math.round((image.width  / image.height) * height!);
  if (!height) height = Math.round((image.height / image.width)  * width);

  const outLen = new BigUint64Array(1);
  const ptr = _resize(
    image.data,
    image.width, image.height, image.channels,
    width, height,
    threads,
    outLen,
  );
  if (ptr === null) throw new Error("zigpix: resize failed");

  const out: ImageBuffer = {
    data:     copyAndFree(ptr, outLen[0]),
    width,
    height,
    channels: image.channels,
  };
  if (image.icc !== undefined && image.icc.byteLength > 0) {
    out.icc = Buffer.from(image.icc);
  }
  return out;
}

/**
 * Encode pixel data as WebP.
 * @throws {Error} if encoding fails
 */
export function encodeWebP(image: ImageBuffer, options: WebPOptions = {}): Buffer {
  const { quality = 92, lossless = false } = options;

  const outLen = new BigUint64Array(1);
  const icc = image.icc;
  const iccLen = icc !== undefined && icc.byteLength > 0 ? BigInt(icc.byteLength) : 0n;
  const ptr = _encode_webp_v2(
    image.data,
    image.width, image.height, image.channels,
    quality, lossless,
    icc !== undefined && icc.byteLength > 0 ? icc : null,
    iccLen,
    outLen,
  );
  if (ptr === null) throw new Error("zigpix: WebP encoding failed");

  return copyAndFree(ptr, outLen[0]);
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
export function encodeAvif(image: ImageBuffer, options: AvifOptions = {}): Buffer | null {
  const { quality = 60, speed = 6 } = options;

  if (!Number.isInteger(quality) || quality < 0 || quality > 100) return null;
  if (!Number.isInteger(speed)   || speed   < 0 || speed   > 10)  return null;

  const outLen = new BigUint64Array(1);
  const ptr = _encode_avif(
    image.data,
    image.width, image.height, image.channels,
    quality, speed,
    outLen,
  );
  if (ptr === null) return null;

  return copyAndFree(ptr, outLen[0]);
}
