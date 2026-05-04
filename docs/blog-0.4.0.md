# Zig 製画像処理ライブラリ「zenpix」を npm に公開しました

## はじめに

Node.js・Bun・Deno から使える画像処理ライブラリ **zenpix** の v0.4.0 をリリースしました。

Zig で書いた画像処理コアに libjpeg-turbo / libpng / libwebp / libavif（libaom）を静的リンクし、FFI 経由で JavaScript から呼び出す構成です。`npm install zenpix` だけで依存ライブラリの追加インストールなしに動きます。

## なぜ Zig か

候補は Rust・C もありましたが、Zig を選んだ理由は主に 3 つです。

**1. クロスコンパイルが標準装備**
`zig build lib-windows -Davif=static` でローカルの macOS から Windows 向け DLL が生成できます。CI も mac / linux / windows 向けをすべて別ランナーでビルドしています。

**2. C ライブラリとの親和性が高い**
`@cImport` で C ヘッダを直接取り込め、libjpeg-turbo などの既存 C ライブラリをほぼ素のまま組み込めます。既存の C エコシステムの資産をそのまま使えるのは大きなメリットでした。

**3. 静的リンクが簡単**
zlib・libpng・libjpeg-turbo・libwebp・libavif を `addCSourceFiles` でまとめてビルドし、外部共有ライブラリを一切持ち込まないバイナリにできます。ユーザーは `npm install` だけで完結します。

## インストール

**Node.js / Bun**

```bash
npm install zenpix
```

ESM 専用パッケージです。`package.json` に `"type": "module"` が必要です。

**Deno**

```bash
deno add npm:zenpix
```

または import 時に直接:

```typescript
import { decode, resize, encodeWebP, encodeAvif, encodePng, crop } from "npm:zenpix/deno";
```

`--allow-ffi` フラグが必要です。

## API

v0.4.0 時点の API は 6 関数です。

```typescript
import { decode, resize, encodeWebP, encodeAvif, encodePng, crop } from "zenpix";
import { readFileSync, writeFileSync } from "fs";

// JPEG / PNG / 静止画 WebP をデコード（EXIF Orientation 自動適用）
const image = decode(readFileSync("photo.jpg"));

// Lanczos-3 リサイズ（幅指定、高さはアスペクト比維持）
const resized = resize(image, { width: 1920 });

// WebP エンコード
const webp = encodeWebP(resized, { quality: 92 });
writeFileSync("output.webp", webp);

// AVIF エンコード（libavif / libaom は静的リンク済み）
const avif = encodeAvif(resized, { quality: 60, speed: 10 });
if (avif) writeFileSync("output.avif", avif);

// PNG エンコード（ICC プロファイルがあれば iCCP チャンクとして埋め込み）
const png = encodePng(resized, { compression: 6 });
writeFileSync("output.png", png);

// crop（サムネイル用矩形切り出し）
const thumb = crop(resized, { left: 0, top: 0, width: 400, height: 300 });
writeFileSync("thumb.webp", encodeWebP(thumb, { quality: 85 }));
```

### ImageBuffer

```typescript
interface ImageBuffer {
  data: Buffer;      // 生ピクセル（row-major, top-left origin）
  width: number;
  height: number;
  channels: number;  // 3 = RGB, 4 = RGBA
  icc?: Buffer;      // 埋め込み ICC（ない画像では省略）
}
```

ICC プロファイルは `decode()` が取り出し、`resize()` が引き継ぎ、`encodeWebP()` / `encodePng()` がそれぞれ ICCP チャンクとして埋め込みます。

## v0.4.0 のハイライト: EXIF Orientation 自動回転

今回のリリースで個人的に一番「あってよかった」と感じている機能です。

スマートフォンで撮影した JPEG は、画像データ自体は横向きのまま保存されており、EXIF の Orientation タグ（1〜8）で「どう表示するか」を指定する仕様になっています。ビューアはこのタグを読んで自動回転しますが、自前でデコードするとタグを無視した生データが出てくるため、写真が横倒しや逆さまになるという問題が起きます。

v0.4.0 の `decode()` は JPEG バイト列を受け取った時点で Orientation タグを自動読み取りし、ピクセルデータ・width・height を正位置に合わせて返します。

```typescript
const image = decode(readFileSync("portrait_shot.jpg"));
// Orientation=6（90°CW 撮影）の場合:
//   元データは 403×302 だが、image.width=302, image.height=403 で返ってくる
```

