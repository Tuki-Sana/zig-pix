# 実装チェックリスト

フェーズごとの進捗を管理する。完了したタスクは `[x]`、次タスクは ← でマークする。

---

## Phase 1 — Zig コア実装 ✅

- [x] Lanczos-3 f32 リファレンス実装 (`resize.zig`)
- [x] StreamingResizer (ring バッファ、低メモリ処理)
- [x] メモリ管理モジュール (`mem/ring.zig`, `mem/tile.zig`)
- [x] プラットフォーム抽象 (`platform.zig`, `platform/native.zig`, `platform/wasm.zig`)
- [x] テスト整備 (`zig build test` で全モジュールカバー)

---

## Phase 2 — C vendor 統合 ✅

- [x] libjpeg-turbo ビルド統合 (non-SIMD, 8/12/16-bit, `build.zig`)
- [x] libpng ビルド統合 (`build.zig`)
- [x] libwebp ビルド統合 (enc + dsp スカラー + SIMD dispatch, `build.zig`)
- [x] JPEG decode — `src/c/jpeg_decode.c` + `JpegDecoder` vtable
- [x] PNG decode  — `src/c/png_decode.c` + `PngDecoder` vtable (RGB/RGBA, 16-bit→8-bit)
- [x] WebP encode — `src/c/webp_encode.c` + `WebPEncoder` vtable (lossy/lossless)
- [x] CLI パイプライン — detect → decode → Lanczos-3 resize → encode → write (`main.zig`)
- [x] セキュリティ修正 — overflow guard (w×ch, h×row_stride, png_mem_read/write), quality 範囲チェック
- [x] JPEG/PNG/WebP 単体テスト計 10 件
- [x] `parseArgs` ユニットテスト (-q 境界値 12 件)

---

## Phase 3 — SIMD 最適化

### Phase 3A — SIMD トグル scaffold ✅

- [x] `-Dsimd` ビルドオプション追加 (`build.zig`)
- [x] `build_options` モジュールを pict_mod / unit_tests / ffi_lib / wasm_exe に伝播
- [x] `hPassRow` / `vPassFull` を comptime dispatcher + scalar + stub に分割 (`resize.zig`)
- [x] `simd_enabled` 定数を公開、scaffold テスト 2 件追加

### Phase 3B — Zig SIMD 実装 + emitRow 整合 ✅

- [x] `hPassRowSimd`: `@Vector(4, f32)` で 4ch 並列 H-pass 実装
- [x] H-pass 正確性テスト 3 件 (scalar vs SIMD ±1.0 以内、ch=3 フォールバック)
- [x] `vPassFullSimd`: `@Vector(4, f32)` で 4ch 並列 V-pass 実装
- [x] V-pass 正確性テスト 3 件 (scalar vs SIMD ±1 以内、ch=3 フォールバック完全一致)
- [x] `vPassOneDyRowScalar` / `vPassOneDyRowSimd` 抽出 — `anytype` 静的ディスパッチで vtable 間接呼び出しを排除
- [x] `InterSource` / `RingSource` を `.get()` のみの単純 struct に整理 (関数ポインタなし)
- [x] `StreamingResizer.emitRow` を `vPassOneDyRow*` 経由に統一 (vPassFull と同一コア)
- [x] emitRow ch=3 フォールバック回帰テスト追加 (expectEqualSlices で完全一致確認)

#### Phase 3B ベンチマーク基準値 (Phase 3C 比較用)

環境: Apple M-series (aarch64), ReleaseFast, `zig build bench [-Dsimd=true]`, 5回平均

| ワークロード | SIMD=off | SIMD=on |
|---|---|---|
| full-frame RGBA 1920×1080→640×360 | 84.0 ms | 56.3 ms |
| streaming  RGBA 1920×1080→640×360 | 85.3 ms | 56.8 ms |
| full-frame RGB  1920×1080→640×360 | 73.2 ms | 71.3 ms |

### Phase 3C — C vendor SIMD 有効化

