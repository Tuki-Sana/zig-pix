/**
 * bench/bench.ts — zigpix vs sharp benchmark
 *
 * Scenario: decode(512×512 PNG) → resize(256×256) → encodeAVIF(quality=60, speed=6)
 * Runs WARMUP_N warm-up iterations then MEASURE_N measured iterations.
 * Reports median, min, max wall-clock time for each tool.
 * ratio = sharp_median / zigpix_median (> 1 means zigpix is faster)
 *
 * Output:
 *   bench/results/benchmark.json
 *   bench/results/benchmark.md
 *
 * Run:
 *   npm install sharp   (if not already installed)
 *   npx tsx bench/bench.ts
 */

import { decode, resize, encodeAvif } from "zigpix";
import sharp from "sharp";
import { readFileSync, mkdirSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE  = join(__dirname, "../test/fixtures/bench_input.png");
const OUT_DIR  = join(__dirname, "results");
const WARMUP_N  = 2;
const MEASURE_N = 10;

mkdirSync(OUT_DIR, { recursive: true });

// ── Utility ───────────────────────────────────────────────────────────────────

function median(arr: number[]): number {
  const s = [...arr].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid];
}

function fmt(ms: number): string {
  return ms.toFixed(2);
}

// ── zigpix bench ──────────────────────────────────────────────────────────────

async function benchZigpix(): Promise<number[]> {
  const input = readFileSync(FIXTURE);
  const times: number[] = [];

  for (let i = 0; i < WARMUP_N + MEASURE_N; i++) {
    const t0 = performance.now();
    const img    = decode(input);
    const small  = resize(img, { width: 256, height: 256 });
    const avif   = encodeAvif(small, { quality: 60, speed: 6 });
    const t1 = performance.now();

    if (avif === null) throw new Error("zigpix encodeAvif returned null");
    if (i >= WARMUP_N) times.push(t1 - t0);
  }

  return times;
}

// ── sharp bench ───────────────────────────────────────────────────────────────

async function benchSharp(): Promise<number[]> {
  const input = readFileSync(FIXTURE);
  const times: number[] = [];

  for (let i = 0; i < WARMUP_N + MEASURE_N; i++) {
    const t0 = performance.now();
    await sharp(input)
      .resize(256, 256)
      .avif({ quality: 60, speed: 6 })
      .toBuffer();
    const t1 = performance.now();

    if (i >= WARMUP_N) times.push(t1 - t0);
  }

  return times;
}

// ── Main ──────────────────────────────────────────────────────────────────────

console.log(`Benchmark: decode+resize+AVIF (512×512→256×256, quality=60, speed=6)`);
console.log(`Warm-up: ${WARMUP_N} / Measure: ${MEASURE_N} iterations\n`);

console.log("Running zigpix...");
const zigpixTimes = await benchZigpix();
const zigpixMedian = median(zigpixTimes);
const zigpixMin    = Math.min(...zigpixTimes);
const zigpixMax    = Math.max(...zigpixTimes);

console.log("Running sharp...");
const sharpTimes  = await benchSharp();
const sharpMedian = median(sharpTimes);
const sharpMin    = Math.min(...sharpTimes);
const sharpMax    = Math.max(...sharpTimes);

const ratio = sharpMedian / zigpixMedian;

// ── Console output ────────────────────────────────────────────────────────────

console.log(`
┌─────────────────────────────────────────────────────────┐
│  Benchmark Results (wall-clock ms, ${MEASURE_N} iterations)         │
├──────────┬──────────┬──────────┬──────────┬────────────┤
│ Tool     │ Median   │ Min      │ Max      │ vs. sharp  │
├──────────┼──────────┼──────────┼──────────┼────────────┤
│ zigpix   │ ${fmt(zigpixMedian).padEnd(8)} │ ${fmt(zigpixMin).padEnd(8)} │ ${fmt(zigpixMax).padEnd(8)} │ ${ratio.toFixed(2)}×       │
│ sharp    │ ${fmt(sharpMedian).padEnd(8)} │ ${fmt(sharpMin).padEnd(8)} │ ${fmt(sharpMax).padEnd(8)} │ 1.00×      │
└──────────┴──────────┴──────────┴──────────┴────────────┘
ratio = sharp_median / zigpix_median = ${ratio.toFixed(2)} (>1 means zigpix is faster)
`);

// ── Write results ─────────────────────────────────────────────────────────────

const now = new Date().toISOString();
const runner = process.env.RUNNER_OS
  ? `${process.env.RUNNER_OS} (GitHub Actions)`
  : `${process.platform}-${process.arch} (local)`;

const jsonResult = {
  date: now,
  runner,
  scenario: "decode+resize+avif 512x512→256x256 quality=60 speed=6",
  iterations: MEASURE_N,
  zigpix: {
    median_ms: parseFloat(fmt(zigpixMedian)),
    min_ms:    parseFloat(fmt(zigpixMin)),
    max_ms:    parseFloat(fmt(zigpixMax)),
  },
  sharp: {
    median_ms: parseFloat(fmt(sharpMedian)),
    min_ms:    parseFloat(fmt(sharpMin)),
    max_ms:    parseFloat(fmt(sharpMax)),
  },
  ratio: parseFloat(ratio.toFixed(2)),
};

const mdResult = `# Benchmark Results

**Date**: ${now}  
**Runner**: ${runner}  
**Scenario**: decode + resize(256×256) + AVIF encode (512×512 input, quality=60, speed=6)  
**Iterations**: ${MEASURE_N} (after ${WARMUP_N} warm-up)

| Tool   | Median (ms) | Min (ms) | Max (ms) |
|--------|------------:|---------:|---------:|
| zigpix | ${fmt(zigpixMedian)} | ${fmt(zigpixMin)} | ${fmt(zigpixMax)} |
| sharp  | ${fmt(sharpMedian)} | ${fmt(sharpMin)} | ${fmt(sharpMax)} |

**ratio = sharp_median / zigpix_median = ${ratio.toFixed(2)}**  
${ratio > 1 ? `zigpix is **${ratio.toFixed(2)}× faster** than sharp` : `sharp is **${(1 / ratio).toFixed(2)}× faster** than zigpix`}
`;

const jsonPath = join(OUT_DIR, "benchmark.json");
const mdPath   = join(OUT_DIR, "benchmark.md");

writeFileSync(jsonPath, JSON.stringify(jsonResult, null, 2) + "\n");
writeFileSync(mdPath,   mdResult);

console.log(`Results saved:`);
console.log(`  ${jsonPath}`);
console.log(`  ${mdPath}`);