Orientation 2〜8（水平反転・180°回転・垂直反転・転置・90°CW・逆転置・90°CCW）をすべてカバーしています。

**実装の話**

C で書いた `pict_jpeg_orientation()` が JPEG バイト列から APP1 セグメントを走査して IFD0 の Orientation タグ（0x0112）を取得し、Zig の `pict_rotate()` がピクセルバッファをアロケートして実際の回転・反転を適用します。

一つハマりポイントがあって、Windows DLL では Zig の `export fn` を持たない C 関数のシンボルが自動公開されません（Linux/macOS の ELF/Mach-O とは異なる仕様）。`pict_jpeg_orientation` は Zig ラッパーなしの純 C 関数だったため、`#ifdef _WIN32 __declspec(dllexport)` の追加が必要でした。CI（Windows x64）を回すまで気づかなかった落とし穴でした。

## ベンチマーク

パイプライン: PNG デコード → Lanczos-3 リサイズ → AVIF エンコード（quality=60, speed=6）  
計測: warm-up 2 回・計測 10 回の wall-clock 中央値。ratio = Sharp 中央値 ÷ zenpix 中央値（1 超なら zenpix が速い）

### VPS（Ubuntu、vCPU 2、RAM 2 GB）

zenpix **0.4.0** バイナリで 3 回計測、各セルの中央値。

| フィクスチャ | FHD ratio | WQHD ratio | 4K ratio |
|---|---:|---:|---:|
| 厚塗り風景 | 1.47 | 1.37 | 1.44 |
| キャラ A | 1.35 | 1.26 | 1.21 |
| キャラ B | 1.36 | 1.27 | 1.21 |
| 風景（暗め） | 1.13 | 1.20 | 0.97 |
| 汎用 PNG | 0.26 | 0.25 | 0.24 |

少コア VPS ではキャラ・厚塗り系で zenpix が有利になりやすいです。汎用 PNG（パターン画像）では Sharp が速い結果でした。

### Mac（M4 Pro 14 コア）では Sharp が全シナリオで速い

マルチコアを活かせる高スペック環境では Sharp の並列処理が有利です。同じスクリプトで計測した全フィクスチャで ratio は 1 未満でした。

### 一点比較: 3840×2160 PNG → 1920×1080 AVIF（macOS arm64）

| | wall-clock 中央値 | CPU user |
|---|---:|---:|
| **zenpix speed=10** | **0.710s** | 0.66s |
| Sharp quality=60 | 1.141s | 9.27s |

zenpix はシングルスレッドで動くため CPU user 時間が非常に少なく、他リクエストと CPU を奪い合う場面でのスループット面が有利になりやすいです。

**要約**: 「あらゆる場面で Sharp より速い」ではありません。少コア VPS・AVIF エンコード用途では zenpix が wall-clock で有利になりやすく、マルチコアでスループット最優先なら Sharp を選ぶ棲み分けが現実的です。

## 対応プラットフォーム

| ランタイム | macOS arm64 | macOS x64 | Linux x64 | Windows x64 |
|---|:---:|:---:|:---:|:---:|
| Node.js 18+ | ✅ | ✅ | ✅ | ✅ |
| Bun | ✅ | ✅ | ✅ | ✅ |
| Deno 2.x | ✅ | ✅ | ✅ | ✅ |

npm パッケージは `zenpix`（メタパッケージ）+ プラットフォーム別 optional 4 件（`zenpix-darwin-arm64` / `zenpix-darwin-x64` / `zenpix-linux-x64` / `zenpix-win32-x64`）の構成です。`npm install zenpix` で自動的に適切な optional が選択されます。

ブラウザ向けには AVIF エンコード専用の **[zenpix-wasm](https://www.npmjs.com/package/zenpix-wasm)** も別パッケージで公開しています（Cloudflare Pages 動作確認済み）。

## まとめ

- **`npm install zenpix`** で Node.js / Bun / Deno すべてで即使える
- JPEG / PNG / WebP デコード → Lanczos-3 リサイズ → WebP / AVIF / PNG エンコード → crop の一通りが v0.4.0 で揃った
- **EXIF Orientation 自動回転**で「スマホ写真が横倒し」問題を根本から解消
- 少コア VPS やシングルスレッドが中心の用途では Sharp より有利になりやすい

---

- GitHub: https://github.com/Tuki-Sana/zenpix
- npm (ネイティブ): https://www.npmjs.com/package/zenpix
- npm (WASM): https://www.npmjs.com/package/zenpix-wasm
