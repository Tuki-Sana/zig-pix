# OPERATIONS: 開発運用ガイド

このドキュメントは、`pict-zig-engine` の日常運用で迷いやすい項目をまとめたものです。  
設計思想は `RFC.md`、実務手順はこのファイルを正とします。

## 1) ツールチェーン方針

- Zig は `mise` でプロジェクト単位に固定する。
- `latest` 追従は避け、明示バージョンで pin する。
- チームで同じバージョンを使うことを最優先とする。

### 推奨手順

```bash
# プロジェクトルートで実行
mise use zig@0.13.0
zig version
which zig
```

確認基準:

- `zig version` がプロジェクトで合意した値
- `which zig` が `mise` 管理のパス

## 2) vendor 依存の管理方針

このプロジェクトでは C 依存を `git submodule` で管理する。

対象:

- `vendor/libjpeg-turbo`
- `vendor/zlib`
- `vendor/libpng`
- `vendor/libwebp`

理由:

- 依存バージョンをコミット SHA で厳密固定できる
- 更新差分とリスクを追跡しやすい
- vendor 一式を直接コミットする方式よりリポジトリ肥大化を抑えやすい

## 3) submodule 基本操作

### 初回 clone

```bash
git clone --recurse-submodules <repo-url>
```

### 既存 clone で submodule を取得

```bash
git submodule update --init --recursive
```

### submodule 更新（明示的に行う）

```bash
git submodule update --remote --recursive
git status
```

注意:

- 更新後は必ずビルド・テストを通してからコミットする
- submodule 更新コミットは、通常の機能変更コミットと分ける

## 4) 日常チェックコマンド

```bash
zig build test
zig build bench
zig build linux
zig build wasm
```

目安:

- テスト成功を Phase 完了条件の最低ラインにする
- ベンチ結果は次フェーズ最適化の比較基準として記録する

## 5) 変更時のルール（短縮版）

- まず正しさ（f32 リファレンス）を作り、最適化は後段で行う
- panic/abort より recoverable error を優先する
- API 仕様とコメントを必ず一致させる
- 境界条件（入力長、channel 数、flush 条件）のテストを先に置く

## 6) system library 依存（AVIF）

`libavif` は vendor 管理ではなく **system library** として扱う。  
`zig build lib` / `zig build` 実行環境に事前インストールが必要。

### Mac (Apple Silicon)

```bash
brew install libavif
pkg-config --cflags libavif   # 確認: -I/... が出力されること
pkg-config --libs libavif     # 確認: -L/... -lavif が出力されること
```

`addLibAvifSystem` は pkg-config 優先で、失敗時は `/opt/homebrew/include` / `/opt/homebrew/lib` に fallback する。

### Linux VPS (Ubuntu / Debian 系)

```bash
apt install libavif-dev pkg-config
pkg-config --cflags libavif   # 確認
pkg-config --libs libavif     # 確認
```

Linux では pkg-config が必須。インストールされていない場合はビルドが次のメッセージで停止する:

```
error: libavif headers not found for target linux.
Install libavif development package and pkg-config
(e.g. apt install libavif-dev pkg-config)
```

### AVIF 対応の build ターゲット別まとめ

| コマンド | 実行場所 | AVIF 有効 | 用途 |
|---------|---------|-----------|------|
| `zig build` | Mac | ✅ | CLI dev binary |
| `zig build lib` | Mac | ✅ | Mac 向け libpict.dylib |
| `zig build lib` | VPS | ✅ | Linux 向け libpict.so **← AVIF FFI はここ** |
| `zig build lib-linux` | Mac | ❌ | Linux 向けクロスコンパイル (AVIF 無効) |
| `zig build linux` | Mac | ❌ | Linux CLI クロスコンパイル |

**重要**: Linux で AVIF FFI を使う場合は、必ず VPS 上で `zig build lib` をネイティブ実行すること。  
Mac からのクロスコンパイル (`zig build lib-linux`) では AVIF は無効のままとなる。

## 7) FFI テスト手順

### Mac

```bash
bash test/ffi/run.sh   # zig build lib + bun run test/ffi/test.ts
```

期待出力: `All 6 tests passed.` (Case A〜F)

### Linux VPS

```bash
# 前提: libavif-dev インストール済み
zig build lib -Doptimize=ReleaseFast

# libavif.so が動的解決されていることを確認
ldd zig-out/lib/libpict.so | grep avif

# FFI 統合テスト
bun run test/ffi/test.ts
```

期待出力:
- `ldd` に `libavif.so.*` が表示される
- `All 6 tests passed.` (Case E が null ではなく ftyp 検証を通ること)

### lib-linux の回帰確認 (Mac 上)

```bash
zig build lib-linux

# pict_encode_avif シンボルが存在することを確認 (AVIF 無効でも ABI 互換シンボルとして存在)
zig llvm-nm -D zig-out/linux-x86_64/libpict.so | grep pict_encode_avif
```

## 8) npm パッチリリース（`zigpix` と optional 同梱バイナリ）

ルート `package.json` の `version` と `optionalDependencies`（`zigpix-darwin-arm64` / `zigpix-linux-x64`）、および `npm/zigpix-*/package.json` の `version` を **同一のパッチ番号**に揃える。

### 公開前に置くファイル

