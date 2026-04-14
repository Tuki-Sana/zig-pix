/**
 * bench/bench-quality.ts — encode-only, size-matched (Sharp anchor) spike
 *
 * Policy: README「ベンチの拡張（方針）」— Sharp を基準に出力バイト数を揃え、
 * AVIF encode のみの wall-clock を zigpix vs Sharp で比較する。
 *
 * Pipeline:
 *   1) fixture PNG → zigpix decode → zigpix resize → 固定 ImageBuffer
 *   2) Sharp AVIF(anchor quality/speed) → target byte length
 *   3) zigpix quality を走査し、target ± tolerance に最も近い出力を選ぶ
 *   4) その設定で encode のみ warm-up + measure（Sharp は常に anchor）
 *
 * Env:
 *   BENCH_QUALITY_TOLERANCE  相対幅 (default 0.10 = ±10%)
 *   BENCH_QUALITY_OUT_W / BENCH_QUALITY_OUT_H  リサイズ後 (default 960×540)
 *   BENCH_QUALITY_ANCHOR_Q / BENCH_QUALITY_ANCHOR_SPEED  Sharp (default 60 / 6)
 *   BENCH_QUALITY_ZIGPIX_SPEED  zigpix 探索・計測時の speed (default 6)
 *   BENCH_QUALITY_SEARCH_STEP  quality 走査間隔 1–10 (default 1; 5 で粗探索+細探索)
 *   BENCH_FIXTURE — default | character_* | landscape_*（bench/fixtures.ts、旧別名あり）
 *   BENCH_QUALITY_MIN_SSIM  下限を指定すると未満で exit 1（省略時は報告のみ）
 *   BENCH_WARMUP_N / BENCH_MEASURE_N
 *
 * Run: npm run build && npm run bench:quality
 *
 * Output: bench/results/benchmark-quality.json (+ .md)
 */

