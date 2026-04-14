/**
 * test/e2e/e2e.node.ts — End-to-end integration test (Node.js / Bun)
 *
 * Tests the full pipeline: decode → resize → encodeWebP → decode(WebP) → encodeAvif
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

import { decode, resize, encodeWebP, encodeAvif } from "zigpix";
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
} catch (e) {
  console.error("Unexpected error:", e instanceof Error ? e.message : e);
  process.exit(1);
}

// ── Summary ──────────────────────────────────────────────────────────────────
const TOTAL = 5;
if (failed > 0) {
  console.error(`\n${failed} / ${TOTAL} E2E test(s) FAILED.`);
  process.exit(1);
} else {
  console.log(`\nAll ${TOTAL} E2E tests passed.`);
}
