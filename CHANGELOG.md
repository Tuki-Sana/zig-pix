# Changelog

このファイルは [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) の体裁に近づけ、`zenpix` / 同梱 optional / `zenpix-wasm` の**利用者向けの差分**を記録する。  
0.1.3 以前の細目は Git タグと `docs/CHECKLIST.md`（npm リリース節）を参照。

## [Unreleased]

（次パッチ以降の差分をここに書く）

## [0.4.0] - 2026-05-04

### 追加

- **`encodePng(img, options?)`**: PNG エンコード（`compression` 0–9、デフォルト 6）。`pict_encode_png` FFI 経由。ICC プロファイルがある場合は `iCCP` チャンクとして埋め込む。
- **`crop(img, rect)`**: ピクセルコピーによるクロップ（`left` / `top` / `width` / `height`）。チャンネル数・ICC を引き継ぐ。`pict_crop` FFI 経由。
- **EXIF auto-rotation**: `decode()` が JPEG の EXIF Orientation（1〜8）を自動適用。`pict_jpeg_orientation` でバイト列から orientation を取得し、`pict_rotate` で回転・反転してから返す（orientation=1 は追加処理なし）。

### 変更

- **OOM エラー**: `pict_rotate` が null を返した場合（メモリ不足）、ピクセルバッファおよび ICC バッファを解放してから `"zenpix: EXIF rotation failed (out of memory)"` をスロー（旧来は誤った向きのまま返していた）。

## [0.3.0] - 2026-05-01

### 変更

- **パッケージリネーム**: `zigpix` → `zenpix`（npm・GitHub リポジトリ名ともに変更）。旧 `zigpix` 系パッケージは deprecated 済み。`npm install zenpix` で移行してください。
- **ロゴ・バナー追加**: 円相×ピクセルモチーフのロゴ（`assets/zenpix-logo.jpg`）と 16:9 バナー（`assets/zenpix-banner.jpg`）を追加。バナー生成スクリプト（`scripts/gen-banner.mjs`）は zenpix 自身で Lanczos-3 リサイズを行う。
- **ネイティブバイナリ**: 0.2.4 と同一内容（再ビルド不要）。

## [0.2.4] - 2026-04-18

### 変更

- **npm 実行時依存**: **`sharp` を `dependencies` から削除**し、**`devDependencies` のみ**に置いた。比較ベンチ（`bench/bench.ts` / `bench/bench-quality.ts`）と開発者の `npm install` では引き続き sharp が入るが、**本番相当の `npm install --omit=dev` では sharp / libvips が入らない**。利用者のインストールが軽くなる。
- **メタ＋ optional のバージョン**を **0.2.4** に揃えた。**ネイティブバイナリの中身は 0.2.3 と同一**でよい（`docs/release.md` の手順で optional を publish する際は **0.2.3 と同じ build-native の緑 RUN_ID** の artifact を流用してよい）。

## [0.2.3] - 2026-04-17

### 変更

- **リリース整合**: **Git タグ `v0.2.3`**・**npm**・**リポジトリ内ドキュメント**を同一内容に揃えるためのパッチ。**ネイティブバイナリ（dylib / so / dll）の中身は 0.2.2 と同一**でよい（再ビルド不要。`docs/release.md` の手順で optional を publish する際は **0.2.2 と同じ build-native の緑 RUN_ID** の artifact を流用してよい）。

## [0.2.2] - 2026-04-17

### 追加

- **macOS Intel（x64）**: optional **`zenpix-darwin-x64`**（`libpict.dylib`）。CI（`build-native.yml` の **`build-darwin-x64`**、`macos-15-intel`）で CMake 静的 libavif → **`zig build lib -Davif=static`** と FFI / E2E。

## [0.2.1] - 2026-04-17

### 変更

- **Windows on ARM64**: **`zenpix-win32-arm64` npm 同梱と `build-windows-arm64`（`windows-11-arm`）CI を見送り**。ルート `optionalDependencies` は **darwin / linux / win32-x64 の 3 件**のみ。WoA では **`ZENPIX_LIB`**・**x64 Node**・または **`zig build lib-windows-arm64`** による自己ビルドを案内（`docs/windows-rollout-plan.md` §3.3）。
- **README**: npm ページ向けに **WoA（公式同梱なし）**の注記を追記。**ルート・各 optional のバージョンを 0.2.1 に揃えた**（ネイティブ DLL の中身は 0.2.0 と同一の CI 成果物でよい）。

## [0.2.0] - 2026-04-16

### 追加

- **Windows x64（ネイティブ）**: `zenpix-win32-x64` optional 同梱の **`libpict.dll`**（MSVC 静的 libavif / libaom、`zig build lib-windows -Davif=static`）。CI（`build-native.yml` の `build-windows-x64`）で Bun / Node / Deno の FFI・E2Eおよび **`llvm-readobj` / `llvm-objdump` による exports・依存 DLL ゲート**。
- **ローダー**: `js/src/index.ts` / `index.deno.ts` で `win32` + `x64` を解決（`ZENPIX_LIB` → `zig-out/windows-x86_64/libpict.dll` → optional）。

### 変更

