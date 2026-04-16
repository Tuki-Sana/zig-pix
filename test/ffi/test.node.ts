/**
 * test/ffi/test.node.ts — Node.js FFI integration test using koffi
 *
 * Memory ownership:
 *   Every non-null pointer returned by pict_* MUST be freed via
 *   pict_free_buffer(ptr, outLen). Never read ptr after free.
 *   out_len is uint64 (BigInt); use BigInt arithmetic throughout.
 *
 * Run: npx tsx test/ffi/test.node.ts
 * Or:  bash test/ffi/run.node.sh  (runs zig build lib first)
 */
import koffi from "koffi";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { arch, platform } from "os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..", "..");
const suffix = platform() === "darwin" ? "dylib" : platform() === "win32" ? "dll" : "so";
const winZigOutDir =
  platform() === "win32" && arch() === "arm64" ? "windows-aarch64" : "windows-x86_64";
const LIB_PATH =
  platform() === "win32"
    ? join(repoRoot, "zig-out", winZigOutDir, "libpict.dll")
    : join(repoRoot, "zig-out", "lib", "libpict." + suffix);

const lib = koffi.load(LIB_PATH);

// ── Function declarations (C prototype syntax) ────────────────────────────────

// pict_decode_v2(data, len, out_w, out_h, out_ch, out_len) -> uint8 * | null
const pict_decode_v2 = lib.func(
  "uint8 *pict_decode_v2(const uint8 *data, uint64 len, uint32 *out_w, uint32 *out_h, uint8 *out_ch, uint64 *out_len)"
);

// pict_decode_v3(..., out_icc, out_icc_len) -> uint8 * | null
const pict_decode_v3 = lib.func(
  "uint8 *pict_decode_v3(const uint8 *data, uint64 len, uint32 *out_w, uint32 *out_h, uint8 *out_ch, uint64 *out_len, _Out_ uint8 **out_icc, uint64 *out_icc_len)"
);

// pict_resize(src, src_w, src_h, channels, dst_w, dst_h, n_threads, out_len) -> uint8 * | null
const pict_resize = lib.func(
  "uint8 *pict_resize(const uint8 *src, uint32 src_w, uint32 src_h, uint8 channels, uint32 dst_w, uint32 dst_h, uint32 n_threads, uint64 *out_len)"
);

// pict_encode_webp_v2(..., icc, icc_len, out_len) -> uint8 * | null
const pict_encode_webp_v2 = lib.func(
  "uint8 *pict_encode_webp_v2(const uint8 *pixels, uint32 width, uint32 height, uint8 channels, float quality, bool lossless, uint8 *icc, uint64 icc_len, uint64 *out_len)"
);

// pict_encode_avif(pixels, width, height, channels, quality, speed, out_len) -> uint8 * | null
const pict_encode_avif = lib.func(
  "uint8 *pict_encode_avif(const uint8 *pixels, uint32 width, uint32 height, uint8 channels, uint8 quality, uint8 speed, uint64 *out_len)"
);

// pict_free_buffer(ptr, len) -> void
const pict_free_buffer = lib.func(
  "void pict_free_buffer(uint8 *ptr, uint64 len)"
);

// ── Hardcoded 1×1 RGBA PNG (70 bytes, CRC 検証済み, zero external deps) ──────
// R=255, G=0, B=0, A=255 の単色 1×1 ピクセル
const PNG_1X1_RGBA = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG signature
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, // 8-bit RGBA + CRC
  0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, // IDAT length + type
  0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, // compressed pixel data
  0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x56, 0xc7, // ...
  0x2f, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, // IDAT CRC + IEND type
  0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,             // IEND CRC
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