- [x] `addLibjpegTurbo` をターゲット対応にリファクタ (config header 内生成化、`with_simd` をターゲット arch で決定)
- [x] libjpeg-turbo aarch64 NEON: `simd/arm/*.c` (13 ファイル) + `aarch64/jsimd.c` + `aarch64/jchuff-neon.c` + `jsimd_neon.S` (`-x assembler-with-cpp`) + `WITH_SIMD=1` + `neon-compat.h` 生成
- [x] libjpeg-turbo x86_64: NASM 依存のため今フェーズはスキップ (`WITH_SIMD=null` fallback 維持)
- [x] libpng aarch64: `arm/arm_init.c` + `filter_neon_intrinsics.c` + `palette_neon_intrinsics.c` + `-DPNG_ARM_NEON_OPT=2`
- [x] libpng x86_64: `intel/intel_init.c` + `filter_sse2_intrinsics.c` + `-DPNG_INTEL_SSE_OPT=1`
- [x] `zig build bench` でベンチマーク計測・Phase 3B 基準値との比較

#### Phase 3C ベンチマーク結果 (Phase 3B 比較)

環境: Apple M-series (aarch64), ReleaseFast, `zig build bench [-Dsimd=true]`, 5回平均

| ワークロード | Phase 3B SIMD=off | Phase 3C SIMD=off | Phase 3C SIMD=on |
|---|---|---|---|
| full-frame RGBA 1920×1080→640×360 | 84.0 ms | 85.1 ms | **57.8 ms** |
| streaming  RGBA 1920×1080→640×360 | 85.3 ms | 85.2 ms | **59.0 ms** |
| full-frame RGB  1920×1080→640×360 | 73.2 ms | 73.8 ms | 74.4 ms |

SIMD=off での結果は Phase 3B と同等（誤差範囲内）でリグレッションなし。
SIMD=on での RGBA は約 32% 短縮（C vendor SIMD の影響より Zig SIMD が主因）。

**各ライブラリの SIMD 対応状況 (Phase 3C 完了時点)**

| ライブラリ | aarch64 | x86_64 | その他 |
|---|---|---|---|
| libjpeg-turbo | NEON (WITH_SIMD=1) | non-SIMD (NASM 未対応) | non-SIMD |
| libpng | NEON (PNG_ARM_NEON_OPT=2) | SSE2 (PNG_INTEL_SSE_OPT=1) | なし |
| libwebp | NEON (既存) | SSE2/SSE4.1 (既存) | なし |

---

## Phase 4 — マルチスレッド ✅ (V-pass 並列化)

- [x] `ResizeConfig.n_threads` 追加 (default=1, 0=CPU自動検出)
- [x] `VPassChunk` タスク struct + `vPassFullParallel` 実装 (`std.Thread.Pool` + `spawnWg` + `waitAndWork`)
- [x] 閾値ガード: `n_threads <= 1 or dh < 64` のときシングルスレッド fallback
- [x] `InterSource` は const 読み取り専用、dst 行範囲は排他スライスで競合なし
- [x] `--threads` / `-t` CLI オプション追加 (0=自動)
- [x] bench に `--threads` 引数伝達 + threads=1 vs 2 計測
- [x] `zig build linux` クロスコンパイル通過
- [x] 既存テスト全通過 (SIMD off/on 両方)
- [x] 2 コア VPS での実測確認 ✅

#### Phase 4 ベンチマーク (Apple M-series, ReleaseFast, 5回平均)

| ワークロード | SIMD=off t=1 | SIMD=off t=2 | SIMD=on t=1 | SIMD=on t=2 |
|---|---|---|---|---|
| full-frame RGBA 1920×1080→640×360 | 87.7 ms | **76.0 ms (-13%)** | 57.9 ms | **51.9 ms (-10%)** |
| streaming  RGBA (並列化対象外) | 86.4 ms | 87.8 ms | 58.5 ms | 61.4 ms |
| full-frame RGB  (ch=3 fallback) | 74.0 ms | **64.9 ms (-12%)** | 85.4 ms | 73.2 ms |

streaming は StreamingResizer が別実装のため並列化対象外 (設計どおり)。

#### VPS 実測結果 (シン・VPS x86_64 2コア, PNG→WebP -w 1920)

