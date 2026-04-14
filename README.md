# zigpix

Zig 製の高速画像処理ライブラリです。  
JPEG / PNG / 静止画 WebP をデコードし、Lanczos-3 リサイズを経て WebP / AVIF にエンコードします。  
**HEIC / HEIF は非対応。** 必要ならクライアントで JPEG/PNG に変換してから渡してください（HEVC 特許・対応環境の都合でコアのスコープ外）。

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

// JPEG / PNG / WebP（静止画）をデコード
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

JPEG・PNG・静止画 WebP をデコードして生ピクセルデータを返します。HEIC / HEIF・アニメーション WebP・その他の形式は **未対応**（失敗時は `zigpix: decode failed`）。

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

### Node / `bench/bench.ts`（FHD・WQHD・4K 相当）

`npm run build` のうえ `npx tsx bench/bench.ts`（`sharp` は `devDependencies` に含む）。**同一パイプライン**: PNG **デコード** → **リサイズ**（出力ピクセルは表のとおり）→ **AVIF エンコード（quality=60, speed=6）**。入力 PNG は `test/fixtures/bench_input.png` を、**計測ループの外で** Sharp（`fit=cover`）により各代表解像度へ一度だけ拡大したバイト列。各シナリオで zigpix / Sharp を **warm-up 2・計測 10**し、**wall-clock の中央値（ms）**を比較。**ratio = Sharp 中央値 ÷ zigpix 中央値**（**1 超**なら zigpix の中央値が速い）。

| シナリオ | 入力 | 出力 | zigpix（ms） | Sharp（ms） | ratio |
|----------|------|------|-------------:|------------:|------:|
| FHD 相当 | 1920×1080 | 960×540 | 139.90 | 37.80 | **0.27×** |
| WQHD 相当 | 2560×1440 | 1280×720 | 242.27 | 44.47 | **0.18×** |
| 4K 相当 | 3840×2160 | 1920×1080 | 558.33 | 83.46 | **0.15×** |

実測環境の例: **macOS arm64（Apple M）・ローカル**（2026-04-14 頃、`zigpix` 0.1.3 npm バイナリ、Sharp 0.34）。**GitHub Actions**（`ubuntu-24.04`）でも同スクリプトを実行し、成果物 `benchmark-linux-x64` に `bench/results/benchmark.md` と `benchmark.json` が添付される。

> 上表の条件では **Sharp の wall-clock が速い**。一方、次の「3840→1920」一点比較では **zigpix speed=10 が wall-clock で有利**のように、**解像度・パイプライン（デコード込みか・encoder speed）・マシン**で順位は入れ替わり得る。本マトリクスはトレンド解像度での **再現可能な比較**を先に置くためのもの。

### 3840×2160 PNG → 1920×1080 AVIF（手動計測・一点比較）

macOS aarch64 (Apple M) / ReleaseFast

| ツール | wall-clock（中央値）| CPU user | ファイルサイズ |
|--------|--------------------:|:--------:|---------------:|
| **zigpix speed=10**（シングルスレッド）| **0.710s** | 0.66s | 2.5 MB |
| zigpix speed=6（シングルスレッド）| 2.109s | 2.05s | 2.5 MB |
| Sharp 0.34 quality=60（〜8コア）| 1.141s | 9.27s | 1.5 MB |

### 比較の読み方

- **自動マトリクス**（`bench/bench.ts`）と**下の1ケース表**は別条件。前者は **decode+resize+AVIF（speed=6）** の 3 解像度、後者は **3840×2160 PNG → 1920×1080 AVIF**（zigpix は speed=10 / 6、Sharp は quality=60、macOS arm64、ReleaseFast）。解像度・品質・マシンが変われば順位は入れ替わり得る。
- **wall-clock** は体感に直結。上表では zigpix speed=10 が **0.710s**、Sharp が **1.141s**。
- **CPU user** は「そのプロセスが消費した CPU 時間の合計」。Sharp の **9.27s** は **複数コアに分散した合算**であり、「Sharp が遅い」のではなく「マルチスレッドで総仕事量を積み上げている」結果として大きく見える。**2コア VPS などリソースを奪い合う環境**では、この総量が他リクエストの遅延に効きやすい。
- **ファイルサイズ**は同条件でも一致していない（Sharp 1.5 MB / zigpix 2.5 MB）。圧縮率まで揃えた公平比較ではない。
- **結論**: 「あらゆる場面で Sharp より常に上」ではなく、**低コア・CPU 予算を抑えたい用途**で zigpix のバランスが効きやすい、という立ち位置。

### ベンチの拡張（方針）

