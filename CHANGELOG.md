# Changelog

このファイルは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) の体裁に近づけ、`zigpix` / 同梱 optional / `zigpix-wasm` の**利用者向けの差分**を記録する。  
0.1.3 以前の細目は Git タグと `docs/CHECKLIST.md`（npm リリース節）を参照。

## [Unreleased]

（次パッチ以降の差分をここに書く）

## [0.1.5] - 2026-04-15

### ドキュメント

- **README**: `bench/bench.ts` の **VPS / Mac 実測**（同一条件・各 3 回のセル中央値）、機材・runner の注記、環境別の棲み分け（目安）、`npm run bench:aggregate` の案内。
- **開発者向け**: `scripts/bench-aggregate-multi-run.mjs`（複数 run の `benchmark.json` を集計し Markdown 断片を標準出力へ）。

### 利用者向けメモ

- **API・ネイティブバイナリの機能変更なし**（本リリースはドキュメントとベンチ周辺の整備）。

### zigpix-wasm（`npm install zigpix-wasm@0.1.5`）

- ブラウザ向け **AVIF エンコード専用**パッケージ。本リリースでは **バージョン番号を `zigpix` 0.1.5 に合わせた配布**（API・WASM バイナリの機能変更なし）。詳細は **`wasm/CHANGELOG.md`**。

---

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
- **`docs/release.md`**: `main` push 後から npm 公開までのチェックリスト。`export RUN_ID` と `gh run download` は同一シェルで実行する旨を追記。
- **`docs/README.md`**: 各ドキュメントの役割・読む順。任意のメモ用に `docs/LOCAL.md` を `.gitignore`。
- **`docs/operations.md`**: §8 / §9 を概要と `release.md` 参照に整理。

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
