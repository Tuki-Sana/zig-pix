/**
 * Thin static HTML for benchmark results (relative ./samples/*.avif links).
 */

import { writeFileSync } from "fs";

export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export interface MatrixScenarioRow {
  id: string;
  label: string;
  input_px: string;
  output_px: string;
  ratio: number;
  zigpix_median_ms: number;
  sharp_median_ms: number;
  zigpix_sample_rel: string;
  sharp_sample_rel: string;
  zigpix_bytes: number;
  sharp_bytes: number;
  /** When set, HTML groups rows by fixture (multi-image matrix bench). */
  fixture_id?: string;
  fixture_label?: string;
}

function matrixScenarioSection(s: MatrixScenarioRow, scenarioHeading: "h2" | "h3"): string {
  const H = scenarioHeading;
  return `
  <section class="scenario">
    <${H}>${escapeHtml(s.label)} <span class="id">(${escapeHtml(s.id)})</span></${H}>
    <p class="meta">${escapeHtml(s.input_px)} → ${escapeHtml(s.output_px)} · ratio (sharp÷zigpix) <strong>${s.ratio.toFixed(2)}×</strong></p>
    <p class="timing">zigpix median ${s.zigpix_median_ms.toFixed(2)} ms · sharp median ${s.sharp_median_ms.toFixed(2)} ms</p>
    <p class="bytes">${s.zigpix_bytes.toLocaleString()} bytes (zigpix) · ${s.sharp_bytes.toLocaleString()} bytes (sharp)</p>
    <div class="row">
      <figure>
        <figcaption>zigpix</figcaption>
        <img src="${escapeHtml(s.zigpix_sample_rel)}" alt="zigpix AVIF" width="320" loading="lazy" />
      </figure>
      <figure>
        <figcaption>Sharp</figcaption>
        <img src="${escapeHtml(s.sharp_sample_rel)}" alt="Sharp AVIF" width="320" loading="lazy" />
      </figure>
    </div>
  </section>`;
}

export function writeMatrixHtml(
  outPath: string,
  opts: {
    title: string;
    date: string;
    runner: string;
    pipeline: string;
    avif: { quality: number; speed: number };
    iterations: { warmup: number; measure: number };
    scenarios: MatrixScenarioRow[];
  },
): void {
  const multiFixture = opts.scenarios.some((s) => s.fixture_id !== undefined && s.fixture_id !== "");

  let sections: string;
  if (!multiFixture) {
    sections = opts.scenarios.map((s) => matrixScenarioSection(s, "h2")).join("\n");
  } else {
    const order: string[] = [];
    const byId = new Map<string, MatrixScenarioRow[]>();
    for (const s of opts.scenarios) {
      const fid = s.fixture_id ?? "";
      if (!byId.has(fid)) {
        byId.set(fid, []);
        order.push(fid);
      }
      byId.get(fid)!.push(s);
    }
    sections = order
      .map((fid) => {
        const rows = byId.get(fid)!;
        const first = rows[0]!;
        const title = escapeHtml(first.fixture_label ?? fid);
        const idPart = fid ? ` <span class="id">(${escapeHtml(fid)})</span>` : "";
        const inner = rows.map((r) => matrixScenarioSection(r, "h3")).join("\n");
        return `
  <section class="fixture-block">
    <h2 class="fixture-title">${title}${idPart}</h2>
${inner}
  </section>`;
      })
      .join("\n");
  }

  const html = `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(opts.title)}</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 1rem 1.5rem; max-width: 56rem; }
    h1 { font-size: 1.25rem; }
    .runner, .pipeline { color: #444; font-size: 0.9rem; }
    .fixture-block { margin-top: 2rem; border-top: 1px solid #bbb; padding-top: 1rem; }
    .fixture-title { font-size: 1.1rem; margin-bottom: 0.5rem; }
    .scenario { margin-top: 1.25rem; border-top: 1px solid #ddd; padding-top: 1rem; }
    .fixture-block .scenario:first-of-type { margin-top: 0.75rem; border-top: none; padding-top: 0; }
    .id { color: #666; font-weight: normal; }
    .row { display: flex; flex-wrap: wrap; gap: 1.5rem; margin-top: 0.5rem; }
    figure { margin: 0; }
    figcaption { font-size: 0.85rem; margin-bottom: 0.25rem; }
    img { max-width: 100%; height: auto; background: #f0f0f0; }
    .bytes { font-size: 0.85rem; color: #333; }
  </style>
</head>
<body>
  <h1>${escapeHtml(opts.title)}</h1>
  <p class="runner"><strong>Date</strong> ${escapeHtml(opts.date)} · <strong>Runner</strong> ${escapeHtml(opts.runner)}</p>
  <p class="pipeline">${escapeHtml(opts.pipeline)} · AVIF quality=${opts.avif.quality}, speed=${opts.avif.speed} · warm-up ${opts.iterations.warmup} / measure ${opts.iterations.measure}</p>
  <p>Open this file from the <code>bench/results/</code> directory so relative <code>samples/</code> paths resolve.</p>
${sections}
</body>
</html>
`;
  writeFileSync(outPath, html, "utf8");
}