`npm/zigpix-darwin-arm64/libpict.dylib` と `npm/zigpix-linux-x64/libpict.so` は **git 管理外**（`.gitignore`）だが、`npm publish` にはワーキングツリー上に実体が必要。GitHub Actions の **build-native** ジョブ成果物（`libpict-darwin-arm64` / `libpict-linux-x64`）からコピーする。

### 公開順序

1. `npm/zigpix-darwin-arm64` で `npm publish`（Access トークン・`npm whoami` を確認）
2. `npm/zigpix-linux-x64` で同様に `npm publish`
3. リポジトリルートで `npm publish`（メタパッケージ `zigpix`。`prepublishOnly` で `js/dist` が生成される）

optional を先に上げないと、ルートだけ先に `0.1.n` を出すと `npm install zigpix` が新しい optional を解決できず失敗する。

### ローカル / CI で「今ビルドした lib」を使う

`npm install` 済みの optional パッケージは **レジストリの古いバイナリ**を指すことがある。次で上書きすると、FFI / E2E が `zig-out` のビルドと一致する。

**注意**: `package.json` の `optionalDependencies` が **まだ npm に無いバージョン**だと、optional は解決されず `node_modules/zigpix-*` が存在しない。その場合はディレクトリと `package.json` を先に置いてから `libpict` をコピーする（CI の **build-native** と同じ手順）。

```bash
# macOS Apple Silicon の例
mkdir -p node_modules/zigpix-darwin-arm64
cp npm/zigpix-darwin-arm64/package.json node_modules/zigpix-darwin-arm64/
cp zig-out/lib/libpict.dylib node_modules/zigpix-darwin-arm64/libpict.dylib

# Linux x86_64 の例
mkdir -p node_modules/zigpix-linux-x64
cp npm/zigpix-linux-x64/package.json node_modules/zigpix-linux-x64/
cp zig-out/lib/libpict.so node_modules/zigpix-linux-x64/libpict.so
```

既に optional が入っている環境では、`mkdir` / `package.json` のコピーは省略して **`libpict` の `cp` だけ**でもよい。

CI の **build-native** でも `npm run build` の直後に上記と同等の overlay を実行している。

## 9) `zigpix-wasm`（ブラウザ・Cloudflare Pages 向け AVIF）

ルートの **`zigpix`**（ネイティブ FFI）とは **別パッケージ** [`zigpix-wasm`](https://www.npmjs.com/package/zigpix-wasm)。Emscripten でビルドした **ブラウザ用 AVIF エンコード**のみ（小〜中画像向け。`decode` / リサイズ / WebP は含まない）。

### バージョン方針（ネイティブと独立）

- **`wasm/package.json` の `version` が `zigpix-wasm` のセマバ**であり、**`zigpix` と同期させる必要はない**（WASM だけ直す／ネイティブだけ直す、を別リリースにできる）。
- 見た目を揃えたいリリースでは、運用で同じ番号にしてもよい（必須ではない）。

### 公開前のビルド（手元）

`wasm/dist/` は `.gitignore` 対象のため、**publish 前に生成**する。前提: [Emscripten emsdk](https://emscripten.org/docs/getting_started/downloads.html) が有効なシェル（`wasm/README.md`）。

```bash
cd wasm
npm run build:all    # baseline + SIMD。または npm run build のみ
npm test             # Node smoke（推奨）
npm publish --access public
```

### CI（手動のみ・`build-native` とは別ワークフロー）

ワークフロー **Build WASM (zigpix-wasm)**（`.github/workflows/build-wasm.yml`）を **手動実行**（`workflow_dispatch`）すると、Ubuntu 上で Emscripten をセットアップし `wasm/dist` をビルドし、**artifact `zigpix-wasm-dist`** としてアップロードする。**所要時間は libaom / libavif のフルコンパイルが支配的**で、初回・クリーン環境では **30〜90 分程度**かかることもある。一方、ランナーやネットワーク次第では **数分〜十数分**で完了することがある（目安であり保証ではない）。

- **`build-native` には混ぜない**（ネイティブ CI の時間・失敗要因を増やさない）。
- **npm publish は自動では行わない**（`NPM_TOKEN` を載せるまで）。成果物をダウンロードして手元で `wasm/` から `npm publish` するか、将来ジョブを足す。

### npm publish（CI 成果物をコマンドで反映する手順）

1. 成功した run の **databaseId** を確認する。

   ```bash
   gh run list --workflow=build-wasm.yml --branch main --limit 5
   ```

2. リポジトリルートで artifact を `wasm/dist/` に展開する（`gh` が認証済みであること）。

   ```bash
   bash scripts/fetch-wasm-artifact.sh RUN_ID
   ```

   `scripts/fetch-wasm-artifact.sh` は `gh run download` のあと、zip 内の **`avif.js` を探索**して親ディレクトリを `wasm/dist/` の中身としてコピーする（artifact の一段ディレクトリ差を吸収する）。

3. 検証して publish する。

   ```bash
   cd wasm && npm test && npm publish --access public
   ```

### Cloudflare Pages での使い方（要点）

- **静的サイト**としてブラウザで動かす想定。`import { createAvifEncoder } from 'zigpix-wasm'` のように ESM で読み、bundler が `.wasm` をアセットとして吐き出す設定に合わせる。
- **Workers 上での WASM AVIF エンコード**は CPU 時間・サイズ制約が厳しく、チェックリストどおり **非推奨**（大画像はサーバの `zigpix` ネイティブへ）。
