# Changelog

このファイルは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) の体裁に近づけ、`zigpix` / 同梱 optional / `zigpix-wasm` の**利用者向けの差分**を記録する。  
0.1.3 以前の細目は Git タグと `docs/CHECKLIST.md`（npm リリース節）を参照。

## [0.1.4] - 2026-04-14

### 追加

- **埋め込み ICC**: `decode()` が `pict_decode_v3` 経由で、JPEG / PNG / WebP 等の埋め込み ICC を `ImageBuffer.icc`（任意）として返す。
- **WebP への ICC 埋め込み**: `encodeWebP()` が `pict_encode_webp_v2` 相当で ICCP チャンクを付与できる。
- **FFI**: `export fn pict_encode_webp_v2`（`icc` / `icc_len`。`icc_len == 0` で ICC なし）。既存 `pict_encode_webp` は後方互換のまま。

### 変更

- **`resize()`**: 入力に `icc` がある場合は出力にも引き継ぎ、その後の `encodeWebP` で WebP に載せられる。

### ドキュメント

- **README**: `ZIGPIX_LIB`、FFI 検証には `zig build lib` が必要であること、`zig build wasm` と `zigpix-wasm` の役割差を追記。
- **build.zig**: WASI ターゲットがネイティブの C デコード・ICC・WebP フルパスと揃わない旨をコメントで明示。

### 利用者向けメモ

- **ローカル検証**: `npx tsx test/ffi/test.node.ts` / `bun test/ffi/test.ts` の前に **`zig build lib`**（共有ライブラリ更新）。
- **任意の `libpict` を指す**: 環境変数 **`ZIGPIX_LIB`** に `libpict.dylib` / `libpict.so` のフルパス（解決順は `js/src/index.ts` 参照）。

### 互換性

- **`pict_encode_webp`**: シンボル維持。ICC 不要な呼び出しは従来どおり。
- **HEIC / アニメ WebP**: 非対応のまま。

### zigpix-wasm（`npm install zigpix-wasm@0.1.4`）

- ブラウザ向け **AVIF エンコード専用**パッケージ。本リリースでは **バージョン番号を `zigpix` 0.1.4 に合わせた配布**（API・WASM バイナリの機能変更なし）。詳細は **`wasm/CHANGELOG.md`**。

---

## [0.1.3] 以前

概要は `docs/CHECKLIST.md` の「0.1.3 パッチ」「0.1.2 修正」などを参照。以降のリリースでは本ファイルの **Unreleased** か該当バージョン見出しを publish 前に更新する。