| | threads=1 | threads=2 | 変化 |
|---|---|---|---|
| real (壁時計時間) | 4.680s | **3.967s** | **-15%** |
| user (CPU 合計) | 4.404s | 4.468s | ほぼ同等 |

user がほぼ同等で real が短縮 = 2コアに分散して並列化が正常に効いている。
macOS (-13%) より VPS (-15%) の方が効果大きく、専有 2コア環境では理論値に近い短縮を確認。

---

## Phase 5 — WebAssembly / WASI

- [ ] C ライブラリの Wasm ビルド接続 (`zig build wasm`)
- [ ] `wasm32-freestanding` 切り替え (Cloudflare Workers 向け)
- [ ] WASI ランタイムでの動作確認

---

## Phase 6 — FFI 公開シンボル ✅

- [x] `export fn pict_decode` — @deprecated ラッパー (pict_decode_v2 を内部で呼ぶ)
- [x] `export fn pict_decode_v2` — out_len 付き decode、pict_free_buffer と対称な契約
- [x] `export fn pict_resize` — Lanczos-3 リサイズ、n_threads / ゼロ次元ガード / overflow ガード
- [x] `export fn pict_encode_webp` — quality / lossless オプション対応 WebP エンコード、overflow ガード
- [x] `export fn pict_free_buffer` — c_allocator バッファの解放エントリポイント
- [x] `mul3SizeChecked` — 3値乗算のオーバーフローチェックヘルパー (pict_resize / pict_encode_webp に適用)
- [x] 入力ポインタを `[*c]const u8` (C pointer) に変更、null ガード付き
- [x] 出力ポインタを `?*T` に変更、null ガード付き (out_len は全関数で必須: null → null 返却)
- [x] 失敗時契約統一: null 返却、out_len は変更しない (out_w/h/ch は未定義)
- [x] FFI ユニットテスト 12 件 (成功系 C×4 / null out arg A×3 / sentinel 不変 B×4 / decode 不正データ×1)
- [x] `zig build test` / `zig build test -Dsimd=true` 全通過 (59 tests)
- [x] `test/ffi/test.ts` + `test/ffi/run.sh` 作成 (Bun FFI 結合テスト: A/B/C/D 4ケース)
- [x] Mac: `bash test/ffi/run.sh` 成功 (`zig build lib` + `bun run test/ffi/test.ts`) — A/B/C/D 全 PASS
- [x] VPS: `zig build lib-linux` + scp + `bun run test/ffi/test.ts` 成功 — Linux x86_64 (シン・VPS) 全 4 テスト PASS
- [ ] tsukasa-art: `POST /api/convert` で WebP 返却成功
- [ ] `turbojpeg.c` 統合検討 (TurboJPEG API が必要になった場合)

### メモリ管理モデル (FFI)

| 関数 | 確保側 | 解放方法 |
|------|--------|----------|
| `pict_decode` (@deprecated) | Zig (`c_allocator`) | `pict_free_buffer(ptr, w*h*ch)` — 非推奨: v2 を使うこと |
| `pict_decode_v2` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_resize` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_encode_webp` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |

### 失敗時契約

| 条件 | 戻り値 | `out_len` | `out_w/h/ch` |
|---|---|---|---|
| 成功 | 非 null | バイト数をセット | 正確な値をセット |
| 任意エラー (overflow / alloc 失敗 / ゼロ次元 / null 引数) | `null` | **変更しない** | 未定義 |

---

## Phase 7A — AVIF encode スパイク (libavif + aom system lib)

- [x] brew install libavif svt-av1 (libavif 1.4.1 / svt-av1 4.1.0 確認済み)
- [x] build.zig: `pict_mod_cli` (has_avif=true) 作成、cli の addImport を pict_mod_cli に差し替え (unit_tests 等は既存 pict_mod を維持)
- [x] build.zig: 非 CLI artifact 作成直後に `no_avif_options` (has_avif=false) を注入 (unit_tests, ffi_lib, ffi_lib_linux, wasm_exe, cli_tests)
- [x] build.zig: `addLibAvifSystem` (Homebrew cellar パス直接解決、cli のみ)
- [x] `src/c/avif_encode.c` ブリッジ (avifRGBImageSetDefaults + avifImageRGBToYUV、RGB 3ch / RGBA 4ch 両対応)
- [x] `encode.zig`: `avifEncoder()` + `AvifOptions` (extern 宣言・呼び出し両方を comptime has_avif でガード、false 時は error.AvifDisabled)
- [x] CLI: `.avif` 拡張子検出 + `--avif-speed` オプション (0-10、デフォルト 6)
- [x] `zig build` / `zig build test` 全通過
- [x] `file out.avif` → "ISO Media, AVIF Image" 確認
- [x] Sharp AVIF との速度比較ベンチ完了