try {
  // ── Case A: pict_decode_v2 ──────────────────────────────────────────────
  // Decode a hardcoded 1×1 RGBA PNG; verify out_len == out_w * out_h * out_ch.
  {
    const outW   = new Uint32Array(1);
    const outH   = new Uint32Array(1);
    const outCh  = new Uint8Array(1);
    const outLen = new BigUint64Array(1);

    const result = pict_decode_v2(
      PNG_1X1_RGBA,
      BigInt(PNG_1X1_RGBA.byteLength),
      outW,
      outH,
      outCh,
      outLen,
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
      pict_free_buffer(result, outLen[0]);
    }
  }

  // ── Case A2: pict_decode_v3 + iCCP PNG ─────────────────────────────────
  {
    const parisPath = join(__dirname, "../../vendor/libavif/tests/data/paris_icc_exif_xmp.png");
    let paris: Buffer;
    try {
      paris = readFileSync(parisPath);
    } catch {
      fail("A2: pict_decode_v3", `missing fixture ${parisPath}`);
      paris = Buffer.alloc(0);
    }
    if (paris.length > 0) {
      const outW   = new Uint32Array(1);
      const outH   = new Uint32Array(1);
      const outCh  = new Uint8Array(1);
      const outLen = new BigUint64Array(1);
      const iccSlot: unknown[] = [null];
      const iccLen = new BigUint64Array(1);

      const result = pict_decode_v3(
        paris,
        BigInt(paris.byteLength),
        outW,
        outH,
        outCh,
        outLen,
        iccSlot,
        iccLen,
      );

      if (result === null) {
        fail("A2: pict_decode_v3", "returned null");
      } else if (iccSlot[0] == null || iccLen[0] === 0n) {
        fail("A2: pict_decode_v3", "expected non-null ICC");
        pict_free_buffer(result, outLen[0]);
      } else {
        if (iccLen[0] < 128n) {
          fail("A2: pict_decode_v3", `icc_len ${iccLen[0]} too small`);
        } else {
          pass(`A2: pict_decode_v3 — ICC len=${iccLen[0]}`);
        }
        pict_free_buffer(iccSlot[0] as never, iccLen[0]);
        pict_free_buffer(result, outLen[0]);
      }
    }
  }

  // ── Case B: pict_resize ────────────────────────────────────────────────
  // Resize a 4×4 RGBA buffer to 2×2; verify out_len == 2*2*4.
  {
    const src    = Buffer.alloc(4 * 4 * 4, 128);
    const outLen = new BigUint64Array(1);

    const result = pict_resize(
      src,
      4, 4, 4, // src_w, src_h, channels
      2, 2,    // dst_w, dst_h
      1,       // n_threads
      outLen,
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
      pict_free_buffer(result, outLen[0]);
    }
  }

  // ── Case C: pict_encode_webp ───────────────────────────────────────────
  // Encode a 4×4 RGBA buffer as WebP; verify RIFF header in output.
  {
    const pixels = Buffer.alloc(4 * 4 * 4, 128);
    const outLen = new BigUint64Array(1);

    const result = pict_encode_webp_v2(
      pixels,
      4, 4, 4, // width, height, channels
      80.0,    // quality
      false,   // lossless
      null,
      0n,
      outLen,
    );

    if (result === null) {
      fail("C: pict_encode_webp", "returned null");
    } else {
      const header: number[] = koffi.decode(result, "uint8", 4);
      const isRiff =
        header[0] === 0x52 && // 'R'
        header[1] === 0x49 && // 'I'
        header[2] === 0x46 && // 'F'
        header[3] === 0x46;   // 'F'
      pict_free_buffer(result, outLen[0]);
      if (!isRiff) {
        const hex = header.map((b) => b.toString(16).padStart(2, "0")).join(" ");
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

    const result = pict_encode_webp_v2(
      null,        // null input pointer
      4, 4, 4,
      80.0, false,
      null,
      0n,
      outLen,
    );

    if (result !== null) {
      fail("D: failure null input", "expected null, got non-null pointer");
    } else {
      pass("D: failure null input — returned null as expected");
    }
  }

  // ── Case E: pict_encode_avif ───────────────────────────────────────────
  // Encode a 4×4 RGB buffer as AVIF; verify ISO Base Media File Format
  // ftyp box at bytes[4..8] == "ftyp".
  {
    const W = 4, H = 4, CH = 3;
    const pixels = Buffer.alloc(W * H * CH, 128);
    const outLen = new BigUint64Array(1);

    const result = pict_encode_avif(
      pixels,
      W, H, CH,
      60,  // quality
      8,   // speed (fast for tests)
      outLen,
    );

    if (result === null) {
      fail("E: pict_encode_avif", "returned null (AVIF may be disabled for this build)");
    } else {
      const header: number[] = koffi.decode(result, "uint8", 8);
      const brand = String.fromCharCode(header[4], header[5], header[6], header[7]);
      pict_free_buffer(result, outLen[0]);
      if (brand !== "ftyp") {
        fail("E: pict_encode_avif", `expected "ftyp" at bytes[4..8], got "${brand}"`);
      } else {
        pass(`E: pict_encode_avif — ftyp header verified, out_len=${outLen[0]}`);
      }
    }
  }

  // ── Case F: pict_encode_avif null input returns null ──────────────────
  {
    const outLen = new BigUint64Array(1);

    const result = pict_encode_avif(
      null,  // null pixels
      4, 4, 3,
      60, 8,
      outLen,
    );

    if (result !== null) {
      fail("F: encode_avif null input", "expected null, got non-null pointer");
    } else {
      pass("F: encode_avif null input — returned null as expected");
    }
  }

  // ── Case G: pict_encode_avif out-of-range quality/speed returns null ──
  // quality=255 (>100) and speed=255 (>10) must be rejected at the FFI boundary.
  {
    const W = 4, H = 4, CH = 3;
    const pixels = Buffer.alloc(W * H * CH, 128);
    const outLen = new BigUint64Array(1);

    const resultQ = pict_encode_avif(
      pixels,
      W, H, CH,
      255,  // quality out of range (>100)
      8,
      outLen,
    );
    if (resultQ !== null) {
      fail("G: encode_avif out-of-range quality", "expected null for quality=255, got non-null");
    } else {
      pass("G: encode_avif quality=255 — returned null as expected");
    }

    const resultS = pict_encode_avif(
      pixels,
      W, H, CH,
      60,
      255,  // speed out of range (>10)
      outLen,
    );
    if (resultS !== null) {
      fail("G: encode_avif out-of-range speed", "expected null for speed=255, got non-null");
    } else {
      pass("G: encode_avif speed=255 — returned null as expected");
    }
  }
} finally {
  lib.unload();
}

const TOTAL = 8;
if (failed > 0) {
  console.error(`\n${failed} / ${TOTAL} test(s) FAILED.`);
  process.exit(1);
} else {
  console.log(`\nAll ${TOTAL} tests passed.`);
}