export function writeQualityHtml(
  outPath: string,
  opts: {
    date: string;
    runner: string;
    node: string;
    tolerance_pct: number;
    anchor: { quality: number; speed: number; bytes: number };
    zigpix: { quality: number; speed: number; bytes: number; within: boolean };
    timings: { zigpix_median_ms: number; sharp_median_ms: number; ratio: number };
    zigpix_sample_rel: string;
    sharp_sample_rel: string;
    pixels: string;
  },
): void {
  const html = `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>benchmark-quality (encode-only, size-matched)</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 1rem 1.5rem; max-width: 48rem; }
    table { border-collapse: collapse; margin: 1rem 0; }
    th, td { border: 1px solid #ccc; padding: 0.35rem 0.6rem; text-align: left; }
    th { background: #f5f5f5; }
    .row { display: flex; flex-wrap: wrap; gap: 1.5rem; margin-top: 1rem; }
    figure { margin: 0; }
    figcaption { font-size: 0.85rem; margin-bottom: 0.25rem; }
    img { max-width: 100%; height: auto; background: #f0f0f0; }
  </style>
</head>
<body>
  <h1>benchmark-quality (encode-only, size-matched)</h1>
  <p><strong>Date</strong> ${escapeHtml(opts.date)} · <strong>Runner</strong> ${escapeHtml(opts.runner)} · <strong>Node</strong> ${escapeHtml(opts.node)}</p>
  <p>Tolerance ±${opts.tolerance_pct}% · ${escapeHtml(opts.pixels)}</p>
  <table>
    <tr><th>Sharp anchor</th><td>quality ${opts.anchor.quality}, speed ${opts.anchor.speed}, ${opts.anchor.bytes.toLocaleString()} bytes</td></tr>
    <tr><th>zigpix (calibrated)</th><td>quality ${opts.zigpix.quality}, speed ${opts.zigpix.speed}, ${opts.zigpix.bytes.toLocaleString()} bytes · within band: ${opts.zigpix.within ? "yes" : "no"}</td></tr>
    <tr><th>zigpix encode median</th><td>${opts.timings.zigpix_median_ms.toFixed(2)} ms</td></tr>
    <tr><th>Sharp encode median</th><td>${opts.timings.sharp_median_ms.toFixed(2)} ms</td></tr>
    <tr><th>ratio (sharp÷zigpix)</th><td>${opts.timings.ratio.toFixed(2)}×</td></tr>
  </table>
  <div class="row">
    <figure>
      <figcaption>zigpix</figcaption>
      <img src="${escapeHtml(opts.zigpix_sample_rel)}" alt="zigpix AVIF" width="320" loading="lazy" />
    </figure>
    <figure>
      <figcaption>Sharp (anchor)</figcaption>
      <img src="${escapeHtml(opts.sharp_sample_rel)}" alt="Sharp AVIF" width="320" loading="lazy" />
    </figure>
  </div>
  <p style="font-size:0.85rem;color:#444;">Open from <code>bench/results/</code> so <code>samples/</code> paths work.</p>
</body>
</html>
`;
  writeFileSync(outPath, html, "utf8");
}