### バックエンド
- **AV1 エンコーダ**: libaom (Homebrew libavif bottle デフォルト)
  - svt-av1 は別途インストール済みだが Homebrew bottle の libavif には組み込まれていないため libaom fallback を使用
- **インクルード/ライブラリパス解決**: Homebrew cellar 直接指定 (`/opt/homebrew/Cellar/libavif/1.4.1/`)

### ベンチマーク結果 (Mac aarch64 / 3840×2160 PNG → 1920×1080 AVIF / ReleaseFast)

| ツール | wall-clock (中央値) | CPU user time | ファイルサイズ |
|--------|--------------------:|:-------------:|---------------:|
| pict speed=10 (シングルスレッド) | **0.710s** | 0.66s | 2.5 MB |
| pict speed=6 (シングルスレッド) | 2.109s | 2.05s | 2.5 MB |
| Sharp 0.34 avif quality=60 (multi-thread ~8コア) | 1.141s | 9.27s | 1.5 MB |

**考察**
- pict speed=10 は Sharp より **1.6× 高速** (wall-clock)。かつシングルスレッドで CPU 効率は Sharp の 14× 以上
- pict speed=6 は wall-clock で Sharp の 1.85× 遅いが、Sharp は 8 コア占有 (user CPU 9.27s) に対し pict は 2.05s (4.5× CPU 効率)
- ファイルサイズは Sharp が 1.5 MB vs pict が 2.5 MB — libaom の speed 設定による圧縮率の差。speed=6 以下での品質改善余地あり
- **結論**: speed=10 でシングルスレッド実行でも Sharp より高速。サーバ並列処理環境では pict の優位性がさらに大きくなる見込み

### 次フェーズ候補
- Phase 7C: Linux AVIF 有効化（VPS native build）← 実装済み（下記参照）

---

## Phase 7C — Linux AVIF 有効化 (VPS native build)

- [x] `build.zig`: `addLibAvifSystem` を `artifact.rootModuleTarget().os.tag` ベース分岐に変更
  - Linux: pkg-config 必須、失敗時は `b.fatal(...)` で即停止（distro 非依存メッセージ）
  - macOS: pkg-config 優先、失敗時は `/opt/homebrew` fallback（Apple Silicon 前提）
- [x] `build.zig`: `lib-linux` ステップ説明文に「AVIF 無効、Linux AVIF FFI は VPS native build」を明記
- [x] `docs/operations.md`: AVIF system library 依存手順を追記（Mac/Linux 差分、build ターゲット別まとめ、FFI テスト手順）

### 設計上の明確化

| コマンド | 実行場所 | AVIF | 説明 |
|---------|---------|------|------|
| `zig build lib` | VPS | ✅ 有効 | Linux AVIF FFI の正式パス |
| `zig build lib-linux` | Mac | ❌ 無効 | クロスコンパイル用（互換維持） |

- `ffi_lib_linux` は AVIF 無効のまま維持（クロスコンパイル互換用）
- Linux で AVIF FFI を使う場合は VPS 上での native build が必須

### Phase 7C 完了条件（VPS で実施）✅ 確認済み

```bash
apt install libavif-dev pkg-config
zig build lib -Doptimize=ReleaseFast
ldd zig-out/lib/libpict.so | grep avif     # libavif.so.16 が解決されたことを確認済み
bun run test/ffi/test.ts                   # A〜F 全 PASS 確認済み (Case E ftyp 検証通過)
```

Mac 側の回帰確認:
```bash
zig build lib-linux
zig llvm-nm -D zig-out/linux-x86_64/libpict.so | grep pict_encode_avif  # シンボルが存在すること
```

