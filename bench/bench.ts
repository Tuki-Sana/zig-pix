/**
 * bench/bench.ts — zigpix vs sharp benchmark (multi-scenario)
 *
 * For each scenario: decode(PNG) → resize(outW×outH) → encodeAVIF(quality, speed)
 * Input PNGs are generated from test/fixtures/*.png (see BENCH_FIXTURES below),
 * scaled with Sharp (cover) to each scenario's width×height.
 *
 * WARMUP_N / MEASURE_N overridable via BENCH_WARMUP_N / BENCH_MEASURE_N.
 *
 * Env:
 *   BENCH_FIXTURES   comma-separated fixture ids (default: all). Example: bench_input,bench_chara_chika
 *   BENCH_WRITE_SAMPLES=0  skips AVIF + HTML (JSON/Markdown only).
 *
 * Output:
 *   bench/results/benchmark.json
 *   bench/results/benchmark.md
 *   bench/results/report.html  (opens ./samples/*.avif)
 *   bench/results/samples/matrix-{fixture}-{scenario}-{zigpix|sharp}.avif
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
import { writeMatrixHtml, type MatrixScenarioRow } from "./report-html";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = join(__dirname, "../test/fixtures");
const OUT_DIR = join(__dirname, "results");
const SAMPLES_DIR = join(OUT_DIR, "samples");

/** Default matrix: original 512 tile + portfolio / landscape variants under test/fixtures/. */
const ALL_FIXTURES = [
  { id: "bench_input", file: "bench_input.png", label: "bench_input（従来・512 系）" },
  { id: "bench_chara_chika", file: "bench_chara_chika.png", label: "キャラ（Chika）" },
  { id: "bench_chara_kanata", file: "bench_chara_kanata.png", label: "キャラ（Kanata）" },
  { id: "bench_landscape_dark", file: "bench_landscape_dark.png", label: "風景（トワイライト）" },
  { id: "bench_landscape_impasto", file: "bench_landscape_impasto.png", label: "風景（厚塗り）" },
  { id: "bench_landscape_light", file: "bench_landscape_light.png", label: "風景（ハイキー）" },
] as const;

