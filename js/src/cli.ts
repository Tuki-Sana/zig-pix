/**
 * zenpix CLI — decode → resize → encode pipeline
 *
 * Usage:
 *   zenpix input.jpg                         → input.avif
 *   zenpix input.jpg output.webp             → output.webp
 *   zenpix *.jpg --out-dir ./avif/           → batch
 *   cat input.jpg | zenpix - output.avif     → stdin
 *   zenpix input.jpg -                       → stdout
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { extname, basename, join, dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { decode, resize, encodeAvif, encodeWebP, encodePng } from "./index.js";
import type { ImageBuffer } from "./index.js";

// ── Types ─────────────────────────────────────────────────────────────────────

type Format = "avif" | "webp" | "png";

interface EncodeOpts {
  format: Format;
  quality: number;
  speed: number;
  threads: number;
  compression: number;
}

interface ResizeOpts {
  maxSize?: number;
  width?: number;
  height?: number;
  fit: "stretch" | "contain" | "cover";
}

// ── Constants ─────────────────────────────────────────────────────────────────

const EXT_TO_FORMAT: Record<string, Format> = {
  ".avif": "avif",
  ".webp": "webp",
  ".png": "png",
};

const FORMAT_TO_EXT: Record<Format, string> = {
  avif: ".avif",
  webp: ".webp",
  png: ".png",
};

const DEFAULT_QUALITY: Record<Format, number> = {
  avif: 60,
  webp: 92,
  png: 0,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

function getVersion(): string {
  const pkgPath = join(dirname(fileURLToPath(import.meta.url)), "../../package.json");
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as { version: string };
  return pkg.version;
}

function err(msg: string): never {
  process.stderr.write(`zenpix: ${msg}\n`);
  process.exit(1);
}

function log(msg: string, toStdout: boolean): void {
  if (!toStdout) process.stderr.write(msg + "\n");
  else process.stderr.write(msg + "\n");
}

async function readStdin(): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(Buffer.from(chunk as Uint8Array));
  }
  return Buffer.concat(chunks);
}

function detectFormat(outputPath: string, formatFlag?: string): Format {
  if (formatFlag) {
    if (!["avif", "webp", "png"].includes(formatFlag)) {
      err(`unknown format "${formatFlag}". Use avif, webp, or png`);
    }
    return formatFlag as Format;
  }
  if (outputPath !== "-") {
    const ext = extname(outputPath).toLowerCase();
    if (ext in EXT_TO_FORMAT) return EXT_TO_FORMAT[ext]!;
  }
  return "avif";
}

function applyResize(img: ImageBuffer, opts: ResizeOpts): ImageBuffer {
  const { maxSize, width, height, fit } = opts;
  if (maxSize !== undefined) {
    const long = Math.max(img.width, img.height);
    if (long <= maxSize) return img;
    // 片側指定→アスペクト比は zenpix が自動維持、fit 不要
    return img.width >= img.height
      ? resize(img, { width: maxSize })
      : resize(img, { height: maxSize });
  }
  if (width !== undefined || height !== undefined) {
    return resize(img, { width, height, fit });
  }
  return img;
}

function encodeImage(img: ImageBuffer, opts: EncodeOpts): Buffer {
  switch (opts.format) {
    case "avif": {
      const result = encodeAvif(img, {
        quality: opts.quality,
        speed: opts.speed,
        threads: opts.threads,
      });
      if (!result) err("AVIF encode failed (quality or speed out of range, or AVIF not supported)");
      return Buffer.from(result);
    }
    case "webp":
      return encodeWebP(img, { quality: opts.quality }) as Buffer;
    case "png":
      return encodePng(img, { compression: opts.compression }) as Buffer;
  }
}

function outputPath(inputPath: string, format: Format, outDir?: string): string {
  const base = basename(inputPath, extname(inputPath)) + FORMAT_TO_EXT[format];
  return outDir ? join(outDir, base) : join(dirname(inputPath), base);
}

function writeOutput(dest: string, data: Buffer): void {
  if (dest === "-") {
    process.stdout.write(data);
    return;
  }
  mkdirSync(dirname(resolve(dest)), { recursive: true });
  writeFileSync(dest, data);
}

// ── Help ──────────────────────────────────────────────────────────────────────

function printHelp(): void {
  process.stdout.write(`\
zenpix v${getVersion()} — high-performance image converter (AVIF / WebP / PNG)

Usage:
  zenpix [input...] [output] [options]

Arguments:
  input      Input file(s) or - for stdin
  output     Output file or - for stdout (single input only)
             Omit to replace input extension with output format extension

Options:
  -f, --format <fmt>       Output format: avif | webp | png  (default: avif, or from output extension)
  -q, --quality <n>        Quality 0–100  (default: 60 for AVIF, 92 for WebP)
  -s, --speed <n>          AVIF encode speed 0–10  (default: 6; 10 = fastest)
      --threads <n>        AVIF encode threads  (default: 1)
      --max-size <px>      Resize longest side to at most N px (contain)
      --width <px>         Output width
      --height <px>        Output height
      --fit <mode>         Resize fit: stretch | contain | cover  (default: contain)
      --compression <n>    PNG zlib compression 0–9  (default: 6)
      --out-dir <dir>      Output directory (required for batch input)
  -h, --help               Show this help
  -v, --version            Show version

Examples:
  zenpix photo.jpg                         # → photo.avif (AVIF, quality=60)
  zenpix photo.jpg out.webp -q 92         # → WebP
  zenpix photo.jpg --max-size 1920        # → photo.avif resized to ≤1920px
  zenpix *.jpg --out-dir ./avif/          # batch → avif/
  cat photo.jpg | zenpix - out.avif       # stdin
  zenpix photo.jpg -                      # stdout (pipe to next command)
  zenpix photo.jpg out.avif --threads 8  # multi-threaded AVIF encode
`);
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const { values, positionals } = parseArgs({
    args: process.argv.slice(2),
    allowPositionals: true,
    options: {
      format:      { type: "string",  short: "f" },
      quality:     { type: "string",  short: "q" },
      speed:       { type: "string",  short: "s" },
      threads:     { type: "string" },
      "max-size":  { type: "string" },
      width:       { type: "string" },
      height:      { type: "string" },
      fit:         { type: "string" },
      compression: { type: "string" },
      "out-dir":   { type: "string" },
      help:        { type: "boolean", short: "h" },
      version:     { type: "boolean", short: "v" },
    },
  });

  if (values.help) { printHelp(); return; }
  if (values.version) { process.stdout.write(getVersion() + "\n"); return; }

  // ── Resolve inputs / output ──────────────────────────────────────────────

  if (positionals.length === 0) {
    printHelp();
    process.exit(1);
  }

  const outDir = values["out-dir"];

  // Last positional is output if it looks like a file path (has extension or is "-")
  // and there is more than one positional, or it differs from input.
  let inputs: string[];
  let outputArg: string | undefined;

  if (positionals.length === 1) {
    inputs = [positionals[0]!];
    outputArg = undefined;
  } else {
    const last = positionals[positionals.length - 1]!;
    const looksLikeOutput = last === "-" || extname(last) !== "" || outDir !== undefined;
    if (looksLikeOutput && !outDir) {
      inputs = positionals.slice(0, -1);
      outputArg = last;
    } else {
      inputs = positionals;
      outputArg = undefined;
    }
  }

  const isStdin = inputs.length === 1 && inputs[0] === "-";
  const isStdout = outputArg === "-";
  const isBatch = inputs.length > 1 || (inputs.length === 1 && outDir !== undefined && !isStdin);

  if (isBatch && isStdout) err("stdout (-) cannot be used with batch input");
  if (isBatch && !outDir && outputArg === undefined) {
    // Multiple inputs, no --out-dir, no explicit output → auto-place beside each input
  }
  if (isStdin && outputArg === undefined && outDir === undefined) {
    err("stdin input requires an output path or --out-dir");
  }

  // ── Parse options ────────────────────────────────────────────────────────

  // Format is determined per-file in batch; determined once for single
  const formatFlag = values.format;
  const speed = values.speed !== undefined ? parseInt(values.speed, 10) : 6;
  const threads = values.threads !== undefined ? parseInt(values.threads, 10) : 1;
  const compression = values.compression !== undefined ? parseInt(values.compression, 10) : 6;
  const maxSize = values["max-size"] !== undefined ? parseInt(values["max-size"], 10) : undefined;
  const widthOpt = values.width !== undefined ? parseInt(values.width, 10) : undefined;
  const heightOpt = values.height !== undefined ? parseInt(values.height, 10) : undefined;
  const fitOpt = (values.fit ?? "contain") as "stretch" | "contain" | "cover";

  const resizeOpts: ResizeOpts = { maxSize, width: widthOpt, height: heightOpt, fit: fitOpt };
  const hasResize = maxSize !== undefined || widthOpt !== undefined || heightOpt !== undefined;

  // ── Process files ────────────────────────────────────────────────────────

  async function processOne(inputPath: string, dest: string): Promise<void> {
    const toStdout = dest === "-";

    const raw = inputPath === "-" ? await readStdin() : readFileSync(inputPath);
    const format = detectFormat(dest, formatFlag);
    const quality = values.quality !== undefined ? parseInt(values.quality, 10) : DEFAULT_QUALITY[format];

    const encodeOpts: EncodeOpts = { format, quality, speed, threads, compression };

    let img = decode(raw);
    if (hasResize) img = applyResize(img, resizeOpts);
    const out = encodeImage(img, encodeOpts);

    writeOutput(dest, out);
    if (!toStdout) {
      log(
        `${inputPath === "-" ? "stdin" : inputPath} → ${dest} (${format.toUpperCase()}, ${(out.length / 1024).toFixed(0)} kB)`,
        toStdout,
      );
    }
  }

  if (isStdin) {
    const dest = outputArg ?? (outDir ? join(outDir, "output.avif") : "output.avif");
    await processOne("-", dest);
    return;
  }

  if (!isBatch) {
    const inputPath = inputs[0]!;
    const format = detectFormat(outputArg ?? "", formatFlag);
    const dest = outputArg ?? outputPath(inputPath, format, outDir);
    await processOne(inputPath, dest);
    return;
  }

  // Batch
  let errors = 0;
  for (const inputPath of inputs) {
    try {
      const format = detectFormat("", formatFlag);
      const dest = outputPath(inputPath, format, outDir);
      await processOne(inputPath, dest);
    } catch (e) {
      process.stderr.write(`zenpix: ${inputPath}: ${e instanceof Error ? e.message : String(e)}\n`);
      errors++;
    }
  }
  if (errors > 0) process.exit(1);
}

main().catch((e: unknown) => {
  process.stderr.write(`zenpix: ${e instanceof Error ? e.message : String(e)}\n`);
  process.exit(1);
});