---

## Phase 7B — AVIF FFI 公開 (pict_encode_avif)

- [x] build.zig: `ffi_lib` (Mac native) を `has_avif=true` に更新、`addLibAvifSystem` + `avif_encode.c` を追加 (`ffi_lib_linux` は Phase 7C まで has_avif=false のまま)
- [x] `src/root.zig`: `pict_encode_avif(pixels, width, height, channels, quality, speed, out_len)` を export (has_avif=false 時は null を返す ABI 互換シンボルとして存在)
- [x] `src/pipeline/encode.zig`: `has_avif=false` 時に `error.AvifDisabled` を返すテスト追加 (`zig build test` で検証)
- [x] `test/ffi/test.ts`: `pict_encode_avif` シンボル追加 + Case E (ftyp ヘッダ検証) / Case F (null 入力) / Case G (quality=255・speed=255 範囲外値) 追加 (合計 8 テスト)
- [x] `bash test/ffi/run.sh` → 全 8 テスト PASS (A/B/C/D/E/F/G)
- [x] `src/root.zig`: `pict_encode_avif` に `quality > 100 or speed > 10` の範囲チェックを追加 (Codex レビュー対応)
- [x] `src/c/avif_encode.c`: `rowBytes` を `(uint32_t)((size_t)width * (size_t)channels)` に修正 (Codex レビュー対応)

### FFI メモリ管理モデル (更新)