function selectFixtures(): readonly (typeof ALL_FIXTURES)[number][] {
  const raw = process.env.BENCH_FIXTURES?.trim();
  if (!raw) return ALL_FIXTURES;
  const want = new Set(
    raw
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
  const picked = ALL_FIXTURES.filter((f) => want.has(f.id));
  if (picked.length === 0) {
    throw new Error(
      `BENCH_FIXTURES matched no known fixture ids: "${raw}". Known: ${ALL_FIXTURES.map((x) => x.id).join(", ")}`,
    );
  }
  return picked;
}

const WARMUP_N = Math.max(0, parseInt(process.env.BENCH_WARMUP_N ?? "2", 10));
const MEASURE_N = Math.max(1, parseInt(process.env.BENCH_MEASURE_N ?? "10", 10));
const AVIF_QUALITY = 60;
const AVIF_SPEED = 6;
/** Sharp の型に `speed` が無い版があるため、実行時オプションとして渡す */
const SHARP_AVIF_OPTS = { quality: AVIF_QUALITY, speed: AVIF_SPEED } as const;
const WRITE_SAMPLES = process.env.BENCH_WRITE_SAMPLES !== "0";

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

async function makeInputPng(fixturePath: string, s: Scenario): Promise<Buffer> {
  const base = readFileSync(fixturePath);
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
      .avif({ ...SHARP_AVIF_OPTS } as Parameters<sharp.Sharp["avif"]>[0])
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

/** One encode each; same pipeline as the timed loop (not timed). */
async function writeMatrixSamples(
  fixtureId: string,
  scenarioId: string,
  inputPng: Buffer,
  outW: number,
  outH: number,
): Promise<{ zigpix_rel: string; sharp_rel: string; zigpix_bytes: number; sharp_bytes: number }> {
  mkdirSync(SAMPLES_DIR, { recursive: true });
  const img = decode(inputPng);
  const small = resize(img, { width: outW, height: outH });
  const z = encodeAvif(small, { quality: AVIF_QUALITY, speed: AVIF_SPEED });
  if (z === null) throw new Error("zigpix encodeAvif returned null (samples)");
  const zigName = `matrix-${fixtureId}-${scenarioId}-zigpix.avif`;
  const sharpName = `matrix-${fixtureId}-${scenarioId}-sharp.avif`;
  writeFileSync(join(SAMPLES_DIR, zigName), z);

  const sbuf = await sharp(inputPng)
    .resize(outW, outH)
    .avif({ ...SHARP_AVIF_OPTS } as Parameters<sharp.Sharp["avif"]>[0])
    .toBuffer();
  writeFileSync(join(SAMPLES_DIR, sharpName), sbuf);

  return {
    zigpix_rel: `samples/${zigName}`,
    sharp_rel: `samples/${sharpName}`,
    zigpix_bytes: z.length,
    sharp_bytes: sbuf.length,
  };
}

// ── Main ──────────────────────────────────────────────────────────────────────

const runner = process.env.RUNNER_OS
  ? `${process.env.RUNNER_OS} (GitHub Actions)`
  : `${process.platform}-${process.arch} (local)`;

const fixtures = selectFixtures();

console.log(
  `Benchmark: decode + resize + AVIF (quality=${AVIF_QUALITY}, speed=${AVIF_SPEED})`,
);
console.log(`Warm-up: ${WARMUP_N} / Measure: ${MEASURE_N} iterations`);
console.log(`Fixtures (${fixtures.length}): ${fixtures.map((f) => f.id).join(", ")}`);
console.log(`Input: test/fixtures/<png> → Sharp cover-resize per scenario\n`);

type ScenarioRow = {
  scenario: Scenario;
  input_png_bytes: number;
  zigpix: Timings;
  sharp: Timings;
  ratio: number;
  samples?: {
    zigpix_rel: string;
    sharp_rel: string;
    zigpix_bytes: number;
    sharp_bytes: number;
  };
};

const fixtureResults: Array<{
  fixture: { id: string; file: string; label: string; path: string };
  scenarios: ScenarioRow[];
}> = [];

for (const fx of fixtures) {
  const fixturePath = join(FIXTURES_DIR, fx.file);
  console.log(`\n▶ Fixture: ${fx.label} (${fx.id})`);
  console.log(`  file: test/fixtures/${fx.file}`);

  const scenarioResults: ScenarioRow[] = [];

  for (const s of SCENARIOS) {
    console.log(`── ${s.label} (${s.inW}×${s.inH} → ${s.outW}×${s.outH}) ──`);
    const inputPng = await makeInputPng(fixturePath, s);
    console.log(`  input PNG size: ${inputPng.length} bytes`);

    console.log("  zigpix...");
    const zigpixTimes = benchZigpix(inputPng, s.outW, s.outH);
    const zigpix = summarize(zigpixTimes);

    console.log("  sharp...");
    const sharpTimes = await benchSharp(inputPng, s.outW, s.outH);
    const sharpT = summarize(sharpTimes);

    const ratio = sharpT.median_ms / zigpix.median_ms;

    let samples: ScenarioRow["samples"];
    if (WRITE_SAMPLES) {
      samples = await writeMatrixSamples(fx.id, s.id, inputPng, s.outW, s.outH);
      console.log(`  wrote ${samples.zigpix_rel}, ${samples.sharp_rel}`);
    }

    scenarioResults.push({
      scenario: s,
      input_png_bytes: inputPng.length,
      zigpix,
      sharp: sharpT,
      ratio: parseFloat(ratio.toFixed(2)),
      samples,
    });

    console.log(
      `  median: zigpix ${fmt(zigpix.median_ms)} ms / sharp ${fmt(sharpT.median_ms)} ms → ratio ${ratio.toFixed(2)} (sharp÷zigpix)\n`,
    );
  }

  fixtureResults.push({
    fixture: { id: fx.id, file: fx.file, label: fx.label, path: `test/fixtures/${fx.file}` },
    scenarios: scenarioResults,
  });
}

// ── Console matrix ───────────────────────────────────────────────────────────

const colW = 12;
const pad = (s: string, w: number) => s.padStart(w);
const fxCol = 22;
console.log(
  `┌${"─".repeat(fxCol)}┬────────────┬──────────────────┬──────────────────┬──────────┐`,
);
console.log("│ Fixture                │ Scenario   │ zigpix median ms │ sharp median ms  │ ratio    │");
console.log(
  `├${"─".repeat(fxCol)}┼────────────┼──────────────────┼──────────────────┼──────────┤`,
);
for (const fr of fixtureResults) {
  for (const r of fr.scenarios) {
    const fxId = fr.fixture.id.length > fxCol ? fr.fixture.id.slice(0, fxCol - 1) + "…" : fr.fixture.id.padEnd(fxCol);
    const sid = r.scenario.id.padEnd(10);
    console.log(
      `│ ${fxId} │ ${sid} │ ${pad(fmt(r.zigpix.median_ms), colW)} │ ${pad(fmt(r.sharp.median_ms), colW)} │ ${pad(r.ratio.toFixed(2) + "×", 8)} │`,
    );
  }
}
console.log(
  `└${"─".repeat(fxCol)}┴────────────┴──────────────────┴──────────────────┴──────────┘`,
);
console.log("ratio = sharp_median / zigpix_median (>1 ⇒ zigpix faster wall-clock)\n");

// ── JSON ──────────────────────────────────────────────────────────────────────

const now = new Date().toISOString();
const jsonResult = {
  date: now,
  runner,
  pipeline: "decode PNG → resize → AVIF",
  fixture_dir: "test/fixtures",
  per_scenario: "Sharp resize (fit=cover) to inW×inH, then PNG bytes fed to timed loop",
  avif: { quality: AVIF_QUALITY, speed: AVIF_SPEED },
  iterations: { warmup: WARMUP_N, measure: MEASURE_N },
  write_samples: WRITE_SAMPLES,
  report_html: WRITE_SAMPLES ? "report.html (relative to bench/results/)" : null,
  fixtures: fixtureResults.map((fr) => ({
    id: fr.fixture.id,
    label: fr.fixture.label,
    source: fr.fixture.path,
    scenarios: fr.scenarios.map((r) => ({
      id: r.scenario.id,
      label: r.scenario.label,
      input_px: `${r.scenario.inW}×${r.scenario.inH}`,
      output_px: `${r.scenario.outW}×${r.scenario.outH}`,
      input_png_bytes: r.input_png_bytes,
      zigpix: r.zigpix,
      sharp: r.sharp,
      ratio_sharp_median_over_zigpix_median: r.ratio,
      sample_avif: r.samples ?? null,
    })),
  })),
};

// ── Markdown ─────────────────────────────────────────────────────────────────

const mdRows = fixtureResults
  .flatMap((fr) =>
    fr.scenarios.map(
      (r) =>
        `| ${fr.fixture.id} | ${r.scenario.label} | ${r.scenario.inW}×${r.scenario.inH} | ${r.scenario.outW}×${r.scenario.outH} | ${fmt(r.zigpix.median_ms)} | ${fmt(r.zigpix.min_ms)} | ${fmt(r.zigpix.max_ms)} | ${fmt(r.sharp.median_ms)} | ${fmt(r.sharp.min_ms)} | ${fmt(r.sharp.max_ms)} | **${r.ratio.toFixed(2)}×** |`,
    ),
  )
  .join("\n");

const mdResult = `# Benchmark Results (matrix)

**Date**: ${now}  
**Runner**: ${runner}  
**Pipeline**: decode PNG → resize → AVIF (quality=${AVIF_QUALITY}, speed=${AVIF_SPEED})  
**Warm-up / measure**: ${WARMUP_N} / ${MEASURE_N} per tool per scenario per fixture  
**Fixtures**: ${fixtures.map((f) => f.id).join(", ")} — PNGs under \`test/fixtures/\`, scaled to each input size (Sharp, \`fit=cover\`) once per scenario.

| fixture | シナリオ | 入力 (px) | 出力 (px) | zigpix med (ms) | zig min | zig max | sharp med (ms) | sharp min | sharp max | ratio |
|---------|----------|-----------|-----------|----------------:|--------:|--------:|---------------:|----------:|----------:|------:|
${mdRows}

**ratio** = sharp median ÷ zigpix median (**>1** means zigpix lower wall-clock median for this pipeline).

## Sample AVIFs & HTML

${
  WRITE_SAMPLES
    ? `Relative to \`bench/results/\`: \`report.html\`, and \`samples/matrix-{fixture}-{scenario}-zigpix.avif\` / \`…-sharp.avif\`.`
    : `Skipped (\`BENCH_WRITE_SAMPLES=0\`).`
}

## JSON

See \`benchmark.json\` in this directory for machine-readable rows (\`fixtures[]\` → \`scenarios[]\`).
`;

const jsonPath = join(OUT_DIR, "benchmark.json");
const mdPath = join(OUT_DIR, "benchmark.md");
const htmlPath = join(OUT_DIR, "report.html");

writeFileSync(jsonPath, JSON.stringify(jsonResult, null, 2) + "\n");
writeFileSync(mdPath, mdResult);

if (WRITE_SAMPLES) {
  const matrixRows: MatrixScenarioRow[] = fixtureResults.flatMap((fr) =>
    fr.scenarios.map((r) => {
      const sam = r.samples;
      if (!sam) {
        throw new Error(
          `WRITE_SAMPLES set but missing sample paths for ${fr.fixture.id} / ${r.scenario.id}`,
        );
      }
      return {
        fixture_id: fr.fixture.id,
        fixture_label: fr.fixture.label,
        id: r.scenario.id,
        label: r.scenario.label,
        input_px: `${r.scenario.inW}×${r.scenario.inH}`,
        output_px: `${r.scenario.outW}×${r.scenario.outH}`,
        ratio: r.ratio,
        zigpix_median_ms: r.zigpix.median_ms,
        sharp_median_ms: r.sharp.median_ms,
        zigpix_sample_rel: sam.zigpix_rel,
        sharp_sample_rel: sam.sharp_rel,
        zigpix_bytes: sam.zigpix_bytes,
        sharp_bytes: sam.sharp_bytes,
      };
    }),
  );
  writeMatrixHtml(htmlPath, {
    title: "zigpix vs Sharp — bench matrix",
    date: now,
    runner,
    pipeline: "decode PNG → resize → AVIF",
    avif: { quality: AVIF_QUALITY, speed: AVIF_SPEED },
    iterations: { warmup: WARMUP_N, measure: MEASURE_N },
    scenarios: matrixRows,
  });
}

console.log("Results saved:");
console.log(`  ${jsonPath}`);
console.log(`  ${mdPath}`);
if (WRITE_SAMPLES) {
  console.log(`  ${htmlPath}`);
  console.log(`  ${SAMPLES_DIR}/`);
}
