/**
 * bench/bench.ts — zigpix vs sharp benchmark (multi-scenario)
 *
 * For each scenario: decode(PNG) → resize(outW×outH) → encodeAVIF(quality, speed)
 * Input PNGs are generated once from test/fixtures/bench_input.png (512×512)
 * scaled with Sharp (cover) to the target width×height.
 *
 * WARMUP_N / MEASURE_N overridable via BENCH_WARMUP_N / BENCH_MEASURE_N.
 *
 * Output:
 *   bench/results/benchmark.json
 *   bench/results/benchmark.md
 *
 * Run:
 *   npm install sharp   (if not already installed)
 *   npm run build       (needs js/dist/index.js)
 *   npx tsx bench/bench.ts
 */

import { decode, resize, encodeAvif } from "zigpix";
import sharp from "sharp";
import { readFileSync, mkdirSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BASE_FIXTURE = join(__dirname, "../test/fixtures/bench_input.png");
const OUT_DIR = join(__dirname, "results");

const WARMUP_N = Math.max(0, parseInt(process.env.BENCH_WARMUP_N ?? "2", 10));
const MEASURE_N = Math.max(1, parseInt(process.env.BENCH_MEASURE_N ?? "10", 10));
const AVIF_QUALITY = 60;
const AVIF_SPEED = 6;

mkdirSync(OUT_DIR, { recursive: true });

/** Representative web pipeline: ~FHD / WQHD / 4K class input → half linear dimensions */
const SCENARIOS = [
  { id: "fhd", label: "FHD 相当", inW: 1920, inH: 1080, outW: 960, outH: 540 },
  { id: "wqhd", label: "WQHD 相当", inW: 2560, inH: 1440, outW: 1280, outH: 720 },
  { id: "uhd4k", label: "4K 相当", inW: 3840, inH: 2160, outW: 1920, outH: 1080 },
] as const;

type Scenario = (typeof SCENARIOS)[number];

interface Timings {
  median_ms: number;
  min_ms: number;
  max_ms: number;
}

function median(arr: number[]): number {
  const s = [...arr].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid];
}

function fmt(ms: number): string {
  return ms.toFixed(2);
}

async function makeInputPng(s: Scenario): Promise<Buffer> {
  const base = readFileSync(BASE_FIXTURE);
  return sharp(base)
    .resize(s.inW, s.inH, { fit: "cover", position: "centre" })
    .png()
    .toBuffer();
}

function benchZigpix(input: Buffer, outW: number, outH: number): number[] {
  const times: number[] = [];
  for (let i = 0; i < WARMUP_N + MEASURE_N; i++) {
    const t0 = performance.now();
    const img = decode(input);
    const small = resize(img, { width: outW, height: outH });
    const avif = encodeAvif(small, { quality: AVIF_QUALITY, speed: AVIF_SPEED });
    const t1 = performance.now();
    if (avif === null) throw new Error("zigpix encodeAvif returned null");
    if (i >= WARMUP_N) times.push(t1 - t0);
  }
  return times;
}

async function benchSharp(input: Buffer, outW: number, outH: number): Promise<number[]> {
  const times: number[] = [];
  for (let i = 0; i < WARMUP_N + MEASURE_N; i++) {
    const t0 = performance.now();
    await sharp(input)
      .resize(outW, outH)
      .avif({ quality: AVIF_QUALITY, speed: AVIF_SPEED })
      .toBuffer();
    const t1 = performance.now();
    if (i >= WARMUP_N) times.push(t1 - t0);
  }
  return times;
}

