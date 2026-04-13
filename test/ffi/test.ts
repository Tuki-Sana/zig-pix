/**
 * test/ffi/test.ts — Bun FFI integration test for pict-zig-engine
 *
 * Memory ownership:
 *   Every non-null pointer returned by pict_* MUST be freed via
 *   pict_free_buffer(ptr, outLen). Never read ptr after free.
 *   out_len is BigInt (FFIType.u64); convert to Number only when
 *   out_len <= BigInt(Number.MAX_SAFE_INTEGER).
 *
 * Run: bun run test/ffi/test.ts
 * Or:  bash test/ffi/run.sh  (runs zig build lib first)
 */
import { dlopen, suffix, FFIType, ptr, toArrayBuffer } from "bun:ffi";

const LIB_PATH = `${import.meta.dir}/../../zig-out/lib/libpict.${suffix}`;

const lib = dlopen(LIB_PATH, {
  // pict_decode_v2(data, len, out_w, out_h, out_ch, out_len) -> ?[*]u8
  pict_decode_v2: {
    args: [
      FFIType.ptr, // data: [*c]const u8
      FFIType.u64, // len: usize
      FFIType.ptr, // out_w: ?*u32
      FFIType.ptr, // out_h: ?*u32
      FFIType.ptr, // out_ch: ?*u8
      FFIType.ptr, // out_len: ?*usize
    ],
    returns: FFIType.ptr,
  },
  // pict_resize(src, src_w, src_h, channels, dst_w, dst_h, n_threads, out_len) -> ?[*]u8
  pict_resize: {
    args: [
      FFIType.ptr, // src: [*c]const u8
      FFIType.u32, // src_w: u32
      FFIType.u32, // src_h: u32
      FFIType.u8,  // channels: u8
      FFIType.u32, // dst_w: u32
      FFIType.u32, // dst_h: u32
      FFIType.u32, // n_threads: u32
      FFIType.ptr, // out_len: ?*usize
    ],
    returns: FFIType.ptr,
  },
  // pict_encode_webp(pixels, width, height, channels, quality, lossless, out_len) -> ?[*]u8
  pict_encode_webp: {
    args: [
      FFIType.ptr,  // pixels: [*c]const u8
      FFIType.u32,  // width: u32
      FFIType.u32,  // height: u32
      FFIType.u8,   // channels: u8
      FFIType.f32,  // quality: f32
      FFIType.bool, // lossless: bool
      FFIType.ptr,  // out_len: ?*usize
    ],
    returns: FFIType.ptr,
  },
  // pict_free_buffer(ptr, len) -> void
  pict_free_buffer: {
    args: [
      FFIType.ptr, // ptr: [*]u8
      FFIType.u64, // len: usize
    ],
    returns: FFIType.void,
  },
});

// ── Hardcoded 1×1 RGBA PNG (70 bytes, CRC 検証済み, zero external deps) ──────
// R=255, G=0, B=0, A=255 の単色 1×1 ピクセル
const PNG_1X1_RGBA = new Uint8Array([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, // 8-bit RGBA + CRC
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, // IDAT length + type
  0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0, // compressed pixel data
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x56, 0xC7, // ...
  0x2F, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, // IDAT CRC + IEND type
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,             // IEND CRC
]);

// ── Test runner ───────────────────────────────────────────────────────────────
let failed = 0;

function pass(label: string): void {
  console.log(`PASS: ${label}`);
}

function fail(label: string, reason: string): void {
  console.error(`FAIL: ${label} — ${reason}`);
  failed++;
}

const { symbols } = lib;