| 関数 | 確保側 | 解放方法 |
|------|--------|----------|
| `pict_decode` (@deprecated) | Zig (`c_allocator`) | `pict_free_buffer(ptr, w*h*ch)` |
| `pict_decode_v2` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_resize` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_encode_webp` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_encode_avif` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |

---

## Phase 8 — Node.js 対応 + npm 配布

### Phase 8A — Node.js koffi 対応

**目的**: Bun 専用の `bun:ffi` から `koffi`（Node.js / Bun 互換）に移行し、Node.js ユーザーが zigpix を使えるようにする。
> 注: koffi は当初 Deno 互換を期待していたが、Phase 8C Step 0 PoC で out-pointer 受け渡しが失敗したため、Deno 対応は `Deno.dlopen` ベースの `index.deno.ts` として別実装した。

- [x] `package.json` 作成 (`koffi` + `tsx` devDep、`"type": "module"`)
- [x] `.gitignore` に `node_modules/` 追加
- [x] `test/ffi/test.node.ts` を koffi バインディングで作成
  - `pict_decode_v2` / `pict_resize` / `pict_encode_webp` / `pict_encode_avif` / `pict_free_buffer` をバインド
  - Case A〜G (8件) を Node.js で実行。koffi.decode() でポインタ読み出し
- [x] `test/ffi/run.node.sh` 作成 — `npm install + zig build lib + npx tsx` を実行
- [x] Mac (Apple Silicon) で `npx tsx test/ffi/test.node.ts` → 全 8 件 PASS 確認
- [x] Linux VPS (x86_64) で `npx tsx test/ffi/test.node.ts` → 全 8 件 PASS 確認 (Case E ftyp 検証通過)

### Phase 8B — npm パッケージ配布 (pre-built native binary)

**目的**: ユーザーが `npm install zigpix` だけで使えるようにする。Zig のインストール不要。

- [x] プラットフォーム別 pre-built バイナリ戦略の確定
  - `optionalDependencies` を使ったプラットフォーム別パッケージ構成
  - 対象: `zigpix-darwin-arm64`, `zigpix-linux-x64`（最小構成）
  - `npm/` ディレクトリにプラットフォームパッケージのスケルトン作成
- [x] GitHub Actions CI でクロスプラットフォームビルドを自動化
  - `.github/workflows/build-native.yml` 作成
  - Mac (`macos-14`): `brew install libavif` → `zig build lib` → `libpict.dylib` アップロード
  - Linux (`ubuntu-22.04`): `apt install libavif-dev` → `zig build lib` → `libpict.so` アップロード
  - 両 runner で Bun / Node.js FFI テスト実行
- [x] `js/src/index.ts`: TypeScript 公開 API 作成 (decode / resize / encodeWebP / encodeAvif)
  - `createRequire` でプラットフォームパッケージを解決、開発時は `zig-out/lib/` にフォールバック
  - `tsconfig.json` + `@types/node` 追加、`npm run build` → `js/dist/` にコンパイル済み
  - Mac でスモークテスト: 全機能 OK (`ftyp=true`)
- [x] `libavif` / `libaom` 静的リンク方針の確定
  - **Phase 8B は動的リンク**（system libavif 必須）。静的リンクは Phase 8B+ に先送り
  - 理由: 静的リンクには libaom ソースビルドが必要で工数大
- [x] ライセンス整備（npm publish 前に必須）
  - `LICENSE`（MIT）をルートに追加
  - `THIRD_PARTY_LICENSES` をルートに追加（libjpeg-turbo / zlib / libpng / libwebp / libavif / libaom）
  - ルート `package.json` の `files` に `LICENSE` / `THIRD_PARTY_LICENSES` を追加
  - `npm/zigpix-darwin-arm64/` / `npm/zigpix-linux-x64/` の `package.json` 同様に更新
  - CI で `cp LICENSE THIRD_PARTY_LICENSES npm/zigpix-*/` をアーティファクト生成前に追加
- [x] npm publish フロー確立 (`npm pack` → テスト → `npm publish`)
  - `npm login` + Granular Access Token (Bypass 2FA) で認証
  - プラットフォームパッケージ → メインの順に publish
  - `zigpix@0.0.3` / `zigpix-darwin-arm64@0.0.3` / `zigpix-linux-x64@0.0.3` を公開済み
  - E2E テスト（別ディレクトリで `npm install zigpix` → decode / resize / encodeWebP / encodeAvif 全 PASS）確認済み
- [x] `README.md` に `npm install zigpix` の使い方を追記
  - インストール手順・ESM 明記・API リファレンス・トラブルシューティング・動作環境表を追加
  - Codex レビュー指摘（ESM明記・encodeAvif null条件・トラブルシュート）対応済み
- [x] Codex レビュー指摘（0.0.3）対応済み
  - `encodeAvif` JS 層で quality/speed 範囲チェック追加（小数・負値・範囲超え → null）
  - 非対応 platform/arch で即時エラー（`unsupported platform/architecture` メッセージ）
  - arm64 以外を x64 にサイレントフォールバックする問題を解消

### Phase 8B+ — libavif / libaom 静的リンク（`npm install` だけで動く）

**目的**: `libavif-dev` のシステムインストールを不要にする。`npm install zigpix` だけで AVIF エンコードが動く状態を実現。

**切り戻し条件**: Linux x64 PoC が 48 時間以内に安定しなければ Phase 8C 先行へ切替。

#### Step 1 — Linux x64 PoC（手動静的リンク）✅

- [x] libaom submodule 追加（v3.12.1 / SHA: 10aece41）
- [x] libavif submodule 追加（v1.4.1 / SHA: 6543b22b）
- [x] VPS 上で libaom を cmake ビルド（decoder/docs/tests オフ、nasm 有効）
- [x] libavif を cmake ビルド（`-DAVIF_CODEC_DAV1D=OFF -DAVIF_BUILD_TESTS=OFF -DAVIF_CODEC_AOM=LOCAL -DAVIF_LIBYUV=OFF`）
  - FetchContent で libaom を自動ダウンロード・ビルド（`_deps/libaom-build/libaom.a`）
- [x] `zig build lib -Davif=static` で静的リンク成功
- [x] PoC 完了判定:
  - `ldd libpict.so` に `libavif.so` / `libaom.so` が出ないこと ✅
  - Bun / Node.js 両方で FFI テスト 全8件 PASS（Case E ftyp 確認・Case G null 確認）✅

#### Step 2 — build.zig 統合 ✅

- [x] `addLibAvifStatic` ヘルパー追加（libavif.a + libaom.a を `addObjectFile` で直接リンク）
- [x] `-Davif=static|system` オプション追加（デフォルト: system で後方互換維持）

#### Step 3 — CI 更新 ✅

- [x] Linux: `apt install cmake nasm ninja-build g++` 追加、`apt install libavif-dev` 削除
- [x] macOS: `brew install cmake ninja`（arm64 は nasm 不要を確認）
- [x] 両 runner で libavif を cmake 静的ビルド（FetchContent で libaom 自動ビルド）
- [x] `zig build lib -Davif=static` に変更
- [x] `ldd` / `otool -L` で libavif / libaom 動的依存がないことを CI で検証
- [x] 両 runner で FFI テスト全件 PASS 確認（build-linux-x64: 3m2s / build-darwin-arm64: 2m50s）

#### Step 4 — 仕上げ

- [x] `THIRD_PARTY_LICENSES` に libaom v3.12.1 (10aece41) / libavif v1.4.1 (6543b22b) の正確なバージョン・SHA を記載
- [x] `npm 0.1.0` で publish 完了
  - `zigpix@0.1.0` / `zigpix-darwin-arm64@0.1.0` / `zigpix-linux-x64@0.1.0`
  - `apt install libavif-dev` 不要化達成
  - `npm install zigpix` だけで AVIF エンコードが動く状態を実現

---

### Phase 8C — Deno 対応（任意）

**目的**: Node/Bun に加えて Deno でも同一の公開API（decode / resize / encodeWebP / encodeAvif）を提供する。

**完了条件**:
- `deno run --allow-read --allow-ffi test/ffi/test.deno.ts` で Case A/B/C/G PASS
- encodeAvif の null 条件が Node/Bun 版と完全一致
- CI Deno ジョブが常時グリーン（初期は allow-failure 可）

**切り戻し条件**: Step 0 PoC で koffi 案が失敗したら迷わず Deno.dlopen（案A）へ切替

#### Step 0 — npm:koffi PoC（捨てPoC）✅

- [x] `import koffi from "npm:koffi"` が成功
- [x] `koffi.load("...libpict.so|dylib")` が成功
- [x] `pict_decode_v2` 1回呼び出し → **Check3 失敗**（out-pointer が Deno で動作しない）
- → 案B 不採用、即 Deno.dlopen（案A）へ切替

#### Step 1 — index.deno.ts 実装（Deno.dlopen 案A）✅

対象 FFI 関数（5つ全て必須）:
- [x] `pict_decode_v2` — JPEG/PNG → raw pixels
- [x] `pict_resize` — Lanczos-3 リサイズ
- [x] `pict_encode_webp` — WebP エンコード
- [x] `pict_encode_avif` — AVIF エンコード
- [x] `pict_free_buffer` — **内部必須**（ネイティブメモリ解放）

実装:
- [x] `Deno.dlopen` で上記5関数を定義（型は Deno FFI 型に変換）
- [x] `Deno.UnsafePointerView` でポインタ→Uint8Array 変換（`koffi.decode()` 相当）
- [x] `resolveLibPath()` を Node/Deno 共通化（`node:module` の `createRequire` 活用）
- [x] encodeAvif の null 条件（quality 0–100 / speed 0–10）が Node/Bun 版と一致

#### Step 2 — テスト追加 ✅

- [x] `test/ffi/test.deno.ts` 作成（Case A/B/C/E/G の計6件）
- [x] `deno run --allow-read --allow-ffi --allow-env test/ffi/test.deno.ts` で全件 PASS

#### Step 3 — CI・ドキュメント ✅

- [x] `.github/workflows/build-native.yml` に Deno テストステップ追加（CI グリーン確認後、`continue-on-error` 削除済み）
- [x] README に Deno の install / run 例を追記
- [x] 対応マトリクス（Node / Bun / Deno）を README に明示
- [x] `package.json` に `exports["./deno"]` を追加（`npm:zigpix/deno` で解決可能）
- [x] THIRD_PARTY_LICENSES に変更なし（静的リンクライブラリは変更なし）

---

## 非機能 / 運用

- [ ] E2E テスト自動化 (`build.zig` に `zig build e2e` ステップ)
- [ ] メモリピーク計測・Sharp との比較
- [x] Linux VPS クロスコンパイル動作確認 (`zig build linux`) — Phase 4 で確認済み
- [x] `docs/operations.md` 更新 — Phase 7C で libavif 依存手順・FFI テスト手順を追記済み
