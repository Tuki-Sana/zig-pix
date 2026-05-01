/**
 * bench/bench-quality.ts — encode-only, size-matched (Sharp anchor) spike
 *
 * Policy: README「ベンチの拡張（方針）」— Sharp を基準に出力バイト数を揃え、
 * AVIF encode のみの wall-clock を zenpix vs Sharp で比較する。
 *
 * Pipeline:
 *   1) fixture PNG → zenpix decode → zenpix resize → 固定 ImageBuffer
 *   2) Sharp AVIF(anchor quality/speed) → target byte length
 *   3) zenpix quality を走査し、target ± tolerance に最も近い出力を選ぶ
 *   4) その設定で encode のみ warm-up + measure（Sharp は常に anchor）
 *
 * Env:
 *   BENCH_QUALITY_FIXTURE  basename under test/fixtures/ (default bench_input.png)
 *   BENCH_QUALITY_TOLERANCE  相対幅 (default 0.10 = ±10%)
 *   BENCH_QUALITY_OUT_W / BENCH_QUALITY_OUT_H  リサイズ後 (default 960×540)
 *   BENCH_QUALITY_ANCHOR_Q / BENCH_QUALITY_ANCHOR_SPEED  Sharp (default 60 / 6)
 *   BENCH_QUALITY_ZENPIX_SPEED  zenpix 探索・計測時の speed (default 6)
 *   BENCH_QUALITY_SEARCH_STEP  quality 走査間隔 1–10 (default 1; 5 で粗探索+細探索)
 *   BENCH_WARMUP_N / BENCH_MEASURE_N
 *
 * Run: npm run build && npm run bench:quality
 *
 * Output: bench/results/benchmark-quality.json (+ .md)
 *   bench/results/report-quality.html  (./samples/*.avif)
 *   bench/results/samples/quality-{zenpix|sharp}.avif
 *
 * Env: BENCH_WRITE_SAMPLES=0 skips AVIF + HTML (JSON/Markdown only).
 */

import { decode, resize, encodeAvif, type ImageBuffer } from "zenpix";
import sharp from "sharp";
import { readFileSync, mkdirSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { createRequire } from "module";
import { writeQualityHtml } from "./report-html";

const __dirname = dirname(fileURLToPath(import.meta.url));
/** Basename under test/fixtures/ (default bench_input.png). Example: bench_landscape_light.png */
const QUALITY_FIXTURE_FILE = process.env.BENCH_QUALITY_FIXTURE?.trim() || "bench_input.png";
const BASE_FIXTURE = join(__dirname, "../test/fixtures", QUALITY_FIXTURE_FILE);
const OUT_DIR = join(__dirname, "results");
const SAMPLES_DIR = join(OUT_DIR, "samples");

const TOLERANCE = Math.min(0.5, Math.max(0.01, parseFloat(process.env.BENCH_QUALITY_TOLERANCE ?? "0.1")));
const OUT_W = Math.max(64, parseInt(process.env.BENCH_QUALITY_OUT_W ?? "960", 10));
const OUT_H = Math.max(64, parseInt(process.env.BENCH_QUALITY_OUT_H ?? "540", 10));
const ANCHOR_Q = Math.min(100, Math.max(0, parseInt(process.env.BENCH_QUALITY_ANCHOR_Q ?? "60", 10)));
const ANCHOR_SPEED = Math.min(10, Math.max(0, parseInt(process.env.BENCH_QUALITY_ANCHOR_SPEED ?? "6", 10)));
const ZENPIX_SPEED = Math.min(10, Math.max(0, parseInt(process.env.BENCH_QUALITY_ZENPIX_SPEED ?? "6", 10)));
const SEARCH_STEP = Math.min(10, Math.max(1, parseInt(process.env.BENCH_QUALITY_SEARCH_STEP ?? "1", 10)));
const WARMUP_N = Math.max(0, parseInt(process.env.BENCH_WARMUP_N ?? "2", 10));
const MEASURE_N = Math.max(1, parseInt(process.env.BENCH_MEASURE_N ?? "10", 10));
const WRITE_SAMPLES = process.env.BENCH_WRITE_SAMPLES !== "0";

mkdirSync(OUT_DIR, { recursive: true });

function median(arr: number[]): number {
  const s = [...arr].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid];
}

