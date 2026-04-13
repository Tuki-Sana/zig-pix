# zigpix

Zig 製の高速画像処理ライブラリです。  
JPEG / PNG をデコードし、Lanczos-3 リサイズを経て WebP / AVIF にエンコードします。

- **AVIF エンコード**: speed=10 で Sharp より 1.6× 高速 (wall-clock)、CPU 効率は約 14×
- **WebP エンコード**: lossy / lossless 対応
- **Lanczos-3 リサイズ**: SIMD 最適化（aarch64 NEON / x86_64 SSE2）
- **Node.js 対応**: koffi 経由でネイティブバイナリを呼び出し

## インストール

```bash
npm install zigpix
```

### システム依存ライブラリ（AVIF エンコードに必要）

AVIF エンコードを使う場合は `libavif` をシステムにインストールしてください。

**macOS (Apple Silicon)**
```bash
brew install libavif
```

**Linux (Ubuntu / Debian)**
```bash
apt install libavif-dev
```

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

// AVIF エンコード（libavif が必要）
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

### `encodeAvif(image: ImageBuffer, options?: AvifOptions): Buffer | null`

AVIF にエンコードします。`libavif` が未インストールの場合は `null` を返します。

```typescript
interface AvifOptions {
  quality?: number; // 0–100（デフォルト: 60）
  speed?: number;   // 0–10（デフォルト: 6）。10 が最速
}
```

## ベンチマーク

3840×2160 PNG → 1920×1080 AVIF / macOS aarch64 (Apple M) / ReleaseFast

| ツール | wall-clock（中央値）| CPU user | ファイルサイズ |
|--------|--------------------:|:--------:|---------------:|
| **zigpix speed=10**（シングルスレッド）| **0.710s** | 0.66s | 2.5 MB |
| zigpix speed=6（シングルスレッド）| 2.109s | 2.05s | 2.5 MB |
| Sharp 0.34 quality=60（〜8コア）| 1.141s | 9.27s | 1.5 MB |

## 動作環境

| 環境 | 対応状況 |
|------|---------|
| Node.js 18+ (macOS arm64) | ✅ |
| Node.js 18+ (Linux x86_64) | ✅ |
| Bun (macOS arm64 / Linux x86_64) | ✅ |
| Windows | 未対応 |
| Cloudflare Workers / Pages | 未対応（WASM 版は将来対応予定）|

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
