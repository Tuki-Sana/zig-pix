#!/usr/bin/env node
/**
 * Aggregate bench/bench.ts benchmark.json from multiple runs (same fixtures).
 * For each cell: median of zenpix median_ms, median of sharp median_ms, then ratio = sharp/zenpix.
 *
 * Usage:
 *   node scripts/bench-aggregate-multi-run.mjs
 *     → defaults: bench-results-vps-run{1,2,3}, bench/results-mac-run{1,2,3}
 *
 *   node scripts/bench-aggregate-multi-run.mjs path/to/a.json path/to/b.json path/to/c.json
 *     → one environment, markdown table (fixture × scenario with ms + ratio) to stdout
 */
import { readFileSync } from "fs";
import { dirname, join, resolve } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");

const DEFAULT_VPS = [1, 2, 3].map(
  (n) => join(root, `bench-results-vps-run${n}`, "benchmark.json"),
);
const DEFAULT_MAC = [1, 2, 3].map(
  (n) => join(root, "bench", `results-mac-run${n}`, "benchmark.json"),
);

function median3(a, b, c) {
  const s = [a, b, c].sort((x, y) => x - y);
  return s[1];
}

function medRatio(z, s) {
  return Math.round((s / z) * 100) / 100;
}

function aggregate(paths) {
  const runs = paths.map((p) => JSON.parse(readFileSync(p, "utf8")));
  const rows = [];
  for (const f of runs[0].fixtures) {
    for (const sc of f.scenarios) {
      const z = [];
      const sh = [];
      for (const r of runs) {
        const fx = r.fixtures.find((x) => x.id === f.id);
        const s = fx.scenarios.find((x) => x.id === sc.id);
        z.push(s.zenpix.median_ms);
        sh.push(s.sharp.median_ms);
      }
      const zm = median3(z[0], z[1], z[2]);
      const sm = median3(sh[0], sh[1], sh[2]);
      rows.push({
        fid: f.id,
        sid: sc.id,
        zm,
        sm,
        r: medRatio(zm, sm),
      });
    }
  }
  return { runs, rows };
}

function ratioTableMd(rows) {
  const byF = new Map();
  for (const x of rows) {
    if (!byF.has(x.fid)) byF.set(x.fid, {});
    byF.get(x.fid)[x.sid] = x.r;
  }
  const lines = [
    "| フィクスチャ | FHD | WQHD | 4K |",
    "|--------------|----:|-----:|---:|",
  ];
  for (const fid of byF.keys()) {
    const o = byF.get(fid);
    const fmt = (v) => Number(v).toFixed(2);
    lines.push(
      `| \`${fid}\` | ${fmt(o.fhd)} | ${fmt(o.wqhd)} | ${fmt(o.uhd4k)} |`,
    );
  }
  return lines.join("\n");
}

function fullTableMd(rows) {
  const lines = [
    "| フィクスチャ | シナリオ | zenpix（ms） | Sharp（ms） | ratio |",
    "|--------------|----------|-------------:|------------:|------:|",
  ];
  const sidLabel = { fhd: "FHD", wqhd: "WQHD", uhd4k: "4K" };
  const rf = (v) => Number(v).toFixed(2);
  for (const x of rows) {
    lines.push(
      `| ${x.fid} | ${sidLabel[x.sid] ?? x.sid} | ${x.zm.toFixed(2)} | ${x.sm.toFixed(2)} | ${rf(x.r)} |`,
    );
  }
  return lines.join("\n");
}

function main() {
  const args = process.argv.slice(2);
  if (args.length === 3) {
    const { runs, rows } = aggregate(args.map((a) => resolve(a)));
    console.log(fullTableMd(rows));
    console.log("\nruns:", runs.map((r) => r.date).join(", "));
    return;
  }
  if (args.length !== 0) {
    console.error(
      "Usage: node scripts/bench-aggregate-multi-run.mjs\n" +
        "   or: node scripts/bench-aggregate-multi-run.mjs <j1> <j2> <j3>  (three JSON paths)",
    );
    process.exit(1);
  }

  const v = aggregate(DEFAULT_VPS);
  const m = aggregate(DEFAULT_MAC);

  console.log("## VPS (ratio table)\n");
  console.log(ratioTableMd(v.rows));
  console.log("\ndates:", v.runs.map((r) => r.date).join("\n"));

  console.log("\n## Mac (ratio table)\n");
  console.log(ratioTableMd(m.rows));
  console.log("\ndates:", m.runs.map((r) => r.date).join("\n"));

  console.log("\n## VPS (full ms)\n");
  console.log(fullTableMd(v.rows));

  console.log("\n## Mac (full ms)\n");
  console.log(fullTableMd(m.rows));
}

main();