function fmt(ms: number): string {
  return ms.toFixed(2);
}

function sharpVersion(): string {
  try {
    const req = createRequire(import.meta.url);
    const p = req.resolve("sharp/package.json");
    type Pkg = { version?: string };
    const j: Pkg = JSON.parse(readFileSync(p, "utf8")) as Pkg;
    return j.version ?? "unknown";
  } catch {
    return "unknown";
  }
}

async function sharpEncodeBytes(img: ImageBuffer, quality: number, speed: number): Promise<Buffer> {
  const raw = Buffer.isBuffer(img.data) ? img.data : Buffer.from(img.data);
  return sharp(raw, {
    raw: {
      width: img.width,
      height: img.height,
      channels: img.channels as 3 | 4,
    },
  })
    .avif({ quality, speed })
    .toBuffer();
}

function zenpixEncodeBytes(img: ImageBuffer, quality: number, speed: number): Buffer | null {
  return encodeAvif(img, { quality, speed });
}

function calibrateZenpixQuality(
  img: ImageBuffer,
  targetLen: number,
): { quality: number; bytes: number; withinTolerance: boolean; searchEvals: number } {
  const lo = Math.floor(targetLen * (1 - TOLERANCE));
  const hi = Math.ceil(targetLen * (1 + TOLERANCE));
  let bestInBand: { q: number; bytes: number; dist: number } | null = null;
  let bestAny: { q: number; bytes: number; dist: number } | null = null;
  let evals = 0;
  const seen = new Set<number>();

  const tryQ = (q: number) => {
    if (seen.has(q)) return;
    seen.add(q);
    const buf = zenpixEncodeBytes(img, q, ZENPIX_SPEED);
    if (buf === null) return;
    evals += 1;
    const len = buf.length;
    const dist = Math.abs(len - targetLen);
    if (!bestAny || dist < bestAny.dist) bestAny = { q, bytes: len, dist };
    if (len >= lo && len <= hi) {
      if (!bestInBand || dist < bestInBand.dist) bestInBand = { q, bytes: len, dist };
    }
  };

  if (SEARCH_STEP === 1) {
    for (let q = 0; q <= 100; q++) tryQ(q);
  } else {
    for (let q = 0; q <= 100; q += SEARCH_STEP) tryQ(q);
    const seed = bestAny?.q ?? 60;
    const r = SEARCH_STEP;
    for (let q = Math.max(0, seed - r); q <= Math.min(100, seed + r); q++) tryQ(q);
  }

  const pick = bestInBand ?? bestAny!;
  const within = bestInBand !== null;
  return { quality: pick.q, bytes: pick.bytes, withinTolerance: within, searchEvals: evals };
}

function benchZenpixEncode(img: ImageBuffer, quality: number): number[] {
  const times: number[] = [];
  for (let i = 0; i < WARMUP_N + MEASURE_N; i++) {
    const t0 = performance.now();
    const out = encodeAvif(img, { quality, speed: ZENPIX_SPEED });
    const t1 = performance.now();
    if (out === null) throw new Error("zenpix encodeAvif returned null");
    if (i >= WARMUP_N) times.push(t1 - t0);
  }
  return times;
}

async function benchSharpEncode(img: ImageBuffer): Promise<number[]> {
  const times: number[] = [];
  for (let i = 0; i < WARMUP_N + MEASURE_N; i++) {
    const t0 = performance.now();
    await sharpEncodeBytes(img, ANCHOR_Q, ANCHOR_SPEED);
    const t1 = performance.now();
    if (i >= WARMUP_N) times.push(t1 - t0);
  }
  return times;
}

function summarize(times: number[]) {
  return {
    median_ms: parseFloat(fmt(median(times))),
    min_ms: parseFloat(fmt(Math.min(...times))),
    max_ms: parseFloat(fmt(Math.max(...times))),
  };
}

// ── Main ──────────────────────────────────────────────────────────────────────

const runner = process.env.RUNNER_OS
  ? `${process.env.RUNNER_OS} (GitHub Actions)`
  : `${process.platform}-${process.arch} (local)`;

