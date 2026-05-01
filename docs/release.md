# リリース手順（`main` へ push 済み → npm 公開まで）

**このファイルを上から順に実行すれば、ネイティブ `zenpix` と（必要なら）`zenpix-wasm` を npm に出せる**ように書いてある。  
機密（npm トークン、`.npmrc`）はコミットしない。

## 用語

| 名前 | 意味 |
|------|------|
| **build-native** | GitHub Actions「Build native binaries」（`build-native.yml`）。成果物: `libpict-darwin-arm64` / **`libpict-darwin-x64`** / `libpict-linux-x64` / **`libpict-win32-x64`** |
| **build-wasm** | GitHub Actions「Build WASM」（`build-wasm.yml`、手動）。成果物: `zenpix-wasm-dist` |
| **RUN_ID** | GitHub Actions の run の **database id**（URL `.../actions/runs/12345` の `12345`）。**native と wasm で別の run になる** |

## 事前チェック（ここを飛ばさない）

- [ ] 変更は **`main` にマージ済み**で、意図したコミットが先頭
- [ ] **Build native binaries** が **`main` で緑**（失敗 run の artifact は使わない）
- [ ] ルート `package.json` の `version` と `optionalDependencies`、および `npm/zenpix-*/package.json` の `version` が **意図どおり**（通常は **すべて同じ**番号）
- [ ] **`zenpix-wasm` も上げる**なら `wasm/package.json` の `version` と **`wasm/CHANGELOG.md`** も揃えてある
- [ ] ルート **`CHANGELOG.md`** にそのバージョンの見出しと箇条書きがある
- [ ] 手元: **`gh` が GitHub にログイン済み**（`gh auth status`）、**`npm whoami`** が通る
- [ ] 作業ディレクトリは **リポジトリルート**（以下、特に記載がなければルート）

---

## Phase 0 — コミットと `main` への push

**npm publish より先に**、バージョン・CHANGELOG・README・各 `npm/zenpix-*/package.json` を **コミットして `origin/main` に push** する。タグは **このコミット**に打つと後から追いやすい。

1. `git status` で **ベンチ成果物や `.vscode/` が混ざっていない**ことを確認（不要なら `.gitignore` 済みか、コミット対象から外す）。
2. リリースに含めるファイルだけを add する（例）:

   ```bash
   git add package.json CHANGELOG.md README.md npm/zenpix-darwin-arm64/package.json \
     npm/zenpix-darwin-x64/package.json npm/zenpix-linux-x64/package.json npm/zenpix-win32-x64/package.json
   ```

3. コミット・push:

   ```bash
   git commit -m "chore(release): zenpix 0.2.4 — メタと optional の版上げ（例）"
   git push origin main
   ```

4. **Build native binaries** が **`main` で緑**になるまで待つ（事前チェックと同じ）。

---

## Phase 1 — ネイティブ `zenpix`（optional → メタパッケージ）

**通常**: `zenpix-darwin-arm64` / **`zenpix-darwin-x64`** / `zenpix-linux-x64` / **`zenpix-win32-x64`** を **ルートより先に** publish してからルート `zenpix`。詳細は **`docs/windows-rollout-plan.md` §4 M3 / M5**。

### 1.1 `libpict` を CI 成果物で `npm/zenpix-*/` に置く

**同じ** build-native の **1 つの RUN_ID** から、**darwin arm64 / darwin x64 / linux / win32-x64** の artifact を取る（ジョブは並列だが run は共通）。

1. RUN_ID を調べる:

   ```bash
   gh run list --workflow=build-native.yml --branch main --limit 5
   ```

   先頭の **緑**の run の `ID` 列をコピーする。

2. 置き換えてダウンロード（`RUN_ID` を実値に）:

   ```bash
   export RUN_ID=実際の数字

   # 前回の展開先が残っていると、zip 展開で `file exists` になり失敗することがある
   rm -rf /tmp/libpict-darwin-arm64 /tmp/libpict-darwin-x64 /tmp/libpict-linux-x64 /tmp/libpict-win32-x64

   gh run download "$RUN_ID" -n libpict-darwin-arm64 -D /tmp/libpict-darwin-arm64
   gh run download "$RUN_ID" -n libpict-darwin-x64 -D /tmp/libpict-darwin-x64
   gh run download "$RUN_ID" -n libpict-linux-x64 -D /tmp/libpict-linux-x64
   gh run download "$RUN_ID" -n libpict-win32-x64 -D /tmp/libpict-win32-x64
   ```

   **`export` について（勉強メモ）**: `export RUN_ID=…` でセットした変数は **そのターミナル（シェル）のセッション内だけ**有効。`gh run download` は **`export` と同じウィンドウで、その直後**に実行する（別タブ／別シェルだと `RUN_ID` が空になり失敗しやすい）。別セッションなら `export` をやり直すか、`gh run download 12345678901 ...` のように **ID をコマンドに直接書いてもよい**。

