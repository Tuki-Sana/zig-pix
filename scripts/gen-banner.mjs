import sharp from "sharp";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

// zenpix — decode + resize (Lanczos-3) + encode
const { decode, resize, encodeWebP } = await import("../js/dist/index.js");

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const logoPath = join(root, "assets/zenpix-logo.jpg");

// ── ロゴ角のピクセル色をサンプリング → 背景色に使う ──────────────────────────
const { data: corner } = await sharp(logoPath)
  .extract({ left: 4, top: 4, width: 1, height: 1 })
  .raw()
  .toBuffer({ resolveWithObject: true });
const bg = { r: corner[0], g: corner[1], b: corner[2] };

// ── Logo: zenpix で高品質リサイズ ────────────────────────────────────────────
const raw = decode(readFileSync(logoPath));

// ── 横組みバナー 16:9 (1280×720) ─────────────────────────────────────────────
const W = 1280, H = 720;
const LOGO_SIZE = 580;
const LOGO_X = 60;
const LOGO_Y = (H - LOGO_SIZE) / 2;
const TEXT_X = LOGO_X + LOGO_SIZE + 60;
const TEXT_W = W - TEXT_X - 60;

const resized = resize(raw, { width: LOGO_SIZE, height: LOGO_SIZE });
const logoWebP = encodeWebP(resized, { lossless: true });

const textSvg = Buffer.from(`
<svg xmlns="http://www.w3.org/2000/svg" width="${TEXT_W}" height="${H}">
  <text x="0" y="310"
    font-family="'Helvetica Neue', Helvetica, Arial, sans-serif"
    font-size="108" font-weight="700" fill="#F0F4FF"
    dominant-baseline="middle" letter-spacing="-1">zenpix</text>
  <text x="4" y="400"
    font-family="'Helvetica Neue', Helvetica, Arial, sans-serif"
    font-size="26" font-weight="400" fill="#7BA7C4"
    dominant-baseline="middle">High-performance image processing</text>
</svg>`);

const background = await sharp({
  create: { width: W, height: H, channels: 3, background: bg },
}).png().toBuffer();

await sharp(background)
  .composite([
    { input: logoWebP, left: LOGO_X, top: LOGO_Y },
    { input: textSvg, left: TEXT_X, top: 0 },
  ])
  .jpeg({ quality: 95 })
  .toFile(join(root, "assets/zenpix-banner.jpg"));

console.log("Generated: assets/zenpix-banner.jpg (1280×720, 16:9)");