console.log("bench-quality.ts — encode-only, Sharp size anchor");
console.log(`  fixture: test/fixtures/${QUALITY_FIXTURE_FILE}`);
console.log(`  resize output: ${OUT_W}×${OUT_H}, tolerance ±${(TOLERANCE * 100).toFixed(0)}%`);
console.log(`  anchor: Sharp AVIF quality=${ANCHOR_Q} speed=${ANCHOR_SPEED}`);
console.log(`  zenpix speed (fixed): ${ZENPIX_SPEED}, search step: ${SEARCH_STEP}\n`);

const png = readFileSync(BASE_FIXTURE);
const decoded = decode(png);
const pixels = resize(decoded, { width: OUT_W, height: OUT_H });

console.log(`pixels: ${pixels.width}×${pixels.height}, channels=${pixels.channels}`);

const sharpBuf = await sharpEncodeBytes(pixels, ANCHOR_Q, ANCHOR_SPEED);
const targetLen = sharpBuf.length;
console.log(`Sharp anchor output: ${targetLen} bytes\n`);

console.log("Calibrating zenpix quality (encode sweep)…");
const cal = calibrateZenpixQuality(pixels, targetLen);
console.log(
  `  chosen quality=${cal.quality} → ${cal.bytes} bytes (target ${targetLen}, band [${Math.floor(targetLen * (1 - TOLERANCE))}, ${Math.ceil(targetLen * (1 + TOLERANCE))}])`,
);
console.log(`  within tolerance: ${cal.withinTolerance}, encode evals: ${cal.searchEvals}\n`);

console.log(`Warm-up ${WARMUP_N} / measure ${MEASURE_N} — encode only\n`);

console.log("zenpix encode…");
const zigTimes = benchZenpixEncode(pixels, cal.quality);
const zigS = summarize(zigTimes);

console.log("Sharp encode…");
const sharpTimes = await benchSharpEncode(pixels);
const sharpS = summarize(sharpTimes);

const ratio = sharpS.median_ms / zigS.median_ms;

let zenpixSampleRel = "";
let sharpSampleRel = "";
let zenpixWrittenBytes = 0;
if (WRITE_SAMPLES) {
  mkdirSync(SAMPLES_DIR, { recursive: true });
  const zbuf = zenpixEncodeBytes(pixels, cal.quality);
  if (zbuf === null) throw new Error("zenpix encode failed when writing samples");
  zenpixWrittenBytes = zbuf.length;
  sharpSampleRel = "samples/quality-sharp.avif";
  zenpixSampleRel = "samples/quality-zenpix.avif";
  writeFileSync(join(SAMPLES_DIR, "quality-sharp.avif"), sharpBuf);
  writeFileSync(join(SAMPLES_DIR, "quality-zenpix.avif"), zbuf);
}

console.log(`
┌────────────────────────────────────────────────────────────┐
│  Encode-only (median ms, ${MEASURE_N} iterations)                    │
├──────────┬──────────┬──────────┬──────────┬────────────────┤
│ Tool     │ Median   │ Min      │ Max      │ ratio (S/z)    │
├──────────┼──────────┼──────────┼──────────┼────────────────┤
│ zenpix   │ ${fmt(zigS.median_ms).padEnd(8)} │ ${fmt(zigS.min_ms).padEnd(8)} │ ${fmt(zigS.max_ms).padEnd(8)} │ ${ratio.toFixed(2)}×            │
│ sharp    │ ${fmt(sharpS.median_ms).padEnd(8)} │ ${fmt(sharpS.min_ms).padEnd(8)} │ ${fmt(sharpS.max_ms).padEnd(8)} │ 1.00×          │
└──────────┴──────────┴──────────┴──────────┴────────────────┘
ratio = sharp_median / zenpix_median (${ratio.toFixed(2)})
`);