3. **確認**（ファイルが存在すること）:

   ```bash
   ls -la /tmp/libpict-darwin-arm64/libpict.dylib
   ls -la /tmp/libpict-darwin-x64/libpict.dylib
   ls -la /tmp/libpict-linux-x64/libpict.so
   ls -la /tmp/libpict-win32-x64/libpict.dll
   ```

4. `npm/` へコピー:

   ```bash
   cp /tmp/libpict-darwin-arm64/libpict.dylib npm/zenpix-darwin-arm64/
   cp /tmp/libpict-darwin-x64/libpict.dylib npm/zenpix-darwin-x64/
   cp /tmp/libpict-linux-x64/libpict.so npm/zenpix-linux-x64/
   cp /tmp/libpict-win32-x64/libpict.dll npm/zenpix-win32-x64/
   cp LICENSE THIRD_PARTY_LICENSES npm/zenpix-darwin-arm64/
   cp LICENSE THIRD_PARTY_LICENSES npm/zenpix-darwin-x64/
   cp LICENSE THIRD_PARTY_LICENSES npm/zenpix-linux-x64/
   cp LICENSE THIRD_PARTY_LICENSES npm/zenpix-win32-x64/
   ```

5. **再確認**:

   ```bash
   ls -la npm/zenpix-darwin-arm64/libpict.dylib npm/zenpix-darwin-x64/libpict.dylib npm/zenpix-linux-x64/libpict.so npm/zenpix-win32-x64/libpict.dll
   ```

**GitHub の UI だけ使う場合**: 該当 run の **Artifacts** から `libpict-darwin-arm64` / **`libpict-darwin-x64`** / `libpict-linux-x64` / **`libpict-win32-x64`** の zip を落とし、展開して同様に `npm/zenpix-*/` へ **dylib / so / dll** と **LICENSE / THIRD_PARTY_LICENSES** を置く。

### 1.2 publish 順（**この順序を守る**）

optional が先にレジストリに無いと、ルート `zenpix` だけ先に上げたユーザーが `npm install` で失敗する。

```bash
cd npm/zenpix-darwin-arm64 && npm publish --access public && cd ../..
cd npm/zenpix-darwin-x64 && npm publish --access public && cd ../..
cd npm/zenpix-linux-x64 && npm publish --access public && cd ../..
cd npm/zenpix-win32-x64 && npm publish --access public && cd ../..
npm publish --access public
```

### 1.3 公開後の確認（任意だが推奨）

```bash
npm view zenpix version
npm view zenpix-darwin-arm64 version
npm view zenpix-darwin-x64 version
npm view zenpix-linux-x64 version
npm view zenpix-win32-x64 version
```

バージョンが意図した値と一致していれば Phase 1 完了。

### 1.4 Git タグと GitHub Release（推奨）

**npm publish が成功したあと**、**そのリリースに対応する `main` のコミット**（通常は Phase 0 で push した先頭）にタグを打ち、GitHub Release を作る。順序を崩すと「タグはあるが npm に無い」「npm だけ先でタグ忘れ」になりやすい。

1. ルート `package.json` の `version` を変数に合わせる（例 `0.2.4`）:

   ```bash
   VERSION=$(node -p "require('./package.json').version")
   echo "$VERSION"
   ```

2. **アノテーションタグ**を付けて push（リモートにタグが無いことを確認してから）:

   ```bash
   git switch main && git pull origin main
   git tag -a "v${VERSION}" -m "zenpix ${VERSION}"
   git push origin "v${VERSION}"
   ```