try {
  // ── Case A: pict_decode_v2 ──────────────────────────────────────────────
  // Decode a hardcoded 1×1 RGBA PNG; verify out_len == out_w * out_h * out_ch.
  {
    const outW   = new Uint32Array(1);
    const outH   = new Uint32Array(1);
    const outCh  = new Uint8Array(1);
    const outLen = new BigUint64Array(1);

    const result = symbols.pict_decode_v2(
      ptr(PNG_1X1_RGBA),
      BigInt(PNG_1X1_RGBA.byteLength),
      ptr(outW),
      ptr(outH),
      ptr(outCh),
      ptr(outLen),
    );

    if (result === null) {
      fail("A: pict_decode_v2", "returned null");
    } else {
      const expected = BigInt(outW[0]) * BigInt(outH[0]) * BigInt(outCh[0]);
      if (outLen[0] !== expected) {
        fail("A: pict_decode_v2", `out_len ${outLen[0]} != w*h*ch ${expected}`);
      } else {
        pass(`A: pict_decode_v2 — ${outW[0]}x${outH[0]} ch=${outCh[0]}, out_len=${outLen[0]}`);
      }
      symbols.pict_free_buffer(result, outLen[0]);
    }
  }

  // ── Case B: pict_resize ────────────────────────────────────────────────
  // Resize a 4×4 RGBA buffer to 2×2; verify out_len == 2*2*4.
  {
    const src    = new Uint8Array(4 * 4 * 4).fill(128);
    const outLen = new BigUint64Array(1);

    const result = symbols.pict_resize(
      ptr(src),
      4, 4, 4, // src_w, src_h, channels
      2, 2,    // dst_w, dst_h
      1,       // n_threads
      ptr(outLen),
    );

    if (result === null) {
      fail("B: pict_resize", "returned null");
    } else {
      const expected = BigInt(2 * 2 * 4);
      if (outLen[0] !== expected) {
        fail("B: pict_resize", `out_len ${outLen[0]} != ${expected}`);
      } else {
        pass(`B: pict_resize — 4x4→2x2 RGBA, out_len=${outLen[0]}`);
      }
      symbols.pict_free_buffer(result, outLen[0]);
    }
  }

  // ── Case C: pict_encode_webp ───────────────────────────────────────────
  // Encode a 4×4 RGBA buffer as WebP; verify RIFF header in output.
  // Bytes are read BEFORE calling pict_free_buffer (toArrayBuffer is zero-copy).
  {
    const pixels = new Uint8Array(4 * 4 * 4).fill(128);
    const outLen = new BigUint64Array(1);

    const result = symbols.pict_encode_webp(
      ptr(pixels),
      4, 4, 4,  // width, height, channels
      80.0,     // quality
      false,    // lossless
      ptr(outLen),
    );

    if (result === null) {
      fail("C: pict_encode_webp", "returned null");
    } else {
      const header = new Uint8Array(toArrayBuffer(result, 0, 4));
      const isRiff =
        header[0] === 0x52 && // 'R'
        header[1] === 0x49 && // 'I'
        header[2] === 0x46 && // 'F'
        header[3] === 0x46;   // 'F'
      symbols.pict_free_buffer(result, outLen[0]);
      if (!isRiff) {
        const hex = Array.from(header).map(b => b.toString(16).padStart(2, "0")).join(" ");
        fail("C: pict_encode_webp", `RIFF header mismatch: ${hex}`);
      } else {
        pass(`C: pict_encode_webp — RIFF header verified, out_len=${outLen[0]}`);
      }
    }
  }

  // ── Case D: failure — null input pointer ──────────────────────────────
  // pict_encode_webp with null pixels must return null (no free needed).
  {
    const outLen = new BigUint64Array(1);

    const result = symbols.pict_encode_webp(
      null,         // null input pointer
      4, 4, 4,
      80.0, false,
      ptr(outLen),
    );

    if (result !== null) {
      fail("D: failure null input", "expected null, got non-null pointer");
    } else {
      pass("D: failure null input — returned null as expected");
    }
  }
} finally {
  lib.close();
}

if (failed > 0) {
  console.error(`\n${failed} test(s) FAILED.`);
  process.exit(1);
} else {
  console.log(`\nAll ${4 - failed} tests passed.`);
}
