# zigpix

Zig 製の高速画像処理ライブラリです。  
JPEG / PNG をデコードし、Lanczos-3 リサイズを経て WebP / AVIF にエンコードします。

- **AVIF エンコード**: 代表ベンチでは speed=10 が Sharp より **wall-clock で短く**、Sharp がマルチスレッドで積み上げる **CPU user 時間より遥かに軽い**（条件は下表・[比較の読み方](#比較の読み方)）
- **WebP エンコード**: lossy / lossless 対応
- **Lanczos-3 リサイズ**: SIMD 最適化（aarch64 NEON / x86_64 SSE2）
- **Node.js / Bun / Deno 対応**: Node.js・Bun は koffi、Deno は `Deno.dlopen` 経由でネイティブバイナリを呼び出し

## インストール

**Node.js / Bun**

```bash
npm install zigpix
```

> **ESM 専用パッケージです。** `package.json` に `"type": "module"` が必要です。  
> CommonJS (`require`) は現在非対応です。

**Deno**

```bash
deno add npm:zigpix
```

または直接 `npm:` specifier を使用：

```typescript
import { decode, resize, encodeWebP, encodeAvif } from "npm:zigpix/deno";
```

> Deno での実行時は `--allow-ffi` フラグが必要です。

### システム依存ライブラリ

**v0.1.0 以降は追加インストール不要です。** `libavif` と `libaom` はバイナリに静的リンク済みです。

> ソースからビルドする場合（開発者向け）は `docs/operations.md` を参照してください。

## 使い方

```typescript
import { decode, resize, encodeWebP, encodeAvif } from "zigpix";
import { readFileSync, writeFileSync } from "fs";

// JPEG / PNG をデコード
const input = readFileSync("input.jpg");
const image = decode(input);

// Lanczos-3 リサイズ（幅指定、高さはアスペクト比維持）
const resized = resize(image, { width: 1920 });

// WebP エンコード
const webp = encodeWebP(resized, { quality: 92 });
writeFileSync("output.webp", webp);

// AVIF エンコード（libavif / libaom は静的リンク済み、追加インストール不要）
const avif = encodeAvif(resized, { quality: 60, speed: 10 });
if (avif) writeFileSync("output.avif", avif);
```

## API

### `decode(input: Buffer | Uint8Array): ImageBuffer`

JPEG または PNG をデコードして生ピクセルデータを返します。

```typescript
interface ImageBuffer {
  data: Buffer;     // 生ピクセル（row-major, top-left origin）
  width: number;
  height: number;
  channels: number; // 3 = RGB, 4 = RGBA
}
```

### `resize(image: ImageBuffer, options: ResizeOptions): ImageBuffer`

Lanczos-3 フィルタでリサイズします。`width` / `height` の片方を省略するとアスペクト比を維持します。

```typescript
interface ResizeOptions {
  width?: number;    // 出力幅（px）
  height?: number;   // 出力高さ（px）
  threads?: number;  // 並列スレッド数（デフォルト: 1）
}
```

### `encodeWebP(image: ImageBuffer, options?: WebPOptions): Buffer`

WebP にエンコードします。

```typescript
interface WebPOptions {
  quality?: number;   // 0–100（デフォルト: 92）
  lossless?: boolean; // ロスレス（デフォルト: false）
}
```

### `encodeAvif(image: ImageBuffer, options?: AvifOptions): Buffer | Uint8Array | null`

AVIF にエンコードします。以下の場合は `null` を返します：

- AVIF 無効でビルドされたバイナリを使用している
- `quality` が 0–100 の範囲外、または `speed` が 0–10 の範囲外

> Node.js / Bun では `Buffer`、Deno では `Uint8Array` を返します。

```typescript
interface AvifOptions {
  quality?: number; // 0–100（デフォルト: 60）
  speed?: number;   // 0–10（デフォルト: 6）。10 が最速
}
```

## ブラウザ / Cloudflare Pages 対応（WASM）

小〜中サイズの画像（〜1024×1024）はブラウザ上で直接 AVIF エンコードできます。  
`zigpix-wasm` パッケージ（libavif + libaom を WebAssembly にコンパイル済み）を使います。

```bash
npm install zigpix-wasm
```

```typescript
import createAvif from 'zigpix-wasm';          // Emscripten factory

const Module = await createAvif();
const ptr = Module._malloc(pixels.length);
Module.HEAPU8.set(pixels, ptr);
const outPtr = Module._avif_encode(ptr, width, height, 4, 60, 10); // quality=60 speed=10
Module._free(ptr);
if (outPtr) {
  const size = Module._avif_get_out_size();
  const avif = Module.HEAPU8.slice(outPtr, outPtr + size);
  Module._avif_free_output(outPtr);
  // avif は Uint8Array (ftyp brand: "avif" ✅)
}
```

TypeScript ラッパー（`js/index.ts`）を使うとより簡潔に記述できます。詳細は [`wasm/README.md`](./wasm/README.md) を参照してください。

### WASM パフォーマンス実測値

環境: Chrome (macOS arm64), RGBA, quality=60, speed=10 最速設定、warm-up×1 除外・3回中央値

| サイズ | Baseline (ms) | SIMD (ms) | Speedup |
|--------|:-------------:|:---------:|:-------:|
| 64×64      |  0.5 |  0.5 | 1.00× |
| 256×256    |  5.1 |  4.2 | **1.21×** |
| 512×512    | 16.5 | 14.6 | **1.13×** |
| 1024×1024  | 60.5 | 53.1 | **1.14×** |

> ※ speed=10（最速）の値。大画像・低 speed 設定では数秒〜数十秒になる場合あります。  
> 1024×1024 を超える画像は Web Worker 上での実行を推奨します。

---

## ベンチマーク

3840×2160 PNG → 1920×1080 AVIF / macOS aarch64 (Apple M) / ReleaseFast

| ツール | wall-clock（中央値）| CPU user | ファイルサイズ |
|--------|--------------------:|:--------:|---------------:|
| **zigpix speed=10**（シングルスレッド）| **0.710s** | 0.66s | 2.5 MB |
| zigpix speed=6（シングルスレッド）| 2.109s | 2.05s | 2.5 MB |
| Sharp 0.34 quality=60（〜8コア）| 1.141s | 9.27s | 1.5 MB |

### 比較の読み方

- **条件はこの1ケースに限る**（3840×2160 PNG → 1920×1080 AVIF、macOS arm64、ReleaseFast、Sharp は quality=60、zigpix は speed=10 / 6）。解像度・品質・マシンが変われば順位は入れ替わり得る。
- **wall-clock** は体感に直結。上表では zigpix speed=10 が **0.710s**、Sharp が **1.141s**。
- **CPU user** は「そのプロセスが消費した CPU 時間の合計」。Sharp の **9.27s** は **複数コアに分散した合算**であり、「Sharp が遅い」のではなく「マルチスレッドで総仕事量を積み上げている」結果として大きく見える。**2コア VPS などリソースを奪い合う環境**では、この総量が他リクエストの遅延に効きやすい。
- **ファイルサイズ**は同条件でも一致していない（Sharp 1.5 MB / zigpix 2.5 MB）。圧縮率まで揃えた公平比較ではない。
- **結論**: 「あらゆる場面で Sharp より常に上」ではなく、**低コア・CPU 予算を抑えたい用途**で zigpix のバランスが効きやすい、という立ち位置。

## トラブルシューティング

**`encodeAvif()` が常に `null` を返す**

`quality` / `speed` が範囲外の場合は `null` を返します（仕様）:
- `quality`: 整数かつ 0–100 の範囲外
- `speed`: 整数かつ 0–10 の範囲外

**`Error: Cannot find module 'zigpix-darwin-arm64'` などのエラー**

対応していないプラットフォームです。[動作環境](#動作環境)を確認してください。

---

## 動作環境

| ランタイム | macOS arm64 | Linux x86_64 |
|-----------|:-----------:|:------------:|
| Node.js 18+ | ✅ | ✅ |
| Bun | ✅ | ✅ |
| Deno 2.x | ✅ | ✅ |
| Windows | ❌ 未対応 | — |
| Cloudflare Pages（WASM） | ✅ `zigpix-wasm` | ✅ `zigpix-wasm` |
| Cloudflare Workers | ❌（CPU 制限により非対応）| — |

## ライセンス

MIT © 2026 月村つかさ

本ライブラリは以下のオープンソースライブラリを使用しています。  
詳細は [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES) を参照してください。

- libjpeg-turbo (BSD 3-Clause / IJG)
- zlib (zlib License)
- libpng (PNG Reference Library License v2)
- libwebp (BSD 3-Clause)
- libavif (BSD 2-Clause)
- libaom (BSD 2-Clause)

---

## 開発者向け情報

ソースからビルドする場合は以下を参照してください。

### セットアップ

```bash
# Zig 0.13.0（mise）
mise use zig@0.13.0

# submodule 初期化
git submodule update --init --recursive
```

### よく使うコマンド

```bash
zig build                          # Dev binary
zig build -Doptimize=ReleaseFast   # Release
zig build test                     # ユニットテスト
zig build lib                      # FFI 用共有ライブラリ (.dylib / .so)
zig build bench                    # ベンチマーク
```

### ドキュメント

- 設計要件: `RFC.md`
- 日常運用・libavif セットアップ: `docs/operations.md`
- vendor 依存管理: `docs/deps.md`
- 実装チェックリスト: `docs/CHECKLIST.md`