import { decode, resize, encodeAvif, type ImageBuffer } from "zigpix";
import sharp from "sharp";
import { readFileSync, mkdirSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { createRequire } from "module";
import { resolveFixturePath } from "./fixtures.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(__dirname, "results");

const { id: fixtureId, path: FIXTURE_PATH } = resolveFixturePath(process.env.BENCH_FIXTURE);

const TOLERANCE = Math.min(0.5, Math.max(0.01, parseFloat(process.env.BENCH_QUALITY_TOLERANCE ?? "0.1")));
const OUT_W = Math.max(64, parseInt(process.env.BENCH_QUALITY_OUT_W ?? "960", 10));
const OUT_H = Math.max(64, parseInt(process.env.BENCH_QUALITY_OUT_H ?? "540", 10));
const ANCHOR_Q = Math.min(100, Math.max(0, parseInt(process.env.BENCH_QUALITY_ANCHOR_Q ?? "60", 10)));
const ANCHOR_SPEED = Math.min(10, Math.max(0, parseInt(process.env.BENCH_QUALITY_ANCHOR_SPEED ?? "6", 10)));
const ZIGPIX_SPEED = Math.min(10, Math.max(0, parseInt(process.env.BENCH_QUALITY_ZIGPIX_SPEED ?? "6", 10)));
const SEARCH_STEP = Math.min(10, Math.max(1, parseInt(process.env.BENCH_QUALITY_SEARCH_STEP ?? "1", 10)));
const WARMUP_N = Math.max(0, parseInt(process.env.BENCH_WARMUP_N ?? "2", 10));
const MEASURE_N = Math.max(1, parseInt(process.env.BENCH_MEASURE_N ?? "10", 10));
const MIN_SSIM_RAW = process.env.BENCH_QUALITY_MIN_SSIM?.trim();
const MIN_SSIM =
  MIN_SSIM_RAW !== undefined && MIN_SSIM_RAW !== ""
    ? Math.min(1, Math.max(0, parseFloat(MIN_SSIM_RAW)))
    : null;

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

function zigpixEncodeBytes(img: ImageBuffer, quality: number, speed: number): Buffer | null {
  return encodeAvif(img, { quality, speed });
}

function calibrateZigpixQuality(
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
    const buf = zigpixEncodeBytes(img, q, ZIGPIX_SPEED);
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

function benchZigpixEncode(img: ImageBuffer, quality: number): number[] {
  const times: number[] = [];
  for (let i = 0; i < WARMUP_N + MEASURE_N; i++) {
    const t0 = performance.now();
    const out = encodeAvif(img, { quality, speed: ZIGPIX_SPEED });
    const t1 = performance.now();
    if (out === null) throw new Error("zigpix encodeAvif returned null");
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

/** Sharp で AVIF → RGB raw（輝度 SSIM 用）。グリッドは anchor と同一に fill で揃える。 */
async function decodeAvifRgbFill(avif: Buffer, width: number, height: number): Promise<Buffer> {
  const { data, info } = await sharp(avif)
    .resize(width, height, { fit: "fill" })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  if (info.channels !== 3) {
    throw new Error(`decodeAvifRgbFill: expected 3 channels, got ${info.channels}`);
  }
  return data;
}

/**
 * 輝度のグローバル SSIM（単一ウィンドウ・Wang et al. の式）。
 * 両画像は同一 WxH の RGB8 raw。厳密な知覚一致ではなく回帰用の簡易指標。
 */
function ssimLuminanceGlobal(a: Buffer, b: Buffer, width: number, height: number): number {
  const n = width * height;
  if (a.length !== b.length || a.length !== n * 3) return NaN;
  let sum1 = 0;
  let sum2 = 0;
  let sum1sq = 0;
  let sum2sq = 0;
  let sum12 = 0;
  for (let i = 0; i < n; i++) {
    const o = i * 3;
    const y1 = 0.299 * a[o] + 0.587 * a[o + 1] + 0.114 * a[o + 2];
    const y2 = 0.299 * b[o] + 0.587 * b[o + 1] + 0.114 * b[o + 2];
    sum1 += y1;
    sum2 += y2;
    sum1sq += y1 * y1;
    sum2sq += y2 * y2;
    sum12 += y1 * y2;
  }
  const mu1 = sum1 / n;
  const mu2 = sum2 / n;
  const var1 = sum1sq / n - mu1 * mu1;
  const var2 = sum2sq / n - mu2 * mu2;
  const cov = sum12 / n - mu1 * mu2;
  const L = 255;
  const K1 = 0.01;
  const K2 = 0.03;
  const C1 = (K1 * L) ** 2;
  const C2 = (K2 * L) ** 2;
  const num = (2 * mu1 * mu2 + C1) * (2 * cov + C2);
  const den = (mu1 * mu1 + mu2 * mu2 + C1) * (var1 + var2 + C2);
  if (den === 0 || !Number.isFinite(den)) return NaN;
  return num / den;
}

// ── Main ──────────────────────────────────────────────────────────────────────

const runner = process.env.RUNNER_OS
  ? `${process.env.RUNNER_OS} (GitHub Actions)`
  : `${process.platform}-${process.arch} (local)`;

console.log("bench-quality.ts — encode-only, Sharp size anchor");
console.log(`  fixture: ${fixtureId} (${FIXTURE_PATH})`);
console.log(`  resize output: ${OUT_W}×${OUT_H}, tolerance ±${(TOLERANCE * 100).toFixed(0)}%`);
console.log(`  anchor: Sharp AVIF quality=${ANCHOR_Q} speed=${ANCHOR_SPEED}`);
console.log(`  zigpix speed (fixed): ${ZIGPIX_SPEED}, search step: ${SEARCH_STEP}\n`);

const png = readFileSync(FIXTURE_PATH);
const decoded = decode(png);
const pixels = resize(decoded, { width: OUT_W, height: OUT_H });

console.log(`pixels: ${pixels.width}×${pixels.height}, channels=${pixels.channels}`);

const sharpBuf = await sharpEncodeBytes(pixels, ANCHOR_Q, ANCHOR_SPEED);
const targetLen = sharpBuf.length;
console.log(`Sharp anchor output: ${targetLen} bytes\n`);

console.log("Calibrating zigpix quality (encode sweep)…");
const cal = calibrateZigpixQuality(pixels, targetLen);
console.log(
  `  chosen quality=${cal.quality} → ${cal.bytes} bytes (target ${targetLen}, band [${Math.floor(targetLen * (1 - TOLERANCE))}, ${Math.ceil(targetLen * (1 + TOLERANCE))}])`,
);
console.log(`  within tolerance: ${cal.withinTolerance}, encode evals: ${cal.searchEvals}\n`);

console.log(`Warm-up ${WARMUP_N} / measure ${MEASURE_N} — encode only\n`);

console.log("zigpix encode…");
const zigTimes = benchZigpixEncode(pixels, cal.quality);
const zigS = summarize(zigTimes);

console.log("Sharp encode…");
const sharpTimes = await benchSharpEncode(pixels);
const sharpS = summarize(sharpTimes);

const ratio = sharpS.median_ms / zigS.median_ms;

const zigAvifBuf = zigpixEncodeBytes(pixels, cal.quality, ZIGPIX_SPEED);
if (zigAvifBuf === null) throw new Error("zigpix final encode returned null");

let ssimLuminance: number | null = null;
let ssimError: string | null = null;
try {
  const rgbAnchor = await decodeAvifRgbFill(sharpBuf, pixels.width, pixels.height);
  const rgbZig = await decodeAvifRgbFill(zigAvifBuf, pixels.width, pixels.height);
  ssimLuminance = ssimLuminanceGlobal(rgbAnchor, rgbZig, pixels.width, pixels.height);
} catch (e) {
  ssimError = e instanceof Error ? e.message : String(e);
}

let ssimPassed: boolean | null = null;
if (MIN_SSIM !== null) {
  if (ssimError !== null || ssimLuminance === null || Number.isNaN(ssimLuminance)) {
    console.error(`SSIM gate: 計算できません (${ssimError ?? "n/a"})`);
    process.exit(1);
  }
  ssimPassed = ssimLuminance >= MIN_SSIM;
  if (!ssimPassed) {
    console.error(
      `SSIM gate failed: luminance SSIM=${ssimLuminance.toFixed(4)} < min ${MIN_SSIM}`,
    );
    process.exit(1);
  }
}

console.log(`
┌────────────────────────────────────────────────────────────┐
│  Encode-only (median ms, ${MEASURE_N} iterations)                    │
├──────────┬──────────┬──────────┬──────────┬────────────────┤
│ Tool     │ Median   │ Min      │ Max      │ ratio (S/z)    │
├──────────┼──────────┼──────────┼──────────┼────────────────┤
│ zigpix   │ ${fmt(zigS.median_ms).padEnd(8)} │ ${fmt(zigS.min_ms).padEnd(8)} │ ${fmt(zigS.max_ms).padEnd(8)} │ ${ratio.toFixed(2)}×            │
│ sharp    │ ${fmt(sharpS.median_ms).padEnd(8)} │ ${fmt(sharpS.min_ms).padEnd(8)} │ ${fmt(sharpS.max_ms).padEnd(8)} │ 1.00×          │
└──────────┴──────────┴──────────┴──────────┴────────────────┘
ratio = sharp_median / zigpix_median (${ratio.toFixed(2)})
`);
if (ssimError) {
  console.log(`SSIM (luminance, global): skipped — ${ssimError}`);
} else {
  console.log(
    `SSIM (luminance, global): ${ssimLuminance?.toFixed(4) ?? "n/a"}${MIN_SSIM !== null ? ` (min ${MIN_SSIM}, ${ssimPassed ? "ok" : "fail"})` : ""}`,
  );
}
console.log("");

const now = new Date().toISOString();
const jsonResult = {
  date: now,
  runner,
  node: process.version,
  mode: "encode-only-size-matched",
  sharp_version: sharpVersion(),
  tolerance_ratio: TOLERANCE,
  anchor: {
    tool: "sharp",
    quality: ANCHOR_Q,
    speed: ANCHOR_SPEED,
    output_bytes: targetLen,
  },
  pixel_buffer: {
    fixture_id: fixtureId,
    fixture_path: FIXTURE_PATH,
    decode_resize: "zigpix",
    width: pixels.width,
    height: pixels.height,
    channels: pixels.channels,
  },
  zigpix_calibrated: {
    quality: cal.quality,
    speed: ZIGPIX_SPEED,
    output_bytes: cal.bytes,
    within_tolerance: cal.withinTolerance,
    search_evals: cal.searchEvals,
    search_step: SEARCH_STEP,
  },
  iterations: { warmup: WARMUP_N, measure: MEASURE_N },
  timings_ms: {
    zigpix_encode: zigS,
    sharp_encode: sharpS,
    ratio_sharp_median_over_zigpix_median: parseFloat(ratio.toFixed(2)),
  },
  ssim: {
    method: "luminance_global_decode_via_sharp_fill_resize",
    vs_anchor: "sharp_avif_decoded",
    value: ssimLuminance !== null && !Number.isNaN(ssimLuminance) ? parseFloat(ssimLuminance.toFixed(4)) : null,
    error: ssimError,
    min_threshold: MIN_SSIM,
    passed: ssimPassed,
  },
};

const md = `# benchmark-quality (encode-only, size-matched)

**Date**: ${now}  
**Runner**: ${runner}  
**Mode**: encode-only; Sharp anchor → zigpix quality sweep → match output size (±${(TOLERANCE * 100).toFixed(0)}%)

| Item | Value |
|------|------:|
| Pixel buffer | ${pixels.width}×${pixels.height}, ${pixels.channels} ch (fixture \`${fixtureId}\`, zigpix decode+resize) |
| Sharp anchor | quality=${ANCHOR_Q}, speed=${ANCHOR_SPEED}, **${targetLen}** bytes |
| zigpix chosen | quality=${cal.quality}, speed=${ZIGPIX_SPEED}, **${cal.bytes}** bytes |
| Within ± band | **${cal.withinTolerance ? "yes" : "no"}** |
| zigpix encode median | **${fmt(zigS.median_ms)}** ms |
| Sharp encode median | **${fmt(sharpS.median_ms)}** ms |
| ratio (sharp÷zigpix) | **${ratio.toFixed(2)}×** |
| SSIM (輝度・グローバル) | **${ssimError ? `skipped: ${ssimError}` : (ssimLuminance?.toFixed(4) ?? "n/a")}** |

See \`benchmark-quality.json\` for machine-readable fields (\`ssim\`)。\`BENCH_QUALITY_MIN_SSIM\` で下限ゲート可能。
`;

const jsonPath = join(OUT_DIR, "benchmark-quality.json");
const mdPath = join(OUT_DIR, "benchmark-quality.md");
writeFileSync(jsonPath, JSON.stringify(jsonResult, null, 2) + "\n");
writeFileSync(mdPath, md);
console.log(`Wrote ${jsonPath}`);
console.log(`Wrote ${mdPath}`);