const now = new Date().toISOString();
const jsonResult = {
  date: now,
  runner,
  node: process.version,
  mode: "encode-only-size-matched",
  sharp_version: sharpVersion(),
  tolerance_ratio: TOLERANCE,
  write_samples: WRITE_SAMPLES,
  report_html: WRITE_SAMPLES ? "report-quality.html (relative to bench/results/)" : null,
  sample_avif: WRITE_SAMPLES
    ? {
        sharp: sharpSampleRel,
        zenpix: zenpixSampleRel,
        sharp_bytes: targetLen,
        zenpix_bytes: zenpixWrittenBytes,
      }
    : null,
  anchor: {
    tool: "sharp",
    quality: ANCHOR_Q,
    speed: ANCHOR_SPEED,
    output_bytes: targetLen,
  },
  pixel_buffer: {
    fixture: `test/fixtures/${QUALITY_FIXTURE_FILE}`,
    decode_resize: "zenpix",
    width: pixels.width,
    height: pixels.height,
    channels: pixels.channels,
  },
  zenpix_calibrated: {
    quality: cal.quality,
    speed: ZENPIX_SPEED,
    output_bytes: cal.bytes,
    within_tolerance: cal.withinTolerance,
    search_evals: cal.searchEvals,
    search_step: SEARCH_STEP,
  },
  iterations: { warmup: WARMUP_N, measure: MEASURE_N },
  timings_ms: {
    zenpix_encode: zigS,
    sharp_encode: sharpS,
    ratio_sharp_median_over_zenpix_median: parseFloat(ratio.toFixed(2)),
  },
};

const md = `# benchmark-quality (encode-only, size-matched)

**Date**: ${now}  
**Runner**: ${runner}  
**Mode**: encode-only; Sharp anchor → zenpix quality sweep → match output size (±${(TOLERANCE * 100).toFixed(0)}%)

| Item | Value |
|------|------:|
| Pixel buffer | ${pixels.width}×${pixels.height}, ${pixels.channels} ch (from \`bench_input.png\` via zenpix decode+resize) |
| Sharp anchor | quality=${ANCHOR_Q}, speed=${ANCHOR_SPEED}, **${targetLen}** bytes |
| zenpix chosen | quality=${cal.quality}, speed=${ZENPIX_SPEED}, **${cal.bytes}** bytes |
| Within ± band | **${cal.withinTolerance ? "yes" : "no"}** |
| zenpix encode median | **${fmt(zigS.median_ms)}** ms |
| Sharp encode median | **${fmt(sharpS.median_ms)}** ms |
| ratio (sharp÷zenpix) | **${ratio.toFixed(2)}×** |

${
  WRITE_SAMPLES
    ? `Sample AVIFs: \`report-quality.html\`, \`samples/quality-sharp.avif\`, \`samples/quality-zenpix.avif\`.`
    : `Sample AVIFs skipped (\`BENCH_WRITE_SAMPLES=0\`).`
}

See \`benchmark-quality.json\` for machine-readable fields.
`;

const jsonPath = join(OUT_DIR, "benchmark-quality.json");
const mdPath = join(OUT_DIR, "benchmark-quality.md");
const htmlPath = join(OUT_DIR, "report-quality.html");

writeFileSync(jsonPath, JSON.stringify(jsonResult, null, 2) + "\n");
writeFileSync(mdPath, md);

if (WRITE_SAMPLES) {
  writeQualityHtml(htmlPath, {
    date: now,
    runner,
    node: process.version,
    tolerance_pct: TOLERANCE * 100,
    anchor: { quality: ANCHOR_Q, speed: ANCHOR_SPEED, bytes: targetLen },
    zenpix: {
      quality: cal.quality,
      speed: ZENPIX_SPEED,
      bytes: cal.bytes,
      within: cal.withinTolerance,
    },
    timings: {
      zenpix_median_ms: zigS.median_ms,
      sharp_median_ms: sharpS.median_ms,
      ratio: parseFloat(ratio.toFixed(2)),
    },
    zenpix_sample_rel: zenpixSampleRel,
    sharp_sample_rel: sharpSampleRel,
    pixels: `${pixels.width}×${pixels.height}, ${pixels.channels} ch`,
  });
}

console.log(`Wrote ${jsonPath}`);
console.log(`Wrote ${mdPath}`);
if (WRITE_SAMPLES) {
  console.log(`Wrote ${htmlPath}`);
  console.log(`Wrote ${SAMPLES_DIR}/`);
}