- **ルート `zenpix` と既存 optional**（`zenpix-darwin-arm64` / `zenpix-linux-x64`）の **バージョンを 0.2.0 に揃えた**（ネイティブバイナリは各 CI artifact で置き換えてから publish すること）。

### 互換性・環境

- **Windows 10 以降 x64** をネイティブ対象とする（Node engines `>=18` と整合）。**WSL2** 上では引き続き Linux 用 `.so` が使われる。
- **Windows on ARM64**: npm 公式同梱は **対象外**（`zenpix-win32-arm64` は出さない。`docs/windows-rollout-plan.md` §3.3）。**0.2.0** 時点では x64 のみ npm で配布。
- **Visual C++ 再頒布可能パッケージ (x64)** が無い環境では DLL ロードに失敗することがある（ビルドは `/MD` + ランタイム依存）。不足時は Microsoft 提供の **VC++ Redistributable x64** を入れる。
- **SmartScreen / Defender**: 未署名の `libpict.dll` を初回取得する際に警告が出る場合がある。

### zenpix-wasm

- 本リリースでは **必須ではない**（ネイティブのみ上げる場合は `wasm/` を触らずに Phase 2 をスキップ）。`zenpix-wasm` のバージョンを合わせる場合は **`wasm/package.json`** と **`wasm/CHANGELOG.md`** を別途更新してから publish。

## [0.1.5] - 2026-04-15

### ドキュメント

- **README**: `bench/bench.ts` の **VPS / Mac 実測**（同一条件・各 3 回のセル中央値）、機材・runner の注記、環境別の棲み分け（目安）、`npm run bench:aggregate` の案内。
- **README**: 「比較の読み方」の **少コア VPS** を「上の **VPS 実測**の表」と明記（Mac 実測と対称）。
- **`package.json` の `description`**: ベンチで示す環境差と整合（Sharp との速度は **パイプライン・マシン依存**、詳細は README）。
- **開発者向け**: `scripts/bench-aggregate-multi-run.mjs`（複数 run の `benchmark.json` を集計し Markdown 断片を標準出力へ）。

### 利用者向けメモ

- **API・ネイティブバイナリの機能変更なし**（本リリースはドキュメントとベンチ周辺の整備）。

### zenpix-wasm（`npm install zenpix-wasm@0.1.5`）

- ブラウザ向け **AVIF エンコード専用**パッケージ。本リリースでは **バージョン番号を `zenpix` 0.1.5 に合わせた配布**（API・WASM バイナリの機能変更なし）。詳細は **`wasm/CHANGELOG.md`**。

---

## [0.1.4] - 2026-04-14

### 追加

- **埋め込み ICC**: `decode()` が `pict_decode_v3` 経由で、JPEG / PNG / WebP 等の埋め込み ICC を `ImageBuffer.icc`（任意）として返す。
- **WebP への ICC 埋め込み**: `encodeWebP()` が `pict_encode_webp_v2` 相当で ICCP チャンクを付与できる。
- **FFI**: `export fn pict_encode_webp_v2`（`icc` / `icc_len`。`icc_len == 0` で ICC なし）。既存 `pict_encode_webp` は後方互換のまま。

### 変更

- **`resize()`**: 入力に `icc` がある場合は出力にも引き継ぎ、その後の `encodeWebP` で WebP に載せられる。

### ドキュメント

- **README**: `ZENPIX_LIB`、FFI 検証には `zig build lib` が必要であること、`zig build wasm` と `zenpix-wasm` の役割差を追記。
- **build.zig**: WASI ターゲットがネイティブの C デコード・ICC・WebP フルパスと揃わない旨をコメントで明示。
- **`docs/release.md`**: `main` push 後から npm 公開までのチェックリスト。`export RUN_ID` と `gh run download` は同一シェルで実行する旨を追記。
- **`docs/README.md`**: 各ドキュメントの役割・読む順。任意のメモ用に `docs/LOCAL.md` を `.gitignore`。
- **`docs/operations.md`**: §8 / §9 を概要と `release.md` 参照に整理。

### 利用者向けメモ

- **ローカル検証**: `npx tsx test/ffi/test.node.ts` / `bun test/ffi/test.ts` の前に **`zig build lib`**（共有ライブラリ更新）。
- **任意の `libpict` を指す**: 環境変数 **`ZENPIX_LIB`** に `libpict.dylib` / `libpict.so` のフルパス（解決順は `js/src/index.ts` 参照）。

### 互換性

- **`pict_encode_webp`**: シンボル維持。ICC 不要な呼び出しは従来どおり。
- **HEIC / アニメ WebP**: 非対応のまま。

### zenpix-wasm（`npm install zenpix-wasm@0.1.4`）

- ブラウザ向け **AVIF エンコード専用**パッケージ。本リリースでは **バージョン番号を `zenpix` 0.1.4 に合わせた配布**（API・WASM バイナリの機能変更なし）。詳細は **`wasm/CHANGELOG.md`**。

---

## [0.1.3] 以前

概要は `docs/CHECKLIST.md` の「0.1.3 パッチ」「0.1.2 修正」などを参照。以降のリリースでは本ファイルの **Unreleased** か該当バージョン見出しを publish 前に更新する。
