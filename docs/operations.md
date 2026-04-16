# OPERATIONS: 開発運用ガイド

このドキュメントは、`pict-zig-engine` の日常運用で迷いやすい項目をまとめたものです。  
設計思想は `RFC.md`、実務手順はこのファイルを正とします。

各ドキュメントの役割一覧は **[`docs/README.md`](./README.md)**。

**`main` へ push 済みから npm 公開まで**の手順は、ミス防止のため **[`docs/release.md`](./release.md)** に一本化した（チェックリスト付き）。本ファイルの §8 は概要と開発者向けメモのみ。

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
| `zig build lib-windows` | **Windows x64 + MSVC**（または同等の SDK 環境） | ✅ | Windows 向け **`zig-out/windows-x86_64/libpict.dll`**（**事前に** `vendor/libavif` を CMake で `build/libavif-install/` へ静的ビルド） |
| `zig build lib-linux` | Mac | ❌ | Linux 向けクロスコンパイル (AVIF 無効) |
| `zig build linux` | Mac | ❌ | Linux CLI クロスコンパイル |

**重要**: Linux で AVIF FFI を使う場合は、必ず VPS 上で `zig build lib` をネイティブ実行すること。  
Mac からのクロスコンパイル (`zig build lib-linux`) では AVIF は無効のままとなる。

**Windows**: `build.zig` では **`-Davif=system` は未対応**（エラー終了）。Windows では常に **静的 libavif + AOM**（上記 CMake 手順）を前提に **`zig build lib-windows -Davif=static`** とする。手順の正本は **`docs/windows-rollout-plan.md` §3.2** と **`.github/workflows/build-native.yml` の `build-windows-x64`**。

## 7) FFI テスト手順

### Mac

```bash
bash test/ffi/run.sh   # zig build lib + bun run test/ffi/test.ts
```

期待出力: `All 8 tests passed.`（Case A〜G 相当。スイート拡張に応じて件数は変わり得る）

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
- `All 8 tests passed.` など（Case E が null ではなく ftyp 検証を通ること）

### Windows（x64・MSVC）

前提: **Visual Studio Build Tools** または VS が入り、`ilammy/msvc-dev-cmd` 相当で **x64 ネイティブ**の開発者コマンドプロンプトが使えること。Ninja / NASM を PATH に通す（CI は Chocolatey 参照）。

```bash
# 1) libavif + libaom を静的インストール（リポジトリルートから）
mkdir -p build/libavif && cd build/libavif
cmake ../../vendor/libavif -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL \
  -DCMAKE_INSTALL_PREFIX=../../build/libavif-install \
  -DAVIF_CODEC_AOM=LOCAL \
  -DAVIF_CODEC_DAV1D=OFF \
  -DAVIF_BUILD_TESTS=OFF \
  -DAVIF_BUILD_APPS=OFF \
  -DAVIF_LIBYUV=OFF \
  -DBUILD_SHARED_LIBS=OFF
ninja && ninja install
cd ../..

# 2) libpict.dll（AVIF 静的）
zig build lib-windows -Doptimize=ReleaseFast -Davif=static
```

成果物: **`zig-out/windows-x86_64/libpict.dll`**（Unix の `zig-out/lib/` とはパスが異なる）。

```bash
# FFI（Bun / Node はこの DLL を参照するよう test 側が分岐済み）
bun run test/ffi/test.ts
npx tsx test/ffi/test.node.ts
```

### lib-linux の回帰確認 (Mac 上)

```bash
zig build lib-linux

# pict_encode_avif シンボルが存在することを確認 (AVIF 無効でも ABI 互換シンボルとして存在)
zig llvm-nm -D zig-out/linux-x86_64/libpict.so | grep pict_encode_avif
```

## 8) npm パッチリリース（`zigpix` と optional 同梱バイナリ）

### 正本

**[`docs/release.md`](./release.md)** — `main` へ push 済みから **ネイティブ optional → ルート `zigpix`**、続けて **`zigpix-wasm`** までの **チェックリスト付き手順**（`RUN_ID` の取り違え防止、検証コマンド、よくあるミス）。

### ここだけ押さえる（詳細は release.md）

- ルート `package.json` の `version` と `optionalDependencies`、`npm/zigpix-*/package.json` の `version` を **同一パッチ**に揃える。
- `libpict.dylib` / `libpict.so` は **git 管理外**。publish 直前に **build-native の緑 run** から `npm/zigpix-*/` へ置く。
- **publish 順**: `zigpix-darwin-arm64` → `zigpix-linux-x64` → **`zigpix-win32-x64`**（および ARM64 追加後はその次）→ ルート **`zigpix`**（逆にすると `npm install zigpix` が失敗し得る）。

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

# Windows x64 の例（FFI / E2E を optional より zig-out に合わせるとき）
mkdir -p node_modules/zigpix-win32-x64
cp npm/zigpix-win32-x64/package.json node_modules/zigpix-win32-x64/
cp zig-out/windows-x86_64/libpict.dll node_modules/zigpix-win32-x64/libpict.dll
```

既に optional が入っている環境では、`mkdir` / `package.json` のコピーは省略して **`libpict` の `cp` だけ**でもよい。

CI の **build-native** でも `npm run build` の直後に上記と同等の overlay を実行している。

## 9) `zigpix-wasm`（ブラウザ・Cloudflare Pages 向け AVIF）

ルートの **`zigpix`**（ネイティブ FFI）とは **別パッケージ** [`zigpix-wasm`](https://www.npmjs.com/package/zigpix-wasm)。Emscripten でビルドした **ブラウザ用 AVIF エンコード**のみ（小〜中画像向け。`decode` / リサイズ / WebP は含まない）。

### リリース手順

**[`docs/release.md`](./release.md)** の **Phase 2** を参照（`build-wasm` の **別 RUN_ID**、`fetch-wasm-artifact.sh`、`wasm/dist` の存在確認、`npm publish`）。

### バージョン方針（ネイティブと独立）

- **`wasm/package.json` の `version` が `zigpix-wasm` のセマバ**であり、**`zigpix` と同期させる必要はない**。
- 見た目を揃えたいリリースでは、運用で同じ番号にしてもよい（必須ではない）。

### CI（手動のみ・`build-native` とは別ワークフロー）

ワークフロー **Build WASM**（`.github/workflows/build-wasm.yml`）を **手動実行**すると `wasm/dist` が artifact（`zigpix-wasm-dist`）として保存される。**所要時間は libaom / libavif のフルコンパイルが支配的**（目安: 数分〜数十分以上）。`build-native` には混ぜない。

### 詳細・ビルド前提

- **`wasm/README.md`**（Emscripten、`npm run build:all`、ブラウザテスト）

### Cloudflare Pages での使い方（要点）

- **静的サイト**としてブラウザで動かす想定。`import { createAvifEncoder } from 'zigpix-wasm'` のように ESM で読み、bundler が `.wasm` をアセットとして吐き出す設定に合わせる。
- **Workers 上での WASM AVIF エンコード**は CPU 時間・サイズ制約が厳しく、チェックリストどおり **非推奨**（大画像はサーバの `zigpix` ネイティブへ）。
