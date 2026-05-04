# CLAUDE.md

## プロジェクト概要

zenpix — Zig 製の高速画像処理ライブラリ。JPEG/PNG/WebP/AVIF/GIF decode、Lanczos-3 リサイズ、WebP/AVIF/PNG encode、CLI。Node.js / Bun / Deno 対応（koffi FFI）。

---

## 現在の状況（2026-05-04 時点）

**最新バージョン: 0.7.0**（npm publish 済み、GitHub Release 済み）

### 直近でリリースした内容

| バージョン | 主な変更 |
|---|---|
| 0.5.0 | `encodeAvif()` に `threads` オプション追加 |
| 0.6.0 | AVIF/GIF decode、`resize()` fit モード、`convert()` パイプライン |
| 0.7.0 | CLI 追加（`npx zenpix`）— stdin/stdout、バッチ、リサイズ |

### 次にやること（優先順）

1. **ブログ・X（旧 Twitter）投稿内容を考える** — 0.6.0〜0.7.0 の機能紹介。まだ着手していない
2. **tsukasa-art の zenpix を 0.7.0 に更新** — 現在 `^0.6.0`。CLI は関係ないが揃えておく
3. **Phase 12-B/C**（WebP encode 強化、`<picture>` AVIF+WebP）— 要件が固まったら
4. **CLI の Python パッケージ化**（`pip install zenpix-cli`）— 将来候補

### ワークフロー上の注意

- **CI がグリーンなブランチは PR を作らず直接 main にマージする**（不要なオーバーヘッドのため）
- リリース時は `docs/release.md` の手順に従う

---

## 関連プロジェクト

### tsukasa-art（`/Users/tuki/develop/projects/tsukasa-art`）

作者の個人 HP（Astro + Bun + PostgreSQL + Podman）。zenpix を画像変換に使用。

- **現在の zenpix バージョン**: `^0.6.0`（次のセッションで 0.7.0 に上げる）
- 変更ファイル: `src/lib/utils/imageConvert.ts`、`src/pages/api/admin/upload.ts`、`upload-r18.ts`
- AVIF アップロード対応済み（`image/avif` を `ALLOWED_MIME` に追加）
- Bun 運用、デプロイは VPS 上の `./deploy.sh`

---

## 主要コマンド

```bash
npm run build          # tsc + esbuild (index.deno.js, cli.js + shebang)
npm run test:bun       # bash test/ffi/run.sh
npm run test:node      # bash test/ffi/run.node.sh
npm run bench          # bench/bench.ts (decode→resize→AVIF vs Sharp)
npm run bench:threads  # bench/bench-threads.ts (AVIF_THREADS=N で計測)
npm run bench:quality  # bench/bench-quality.ts (品質揃えの比較)
```

---

## リリース手順

詳細は `docs/release.md`。要点：

1. `main` に push → CI（build-native.yml）グリーン確認
2. `gh run list --workflow=build-native.yml --branch main --limit 3` で RUN_ID 取得
3. artifacts ダウンロード → `npm/zenpix-*/` にコピー（`docs/release.md` §1.1 参照）
4. `npm publish --access public`（optional 4 件 → ルート の順）
5. `git tag -a "vX.Y.Z"` → `git push origin "vX.Y.Z"`
6. CHANGELOG から GitHub Release 生成

バージョン更新時は `package.json`・`npm/*/package.json`・`optionalDependencies`・`CHANGELOG.md` を同時に更新する。

---

## パッケージ構成

```
zenpix                      # ルート（JS + CLI、bin: js/dist/cli.js）
  ├── zenpix-darwin-arm64   # optional: libpict.dylib (Apple Silicon)
  ├── zenpix-darwin-x64     # optional: libpict.dylib (Intel Mac)
  ├── zenpix-linux-x64      # optional: libpict.so
  └── zenpix-win32-x64      # optional: libpict.dll
```

---

## アーキテクチャ

```
Zig (src/) → libpict.{dylib,so,dll}
               ↓ koffi FFI
js/src/index.ts      → js/dist/index.js       (Node / Bun)
js/src/index.deno.ts → js/dist/index.deno.js  (Deno、esbuild でビルド)
js/src/cli.ts        → js/dist/cli.js         (CLI、bin エントリ)
```

- **decode**: JPEG（libjpeg-turbo）/ PNG（libpng）/ WebP（libwebp）/ AVIF（libavif+libaom）/ GIF（stb_image.h、先頭フレームのみ）
- **resize**: Lanczos-3、SIMD（NEON/SSE2）、V-pass マルチスレッド、fit: stretch/contain/cover
- **encode**: WebP（libwebp）/ AVIF（libavif+libaom、threads オプション）/ PNG（libpng）
- **convert()**: decode → crop → resize → encode パイプライン

---

## CLI（0.7.0 で追加）

```bash
zenpix input.jpg                          # → input.avif（デフォルト AVIF）
zenpix input.jpg out.webp -q 92          # WebP
zenpix input.jpg --max-size 1920         # リサイズ + AVIF
zenpix *.jpg --out-dir ./avif/           # バッチ
cat img.jpg | zenpix - out.avif          # stdin
zenpix img.jpg -                         # stdout（パイプ）
zenpix img.jpg out.avif --threads 8     # マルチスレッド AVIF
```

Python から: `subprocess.run(["npx", "zenpix", "input.jpg", "output.avif"])`

---

## 重要な制約

- **ESM 専用**（`"type": "module"`）。CommonJS 非対応
- `js/src/index.deno.ts` は tsconfig の exclude 対象（esbuild でビルド）
- `js/src/cli.ts` は tsc でビルド後、`scripts/add-shebang.mjs` で shebang を付与
- `bench/results/` や `zig-out/` はコミット対象外（.gitignore）
- VPS バイナリは glibc 前提。Alpine（musl）は非対応
- ライブラリバージョンは `docs/deps.md` で管理
