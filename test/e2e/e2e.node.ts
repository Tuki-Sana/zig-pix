/**
 * test/e2e/e2e.node.ts — End-to-end integration test (Node.js / Bun)
 *
 * Tests the full pipeline: decode → resize → encodeWebP → decode(WebP) → encodeAvif → encodePng → crop
 * using a real 128×128 PNG fixture file.
 *
 * Judgment criteria (intentionally loose to avoid flakes):
 *   - No exceptions thrown
 *   - Output dimensions match expectations
 *   - Output byte length > 100 (format-valid output)
 *   - AVIF output has "ftyp" at bytes[4..8]
 *
 * Run:
 *   npx tsx test/e2e/e2e.node.ts        (Node.js)
 *   bun run test/e2e/e2e.node.ts        (Bun)
 */

import { decode, resize, encodeWebP, encodeAvif, encodePng, crop } from "zenpix";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(__dirname, "../fixtures/e2e_input.png");

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

try {
  // ── Step 1: decode ──────────────────────────────────────────────────────────
  const input = readFileSync(fixturePath);
  let img;
  try {
    img = decode(input);
    if (img.width !== 128 || img.height !== 128) {
      fail("decode dimensions", `expected 128x128, got ${img.width}x${img.height}`);
    } else if (img.data.byteLength !== 128 * 128 * img.channels) {
      fail("decode data length", `expected ${128 * 128 * img.channels}, got ${img.data.byteLength}`);
    } else {
      pass(`decode — ${img.width}x${img.height} ch=${img.channels} len=${img.data.byteLength}`);
    }
  } catch (e) {
    fail("decode", e instanceof Error ? e.message : String(e));
    process.exit(1);
  }

  // ── Step 2: resize ──────────────────────────────────────────────────────────
  let small;
  try {
    small = resize(img, { width: 64, height: 64 });
    if (small.width !== 64 || small.height !== 64) {
      fail("resize dimensions", `expected 64x64, got ${small.width}x${small.height}`);
    } else if (small.data.byteLength !== 64 * 64 * small.channels) {
      fail("resize data length", `expected ${64 * 64 * small.channels}, got ${small.data.byteLength}`);
    } else {
      pass(`resize — 128x128→${small.width}x${small.height} ch=${small.channels}`);
    }
  } catch (e) {
    fail("resize", e instanceof Error ? e.message : String(e));
    process.exit(1);
  }

  // ── Step 3: encodeWebP ──────────────────────────────────────────────────────
  try {
    const webp = encodeWebP(small, { quality: 80 });
    if (webp.byteLength <= 100) {
      fail("encodeWebP output size", `expected > 100 bytes, got ${webp.byteLength}`);
    } else {
      const isRiff = webp[0] === 0x52 && webp[1] === 0x49 && webp[2] === 0x46 && webp[3] === 0x46;
      if (!isRiff) {
        fail("encodeWebP header", "RIFF header not found");
      } else {
        pass(`encodeWebP — RIFF verified, len=${webp.byteLength}`);
        try {
          const webpImg = decode(webp);
          if (webpImg.width !== 64 || webpImg.height !== 64) {
            fail("decode(WebP) dimensions", `expected 64x64, got ${webpImg.width}x${webpImg.height}`);
          } else if (webpImg.data.byteLength !== 64 * 64 * webpImg.channels) {
            fail("decode(WebP) data length", `expected ${64 * 64 * webpImg.channels}, got ${webpImg.data.byteLength}`);
          } else {
            pass(`decode(WebP) — ${webpImg.width}x${webpImg.height} ch=${webpImg.channels}`);
          }
        } catch (e2) {
          fail("decode(WebP)", e2 instanceof Error ? e2.message : String(e2));
        }
      }
    }
  } catch (e) {
    fail("encodeWebP", e instanceof Error ? e.message : String(e));
  }

  // ── Step 5: encodeAvif ──────────────────────────────────────────────────────
  try {
    const avif = encodeAvif(small, { quality: 60, speed: 8 });
    if (avif === null) {
      fail("encodeAvif", "returned null (AVIF not available in this build)");
    } else if (avif.byteLength <= 100) {
      fail("encodeAvif output size", `expected > 100 bytes, got ${avif.byteLength}`);
    } else {
      const brand = String.fromCharCode(avif[4], avif[5], avif[6], avif[7]);
      if (brand !== "ftyp") {
        fail("encodeAvif header", `expected "ftyp" at bytes[4..8], got "${brand}"`);
      } else {
        pass(`encodeAvif — ftyp verified, len=${avif.byteLength}`);
      }
    }
  } catch (e) {
    fail("encodeAvif", e instanceof Error ? e.message : String(e));
  }

  // ── Step 6: encodePng ───────────────────────────────────────────────────────
  try {
    const png = encodePng(small, { compression: 6 });
    if (png.byteLength <= 100) {
      fail("encodePng output size", `expected > 100 bytes, got ${png.byteLength}`);
    } else {
      const isPng = png[0] === 0x89 && png[1] === 0x50 && png[2] === 0x4E && png[3] === 0x47;
      if (!isPng) {
        fail("encodePng header", "PNG magic not found");
      } else {
        pass(`encodePng — PNG magic verified, len=${png.byteLength}`);
      }
    }
  } catch (e) {
    fail("encodePng", e instanceof Error ? e.message : String(e));
  }

  // ── Step 7: crop → encodePng ────────────────────────────────────────────────
  try {
    const cropped = crop(small, { left: 0, top: 0, width: 32, height: 32 });
    if (cropped.width !== 32 || cropped.height !== 32) {
      fail("crop dimensions", `expected 32x32, got ${cropped.width}x${cropped.height}`);
    } else if (cropped.data.byteLength !== 32 * 32 * cropped.channels) {
      fail("crop data length", `expected ${32 * 32 * cropped.channels}, got ${cropped.data.byteLength}`);
    } else {
      pass(`crop — 64x64→32x32 ch=${cropped.channels}`);
      const croppedPng = encodePng(cropped);
      const isPng = croppedPng[0] === 0x89 && croppedPng[1] === 0x50 && croppedPng[2] === 0x4E && croppedPng[3] === 0x47;
      if (!isPng) {
        fail("crop→encodePng header", "PNG magic not found");
      } else {
        pass(`crop→encodePng — PNG magic verified, len=${croppedPng.byteLength}`);
      }
    }
  } catch (e) {
    fail("crop", e instanceof Error ? e.message : String(e));
  }

  // ── Step 8: decode EXIF orientation=6 JPEG ─────────────────────────────────
  try {
    const jpegFixture = readFileSync(join(__dirname, "../fixtures/jpeg_orientation_6.jpg"));
    const jpegImg = decode(jpegFixture);
    // Source is 403×302; orientation=6 (90°CW) auto-rotation → 302×403
    if (jpegImg.width !== 302 || jpegImg.height !== 403) {
      fail("decode EXIF orientation=6", `expected 302x403, got ${jpegImg.width}x${jpegImg.height}`);
    } else {
      pass(`decode EXIF orientation=6 — ${jpegImg.width}x${jpegImg.height} (wh swapped correctly)`);
    }
  } catch (e) {
    fail("decode EXIF orientation=6", e instanceof Error ? e.message : String(e));
  }
} catch (e) {
  console.error("Unexpected error:", e instanceof Error ? e.message : e);
  process.exit(1);
}

// ── Summary ──────────────────────────────────────────────────────────────────
const TOTAL = 9; // 1, 2, 3, decode(WebP), 5, 6, 7, crop→encodePng, 8
if (failed > 0) {
  console.error(`\n${failed} / ${TOTAL} E2E test(s) FAILED.`);
  process.exit(1);
} else {
  console.log(`\nAll ${TOTAL} E2E tests passed.`);
}
