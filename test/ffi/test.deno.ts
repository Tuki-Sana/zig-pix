/**
 * test/ffi/test.deno.ts — Deno FFI integration test for pict-zig-engine
 *
 * Tests the public API through js/src/index.deno.ts (Deno.dlopen based).
 * API contract must match Node/Bun version (test.node.ts / test.ts).
 *
 * Run:
 *   deno run --allow-read --allow-ffi --allow-env test/ffi/test.deno.ts
 */

import { decode, resize, encodeWebP, encodeAvif } from "../../js/src/index.deno.ts";

// ── Hardcoded 1×1 RGBA PNG (70 bytes, CRC 検証済み, zero external deps) ──────
// R=255, G=0, B=0, A=255 の単色 1×1 ピクセル
const PNG_1X1_RGBA = new Uint8Array([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
  0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x56, 0xC7,
  0x2F, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

// ── Test runner ───────────────────────────────────────────────────────────────
let failed = 0;
let passed = 0;

function pass(label: string): void {
  console.log(`PASS: ${label}`);
  passed++;
}

function fail(label: string, reason: string): void {
  console.error(`FAIL: ${label} — ${reason}`);
  failed++;
}

// ── Case A: decode ────────────────────────────────────────────────────────────
// Decode a 1×1 RGBA PNG; verify dimensions and pixel count.
{
  try {
    const img = decode(PNG_1X1_RGBA);
    const expected = img.width * img.height * img.channels;
    if (img.data.byteLength !== expected) {
      fail(`A: decode`, `data.byteLength ${img.data.byteLength} != w*h*ch ${expected}`);
    } else {
      pass(`A: decode — ${img.width}x${img.height} ch=${img.channels} len=${img.data.byteLength}`);
    }
  } catch (e) {
    fail("A: decode", e instanceof Error ? e.message : String(e));
  }
}

// ── Case B: resize ────────────────────────────────────────────────────────────
// Decode 1×1 PNG, then resize to 2×2 (artificial upscale); verify dimensions.
{
  try {
    const src = decode(PNG_1X1_RGBA);
    const dst = resize(src, { width: 2, height: 2 });
    const expectedLen = 2 * 2 * dst.channels;
    if (dst.width !== 2 || dst.height !== 2 || dst.data.byteLength !== expectedLen) {
      fail("B: resize", `got ${dst.width}x${dst.height} len=${dst.data.byteLength}, expected 2x2 len=${expectedLen}`);
    } else {
      pass(`B: resize — 1x1→2x2 ch=${dst.channels} len=${dst.data.byteLength}`);
    }
  } catch (e) {
    fail("B: resize", e instanceof Error ? e.message : String(e));
  }
}

// ── Case C: encodeWebP ────────────────────────────────────────────────────────
// Encode a 4×4 RGBA image as WebP; verify RIFF header.
{
  try {
    const raw = new Uint8Array(4 * 4 * 4).fill(128);
    const img = { data: raw, width: 4, height: 4, channels: 4 };
    const webp = encodeWebP(img, { quality: 80 });
    const isRiff =
      webp[0] === 0x52 && // 'R'
      webp[1] === 0x49 && // 'I'
      webp[2] === 0x46 && // 'F'
      webp[3] === 0x46;   // 'F'
    if (!isRiff) {
      const hex = Array.from(webp.slice(0, 4)).map(b => b.toString(16).padStart(2, "0")).join(" ");
      fail("C: encodeWebP", `RIFF header mismatch: ${hex}`);
    } else {
      pass(`C: encodeWebP — RIFF header verified, out_len=${webp.byteLength}`);
    }
  } catch (e) {
    fail("C: encodeWebP", e instanceof Error ? e.message : String(e));
  }
}

// ── Case E: encodeAvif ────────────────────────────────────────────────────────
// Encode a 4×4 RGB image as AVIF; verify ISO Base Media File Format ftyp box.
{
  try {
    const raw = new Uint8Array(4 * 4 * 3).fill(128);
    const img = { data: raw, width: 4, height: 4, channels: 3 };
    const avif = encodeAvif(img, { quality: 60, speed: 8 });
    if (avif === null) {
      fail("E: encodeAvif", "returned null");
    } else {
      // AVIF is ISOBMFF: bytes[4..8] must be "ftyp"
      const brand = String.fromCharCode(avif[4], avif[5], avif[6], avif[7]);
      if (brand !== "ftyp") {
        fail("E: encodeAvif", `expected "ftyp" at bytes[4..8], got "${brand}"`);
      } else {
        pass(`E: encodeAvif — ftyp header verified, out_len=${avif.byteLength}`);
      }
    }
  } catch (e) {
    fail("E: encodeAvif", e instanceof Error ? e.message : String(e));
  }
}

// ── Case G: encodeAvif out-of-range quality/speed returns null ────────────────
// quality=255 (>100) and speed=255 (>10) must return null (JS validation layer).
{
  try {
    const raw = new Uint8Array(4 * 4 * 3).fill(128);
    const img = { data: raw, width: 4, height: 4, channels: 3 };

    const resultQ = encodeAvif(img, { quality: 255, speed: 8 });
    if (resultQ !== null) {
      fail("G: encodeAvif quality=255", "expected null for quality=255, got non-null");
    } else {
      pass("G: encodeAvif quality=255 — returned null as expected");
    }

    const resultS = encodeAvif(img, { quality: 60, speed: 255 });
    if (resultS !== null) {
      fail("G: encodeAvif speed=255", "expected null for speed=255, got non-null");
    } else {
      pass("G: encodeAvif speed=255 — returned null as expected");
    }
  } catch (e) {
    fail("G: encodeAvif out-of-range", e instanceof Error ? e.message : String(e));
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────
const TOTAL = 6; // A, B, C, E, G×2
if (failed > 0) {
  console.error(`\n${failed} / ${TOTAL} test(s) FAILED.`);
  Deno.exit(1);
} else {
  console.log(`\nAll ${TOTAL} tests passed.`);
}