3. **GitHub Release**（`gh` CLI。未ログインなら `gh auth login`）。**本文は `CHANGELOG.md` の該当バージョン節と揃える**（`--generate-notes` だけだとコミット要約になり、利用者向けの説明が薄くなりがち）。

   リポジトリルートで、まず `VERSION` を取る:

   ```bash
   VERSION=$(node -p "require('./package.json').version")
   ```

   **推奨（Python 3 で CHANGELOG 節を抽出）**:

   ```bash
   python3 <<'PY' > /tmp/zenpix-release-notes.md
   import json, pathlib, re
   v = json.loads(pathlib.Path("package.json").read_text(encoding="utf-8"))["version"]
   md = pathlib.Path("CHANGELOG.md").read_text(encoding="utf-8")
   parts = re.split(r"(?m)^## \[", md)
   body = None
   for p in parts[1:]:
       if p.startswith(f"{v}]"):
           body = "## [" + p
           break
   print((body or f"# zenpix {v}\n\nCHANGELOG に ## [{v}] がありません。").strip())
   PY
   gh release create "v${VERSION}" --title "zenpix ${VERSION}" --notes-file /tmp/zenpix-release-notes.md
   ```

   **手動でも可**: `CHANGELOG.md` の `## [X.Y.Z]` から次の `## [` 直前までをコピーし、`/tmp/zenpix-release-notes.md` に貼ってから上記の `gh release create … --notes-file` を実行する。

   **すでに `--generate-notes` だけで Release を作ってしまった場合**（本文を差し替えたいとき）:

   ```bash
   gh release edit "v${VERSION}" --notes-file /tmp/zenpix-release-notes.md
   ```

4. **確認**: リポジトリの **Releases** に `v${VERSION}` が表示され、本文が CHANGELOG と整合し、タグがそのコミットを指していること。

**よくある順序（スムーズな一本線）**: Phase 0（コミット・push・CI 緑）→ Phase 1.1（libpict 配置）→ 1.2（`npm publish`）→ 1.3（`npm view`）→ **1.4（タグ・Release）**。

### 1.5 `zenpix-wasm` とのバージョン（方針）

**`zenpix`（ルート + ネイティブ optional）と `zenpix-wasm` は npm 上で別パッケージ**であり、**セマンティックバージョンを揃える必要はない**。ネイティブだけ変更があるリリースでは **Phase 2 をスキップしてよい**。ブラウザ向け WASM に変更があるときだけ **`wasm/`** を更新し、Phase 2 で `zenpix-wasm` を publish する。無理に同じ番号へ揃えると、**片方だけ意味のないバンプ**が必要になりやすい。

---

## Phase 2 — `zenpix-wasm`（ブラウザ用を上げる場合のみ）

**スキップする場合**: ネイティブだけ上げる運用なら Phase 2 は行わない（§1.5）。**`zenpix` のバージョンと一致させなくてよい**。

### 2.1 `wasm/dist/` を用意する（どちらか一方）

**A. CI の artifact を使う（推奨）**

1. GitHub で **Build WASM** を手動実行し、**成功**させる。
2. **別の RUN_ID** を取得（build-native とは別）:

   ```bash
   gh run list --workflow=build-wasm.yml --branch main --limit 5
   ```

3. リポジトリルートで（**Phase 1.1 と同様**、`export` と `fetch` は **同じシェル**で続けて実行）:

   ```bash
   export RUN_ID=実際の数字
   bash scripts/fetch-wasm-artifact.sh "$RUN_ID"
   ```

4. **確認**:

   ```bash
   ls wasm/dist/avif.js wasm/dist/avif.wasm wasm/dist/avif.simd.js wasm/dist/avif.simd.wasm
   ```

**B. 手元で Emscripten ビルド**

```bash
source ~/emsdk/emsdk_env.sh   # 環境に合わせる
cd wasm && npm run build:all && npm test && cd ..
```

### 2.2 publish

```bash
cd wasm && npm test && npm publish --access public && cd ..
```

---

## よくあるミス

| ミス | 対処 |
|------|------|
| **ルートだけ先に** `npm publish` した | optional を先に同じバージョンで publish し直してからルートを再 publish（またはバージョンを繰り上げてやり直し） |
| **native と wasm で RUN_ID を取り違えた** | ワークフロー名で必ず切り分ける（`build-native.yml` vs `build-wasm.yml`） |
| **`wasm/dist` が空のまま** `npm publish` | `npm pack --dry-run` で tarball に `.wasm` が入るか確認してから publish |
| **CHANGELOG を書かずに publish** | 利用者向けに後から追記するか、次パッチで整える（理想は事前更新） |
| **`gh run download` が `file exists` で失敗** | `/tmp/libpict-*` に前回の展開が残っている。§1.1 の **`rm -rf`** を実行してから取り直す |

---

## 参考（リリース本線では不要）

- **ローカルで `zig-out` の lib を試す**（FFI / E2E）: `docs/operations.md` §8 末尾「ローカル / CI で今ビルドした lib を使う」
- **日常の Zig / libavif / submodule**: `docs/operations.md` の §1〜§7