function summarize(times: number[]): Timings {
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

console.log(
  `Benchmark: decode + resize + AVIF (quality=${AVIF_QUALITY}, speed=${AVIF_SPEED})`,
);
console.log(`Warm-up: ${WARMUP_N} / Measure: ${MEASURE_N} iterations`);
console.log(`Input: ${BASE_FIXTURE} → Sharp cover-resize per scenario\n`);

const scenarioResults: Array<{
  scenario: Scenario;
  input_png_bytes: number;
  zigpix: Timings;
  sharp: Timings;
  ratio: number;
}> = [];

for (const s of SCENARIOS) {
  console.log(`── ${s.label} (${s.inW}×${s.inH} → ${s.outW}×${s.outH}) ──`);
  const inputPng = await makeInputPng(s);
  console.log(`  input PNG size: ${inputPng.length} bytes`);

  console.log("  zigpix...");
  const zigpixTimes = benchZigpix(inputPng, s.outW, s.outH);
  const zigpix = summarize(zigpixTimes);

  console.log("  sharp...");
  const sharpTimes = await benchSharp(inputPng, s.outW, s.outH);
  const sharpT = summarize(sharpTimes);

  const ratio = sharpT.median_ms / zigpix.median_ms;
  scenarioResults.push({
    scenario: s,
    input_png_bytes: inputPng.length,
    zigpix,
    sharp: sharpT,
    ratio: parseFloat(ratio.toFixed(2)),
  });

  console.log(
    `  median: zigpix ${fmt(zigpix.median_ms)} ms / sharp ${fmt(sharpT.median_ms)} ms → ratio ${ratio.toFixed(2)} (sharp÷zigpix)\n`,
  );
}

// ── Console matrix ───────────────────────────────────────────────────────────

const colW = 12;
const pad = (s: string, w: number) => s.padStart(w);
console.log("┌────────────┬──────────────────┬──────────────────┬──────────┐");
console.log("│ Scenario   │ zigpix median ms │ sharp median ms  │ ratio    │");
console.log("├────────────┼──────────────────┼──────────────────┼──────────┤");
for (const r of scenarioResults) {
  const id = r.scenario.id.padEnd(10);
  console.log(
    `│ ${id} │ ${pad(fmt(r.zigpix.median_ms), colW)} │ ${pad(fmt(r.sharp.median_ms), colW)} │ ${pad(r.ratio.toFixed(2) + "×", 8)} │`,
  );
}
console.log("└────────────┴──────────────────┴──────────────────┴──────────┘");
console.log("ratio = sharp_median / zigpix_median (>1 ⇒ zigpix faster wall-clock)\n");

// ── JSON ──────────────────────────────────────────────────────────────────────

const now = new Date().toISOString();
const jsonResult = {
  date: now,
  runner,
  pipeline: "decode PNG → resize → AVIF",
  fixture: {
    source: "test/fixtures/bench_input.png",
    per_scenario: "Sharp resize (fit=cover) to inW×inH, then PNG bytes fed to timed loop",
  },
  avif: { quality: AVIF_QUALITY, speed: AVIF_SPEED },
  iterations: { warmup: WARMUP_N, measure: MEASURE_N },
  scenarios: scenarioResults.map((r) => ({
    id: r.scenario.id,
    label: r.scenario.label,
    input_px: `${r.scenario.inW}×${r.scenario.inH}`,
    output_px: `${r.scenario.outW}×${r.scenario.outH}`,
    input_png_bytes: r.input_png_bytes,
    zigpix: r.zigpix,
    sharp: r.sharp,
    ratio_sharp_median_over_zigpix_median: r.ratio,
  })),
};

// ── Markdown ─────────────────────────────────────────────────────────────────

const mdRows = scenarioResults
  .map(
    (r) =>
      `| ${r.scenario.label} | ${r.scenario.inW}×${r.scenario.inH} | ${r.scenario.outW}×${r.scenario.outH} | ${fmt(r.zigpix.median_ms)} | ${fmt(r.zigpix.min_ms)} | ${fmt(r.zigpix.max_ms)} | ${fmt(r.sharp.median_ms)} | ${fmt(r.sharp.min_ms)} | ${fmt(r.sharp.max_ms)} | **${r.ratio.toFixed(2)}×** |`,
  )
  .join("\n");

const mdResult = `# Benchmark Results (matrix)

**Date**: ${now}  
**Runner**: ${runner}  
**Pipeline**: decode PNG → resize → AVIF (quality=${AVIF_QUALITY}, speed=${AVIF_SPEED})  
**Warm-up / measure**: ${WARMUP_N} / ${MEASURE_N} per tool per scenario  
**Input**: \`test/fixtures/bench_input.png\` scaled to each input size (Sharp, \`fit=cover\`) once per scenario; timed section starts from those PNG bytes.

| シナリオ | 入力 (px) | 出力 (px) | zigpix med (ms) | zig min | zig max | sharp med (ms) | sharp min | sharp max | ratio |
|----------|-----------|-----------|----------------:|--------:|--------:|---------------:|----------:|----------:|------:|
${mdRows}

**ratio** = sharp median ÷ zigpix median (**>1** means zigpix lower wall-clock median for this pipeline).

## JSON

See \`benchmark.json\` in this directory for machine-readable rows (\`scenarios[]\`).
`;

const jsonPath = join(OUT_DIR, "benchmark.json");
const mdPath = join(OUT_DIR, "benchmark.md");

writeFileSync(jsonPath, JSON.stringify(jsonResult, null, 2) + "\n");
writeFileSync(mdPath, mdResult);

console.log("Results saved:");
console.log(`  ${jsonPath}`);
console.log(`  ${mdPath}`);
