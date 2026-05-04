# CLAUDE.md

## プロジェクト概要

zenpix — Zig 製の高速画像処理ライブラリ。JPEG/PNG/WebP/AVIF/GIF decode、Lanczos-3 リサイズ、WebP/AVIF/PNG encode、CLI。Node.js / Bun / Deno 対応（koffi FFI）。

**現在のバージョン**: 0.7.0（npm publish 済み）

## 主要コマンド

```bash
npm run build          # tsc + esbuild (index.deno.js, cli.js + shebang)
npm run test:bun       # bash test/ffi/run.sh
npm run test:node      # bash test/ffi/run.node.sh
npm run bench          # bench/bench.ts (decode→resize→AVIF vs Sharp)
npm run bench:threads  # bench/bench-threads.ts (AVIF_THREADS=N で計測)
npm run bench:quality  # bench/bench-quality.ts (品質揃えの比較)
```

## リリース手順

詳細は `docs/release.md`。要点：

1. `main` に push → CI（build-native.yml）グリーン確認
2. `gh run list --workflow=build-native.yml --branch main --limit 3` で RUN_ID 取得
3. artifacts ダウンロード → `npm/zenpix-*/` にコピー
4. `npm publish --access public`（optional 4 件 → ルート の順）
5. `git tag -a "vX.Y.Z"` → `git push origin "vX.Y.Z"`
6. CHANGELOG から GitHub Release 生成

## パッケージ構成

```
zenpix                  # ルート（JS + CLI、bin: js/dist/cli.js）
  ├── zenpix-darwin-arm64   # optional: libpict.dylib (Apple Silicon)
  ├── zenpix-darwin-x64     # optional: libpict.dylib (Intel Mac)
  ├── zenpix-linux-x64      # optional: libpict.so
  └── zenpix-win32-x64      # optional: libpict.dll
```

バージョンは全パッケージで同一。`npm/*/package.json` / `package.json` の `optionalDependencies` を同時に更新する。

## アーキテクチャ

```
Zig (src/) → libpict.{dylib,so,dll}
               ↓ koffi FFI
js/src/index.ts → js/dist/index.js  (Node / Bun)
js/src/index.deno.ts → js/dist/index.deno.js  (Deno)
js/src/cli.ts → js/dist/cli.js  (CLI, bin エントリ)
```

- **decode**: JPEG（libjpeg-turbo）/ PNG（libpng）/ WebP（libwebp）/ AVIF（libavif+libaom）/ GIF（stb_image.h）
- **resize**: Lanczos-3、SIMD（NEON/SSE2）、V-pass マルチスレッド、fit: stretch/contain/cover
- **encode**: WebP（libwebp）/ AVIF（libavif+libaom、threads オプション）/ PNG（libpng）
- **convert()**: decode → crop → resize → encode パイプライン

## CLI

```bash
zenpix input.jpg                    # → input.avif
zenpix input.jpg out.webp -q 92    # WebP
zenpix *.jpg --out-dir ./avif/     # バッチ
cat img.jpg | zenpix - out.avif    # stdin
zenpix img.jpg -                   # stdout
```

## 重要な制約

- **ESM 専用**（`"type": "module"`）。CommonJS 非対応
- `js/src/index.deno.ts` は tsconfig の exclude 対象（esbuild でビルド）
- `js/src/cli.ts` は tsc でビルド後、`scripts/add-shebang.mjs` で shebang を付与
- `bench/results/` や `zig-out/` はコミット対象外（.gitignore）
- VPS バイナリは glibc 前提。Alpine（musl）は非対応
- ライブラリバージョンは `docs/deps.md` で管理