- **今ある計測**は「同一パイプライン・同じ encoder の数値（quality / speed）」での **壁時計の比較**。**知覚画質やファイルサイズを揃えたうえでの速度**は別問題で、実装するならパラメータ探索や指標（SSIM 等）が要り、CI 本体には載せず **別スクリプト・手元・週次ジョブ**などに分ける想定。
- **主用途はイラスト**のため、写真 8K の網羅より、線・平坦色に効く**少数のイラスト系フィクスチャ**を足すのは後追いでよい。現状は `bench_input.png` を代表解像度へ拡大した 1 系統で、**トレンド解像度での再現性**を優先している。

品質・サイズ揃えのベンチは **`bench/bench-quality.ts`** でスパイク済み（`npm run build` のうえ **`npm run bench:quality`**）。Sharp をアンカーに **AVIF encode のみ**を計測し、zigpix の `quality` を走査して出力バイトを既定 ±10% 帯へ寄せる。成果物は `bench/results/benchmark-quality.json` / `benchmark-quality.md`。**CI には未接続**（手元・任意の週次ジョブ向け）。拡張するときは下のチェックリストで前提を固める。

**チェックリスト（コピペ用）**

1. **揃える軸**: サイズ（bpp やバイト ±%）/ SSIM 等 / まずはサイズのみ、など。
2. **入力**: リサイズ済み固定ピクセル（encode のみ切り出し）か、現行の decode+resize+encode パイプライン全体か。
3. **基準**: Sharp を基準に zigpix を合わせるか、その逆か。
4. **閾値**: 例「出力サイズ ±8〜10%（慣れたら ±3〜5%）」「SSIM を足すなら下限 0.95 前後から」など、最初は粗め。
5. **実行場所**: 探索は手元または夜間ジョブ / CI は固定パラメータ＋短い計測＋閾値ゲートのみ、など。
6. **成果物**: スパイク段階は **JSON を正本**にし、表が固まったら Markdown を生成または README に概要だけ、など。

**ベストプラクティス（推奨の初期デフォルト）**

- **第 1 段階は「出力バイト数（または bpp）だけ揃える」**。SSIM 等は第 2 段階（指標の定義・閾値の議論が増えるため）。
- **スパイクは encode 単体**（同一 `ImageBuffer` に対し zigpix / Sharp で AVIF 化）に寄せ、**現行 `bench/bench.ts` のパイプライン計測とは別メトリクス**として扱う。
- **外向き説明では Sharp を基準**に「同じ出力サイズ帯へ zigpix のパラメータを合わせた」と書ける形が取りやすい。
- **CI**: パラメータ二分探索は載せず、**手元または週次**で探索結果を JSON にコミットし、CI では **その固定パラメータで回帰のみ**、が現実的。
- **再現性**: 成果物 JSON に Node・Sharp・runner OS・反復回数・warm-up を必ず含める。**異なる runner 間で数値を直接比較しない**（同一または近似環境での差分のみ）。
- **PR 用と夜間フル探索用**を分けると、コストとブレの両方を抑えやすい。

### メモリ（ピーク RSS）

1 プロセスあたりの **最大常駐物理メモリ**は、GNU `time -v` の *Maximum resident set size (kbytes)* で取得する。

```bash
zig build lib
npm run build          # bench を計測する場合のみ必須（js/dist/index.js）
# npm install sharp    # bench 行の RSS を取る場合
bash scripts/mem-peak.sh
```

- **Linux**: 通常 `/usr/bin/time -v` が使える（パッケージ名は `time` 等、ディストリ依存）。
- **macOS**: 標準の `/usr/bin/time` は `-v` 非対応。`brew install gnu-time` で `gtime` を入れてから再実行。

| シナリオ | Max RSS (kB) | 備考 |
|----------|---------------:|------|
| FFI `bun run test/ffi/test.ts` | **43536** | Linux x86_64 VPS 実測（`zig build lib` 済み・Bun・`scripts/mem-peak.sh`）。8 件の FFI 結合テスト 1 プロセスのピーク（Bun + koffi + libpict を含む）。同一条件でも数千 kB 程度ブレ得 |
| `npx tsx bench/bench.ts` | **135356** | Linux x86_64 VPS 実測（`npm run build` 済み・`sharp` 同梱）。**旧** `bench/bench.ts`（512×512→256×256 の単一シナリオ）当時の 1 実行ピーク。現行スクリプトは **FHD / WQHD / 4K 相当の 3 シナリオ**のため、ピーク RSS は `scripts/mem-peak.sh` での **再計測を推奨**（Node/tsx + 両ネイティブ） |

上表の FFI 値は **本番アプリのプロセスと同一ではない**（計測対象はテストスイートのみ）。傾向把握・リグレッション比較用。

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
