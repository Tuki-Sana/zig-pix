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
- **方針メモ**: `zig build wasm` の WASI 成果物は **JPEG/PNG/WebP の C デコード・ICC 抽出・WebP エンコードをネイティブと揃えていない**（`build.zig` の wasm ブロック参照）。色管理つきブラウザ用途は **ネイティブ zenpix**、ブラウザ内 AVIF のみは **`zenpix-wasm`（Emscripten）** を使う。

---

## Phase 6 — FFI 公開シンボル ✅

- [x] `export fn pict_decode` — @deprecated ラッパー (pict_decode_v2 を内部で呼ぶ)
- [x] `export fn pict_decode_v2` — out_len 付き decode、pict_free_buffer と対称な契約
- [x] `export fn pict_decode_v3` — 埋め込み ICC を `out_icc` / `out_icc_len` で返す（`*out_icc` も `pict_free_buffer` で解放）
- [x] `export fn pict_resize` — Lanczos-3 リサイズ、n_threads / ゼロ次元ガード / overflow ガード
- [x] `export fn pict_encode_webp` — quality / lossless、ICC なし（後方互換ラッパー）
- [x] `export fn pict_encode_webp_v2` — 任意長 ICC を WebP ICCP として埋め込み（`icc == null` または `icc_len == 0` で従来どおり）
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
- [x] tsukasa-art: `POST /api/admin/upload`（multipart）経路で **ブラウザ→image/webp**（`imageResize.ts` プリリサイズ）→`convertToAvif`（`zenpix@0.1.3` 以降の静止画 WebP decode）が成立（旧メモの `/api/convert` は本リポでは未使用のため整理）
- [ ] `turbojpeg.c` 統合検討 (TurboJPEG API が必要になった場合)

### メモリ管理モデル (FFI)

| 関数 | 確保側 | 解放方法 |
|------|--------|----------|
| `pict_decode` (@deprecated) | Zig (`c_allocator`) | `pict_free_buffer(ptr, w*h*ch)` — 非推奨: v2 を使うこと |
| `pict_decode_v2` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_decode_v3` | Zig (`c_allocator`) | ピクセル: `pict_free_buffer(ptr, out_len)` / ICC: `pict_free_buffer(*out_icc, out_icc_len)` |
| `pict_resize` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_encode_webp` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)`（`pict_encode_webp_v2(..., null, 0)` と同じ） |
| `pict_encode_webp_v2` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |

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
| `pict_decode_v3` | Zig (`c_allocator`) | ピクセル: `pict_free_buffer(ptr, out_len)` / ICC: `pict_free_buffer(*out_icc, out_icc_len)` |
| `pict_resize` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_encode_webp` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_encode_webp_v2` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |
| `pict_encode_avif` | Zig (`c_allocator`) | `pict_free_buffer(ptr, out_len)` |

---

## Phase 8 — Node.js 対応 + npm 配布

### Phase 8A — Node.js koffi 対応

**目的**: Bun 専用の `bun:ffi` から `koffi`（Node.js / Bun 互換）に移行し、Node.js ユーザーが zenpix を使えるようにする。
> 注: koffi は当初 Deno 互換を期待していたが、Phase 8C Step 0 PoC で out-pointer 受け渡しが失敗したため、Deno 対応は `Deno.dlopen` ベースの `index.deno.ts` として別実装した。

- [x] `package.json` 作成 (`koffi` + `tsx` devDep、`"type": "module"`)
- [x] `.gitignore` に `node_modules/` 追加
- [x] `test/ffi/test.node.ts` を koffi バインディングで作成
  - `pict_decode_v2` / `pict_decode_v3` / `pict_resize` / `pict_encode_webp_v2` / `pict_encode_avif` / `pict_free_buffer` をバインド（Case C は v2・ICC なし呼び出し）
  - Case A〜G (8件) を Node.js で実行。koffi.decode() でポインタ読み出し
- [x] `test/ffi/run.node.sh` 作成 — `npm install + zig build lib + npx tsx` を実行
- [x] Mac (Apple Silicon) で `npx tsx test/ffi/test.node.ts` → 全 8 件 PASS 確認
- [x] Linux VPS (x86_64) で `npx tsx test/ffi/test.node.ts` → 全 8 件 PASS 確認 (Case E ftyp 検証通過)

### Phase 8B — npm パッケージ配布 (pre-built native binary)

**目的**: ユーザーが `npm install zenpix` だけで使えるようにする。Zig のインストール不要。

- [x] プラットフォーム別 pre-built バイナリ戦略の確定
  - `optionalDependencies` を使ったプラットフォーム別パッケージ構成
  - 対象（現行）: `zenpix-darwin-arm64`, **`zenpix-darwin-x64`**, `zenpix-linux-x64`, **`zenpix-win32-x64`**（Phase 8B 当時は darwin + linux のみ）
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
  - 各 `npm/zenpix-*/` の `package.json` をルートの `version` / `optionalDependencies` と揃える
  - CI で `cp LICENSE THIRD_PARTY_LICENSES npm/zenpix-*/` をアーティファクト生成前に追加
- [x] npm publish フロー確立 (`npm pack` → テスト → `npm publish`)
  - `npm login` + Granular Access Token (Bypass 2FA) で認証
  - プラットフォームパッケージ → メインの順に publish
  - `zenpix@0.0.3` / `zenpix-darwin-arm64@0.0.3` / `zenpix-linux-x64@0.0.3` を公開済み
  - E2E テスト（別ディレクトリで `npm install zenpix` → decode / resize / encodeWebP / encodeAvif 全 PASS）確認済み
- [x] `README.md` に `npm install zenpix` の使い方を追記
  - インストール手順・ESM 明記・API リファレンス・トラブルシューティング・動作環境表を追加
  - Codex レビュー指摘（ESM明記・encodeAvif null条件・トラブルシュート）対応済み
- [x] Codex レビュー指摘（0.0.3）対応済み
  - `encodeAvif` JS 層で quality/speed 範囲チェック追加（小数・負値・範囲超え → null）
  - 非対応 platform/arch で即時エラー（`unsupported platform/architecture` メッセージ）
  - arm64 以外を x64 にサイレントフォールバックする問題を解消

### Phase 8B+ — libavif / libaom 静的リンク（`npm install` だけで動く）

**目的**: `libavif-dev` のシステムインストールを不要にする。`npm install zenpix` だけで AVIF エンコードが動く状態を実現。

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
  - `zenpix@0.1.0` / `zenpix-darwin-arm64@0.1.0` / `zenpix-linux-x64@0.1.0`
  - `apt install libavif-dev` 不要化達成
  - `npm install zenpix` だけで AVIF エンコードが動く状態を実現

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
- [x] `pict_decode_v2` — JPEG / PNG / 静止画 WebP → raw pixels
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
- [x] `package.json` に `exports["./deno"]` を追加（`npm:zenpix/deno` で解決可能）
- [x] THIRD_PARTY_LICENSES に変更なし（静的リンクライブラリは変更なし）

#### 実機確認 ✅

- [x] macOS arm64（ローカル）: `test/ffi/test.deno.ts` 6/6 PASS
- [x] Linux x64（VPS 実機）: `test/ffi/test.deno.ts` 6/6 PASS
- [x] CI Linux x64 / macOS arm64: 両ジョブ Success（`continue-on-error` 削除後も安定）
- [x] `zenpix@0.1.1` npm publish — `./deno` export 含む版としてリリース

#### 0.1.2 修正 ✅

- [x] 問題: `exports["./deno"]` が `.ts` を指していたため、`node_modules` 内で `ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING` が発生
- [x] 修正: `esbuild` で `index.deno.ts` → `js/dist/index.deno.js` にトランスパイル（型除去のみ）
- [x] `package.json` `exports["./deno"]` を `./js/dist/index.deno.js` に変更
- [x] `npm run build` スクリプトに `esbuild` ステップを追加
- [x] `zenpix@0.1.2` npm publish — `./deno` を JS ファイルとして配布
- [x] Linux x64 VPS で `npm install zenpix@0.1.2` + 本番パス確認: **ALL PASS**

#### 0.1.3 パッチ（静止画 WebP decode + npm 手順整備）✅

- [x] `decode` / CLI / `pict_decode_v2` が静止画 WebP を受理（アニメ WebP は拒否）
- [x] CI: `zig-out` の `libpict` を `node_modules/zenpix-*` に上書きしてから FFI/E2E（optional 未公開時は `mkdir` + `npm/zenpix-*/package.json` を同梱してから `cp`）
- [x] `docs/operations.md` §8 — npm パッチ公開順（optional 先 → ルート）とローカル overlay 手順
- [x] `zenpix` / `zenpix-darwin-arm64` / `zenpix-linux-x64` を **0.1.3** に揃えて npm publish（実施はメンテナ）
- [x] [`zenpix-wasm@0.1.3`](https://www.npmjs.com/package/zenpix-wasm) を npm に公開（CI **Build WASM** 成功 run の artifact → `scripts/fetch-wasm-artifact.sh` → `wasm` で `npm test` / `npm publish`）

#### 0.1.4 パッチ（ICC デコード→WebP 埋め込み + ドキュメント整備）✅

- [x] `pict_decode_v3` / `decode()` で埋め込み ICC を `ImageBuffer.icc` に返す
- [x] `pict_encode_webp_v2` / `encodeWebP()` で ICC を WebP に埋め込み、`resize()` で `icc` を引き継ぎ
- [x] `build.zig` / README — `zig build wasm` とネイティブ・`zenpix-wasm` の役割分担を明示
- [x] ルート **`CHANGELOG.md`** 追加（0.1.4 エントリ・`package.json` `files` へ収録）
- [x] **`docs/release.md`** — push 後〜npm までの手順をチェックリスト化（`operations.md` §8/9 は概要＋参照に整理）
- [x] **`wasm/CHANGELOG.md`** 追加（0.1.4・`wasm/package.json` の `files` に収録）
- [x] **0.1.4 npm publish**: **`docs/release.md`** の Phase 1 →（必要なら）Phase 2 に従い実施済み（optional 二つ → ルート `zenpix`、`zenpix-wasm` は方針に応じて）。補足は `docs/operations.md` §8 / §9

**Phase 8C 完全クローズ** — Node / Bun / Deno 三ランタイム対応完了

---

## 非機能 / 運用

- [x] E2E テスト自動化 — `test/e2e/e2e.node.ts`（Node/Bun）+ `test/e2e/e2e.deno.ts`（Deno）を追加、CI 両ジョブに組み込み済み（decode → resize → encodeWebP → decode(WebP) → encodeAvif、`test/fixtures/e2e_input.png` 使用）。CI では `zig build lib` 直後に optional 同梱 `libpict` を `zig-out` で上書きしてから FFI/E2E を実行。
- [x] Sharp との比較ベンチマーク — `bench/bench.ts`（zenpix vs sharp, decode+resize+AVIF, 中央値記録）+ `.github/workflows/bench.yml`（独立ジョブ、`continue-on-error: true`、artifact に `benchmark.json` / `benchmark.md` を 90 日保存）
- [x] メモリピーク計測スクリプト — `scripts/mem-peak.sh`（GNU `time -v` / `gtime -v` で FFI と bench の Max RSS を表示）
- [x] メモリピーク README 転記 — Linux x86_64 VPS で `bash scripts/mem-peak.sh` 実測、FFI **43536 kB** / bench **135356 kB** を [README](../README.md) に反映（bench は `npm run build` + sharp 後の正常完了時）
- [x] Linux VPS クロスコンパイル動作確認 (`zig build linux`) — Phase 4 で確認済み
- [x] `docs/operations.md` 更新 — Phase 7C で libavif 依存手順・FFI テスト手順を追記済み。§8 で npm パッチ手順、§9 で `zenpix-wasm`（Pages 向け・**セマバは `zenpix` と独立**、CI は `build-wasm.yml` の手動のみ）を追記済み

---

## Phase 10 — libaom WASM（ブラウザ / Pages 静的 JS 向け AVIF エンコード）✅

### スコープ定義（事前調査済み）

**対象**:
- ブラウザ（Chrome / Firefox）
- Cloudflare Pages 静的 JS（ブラウザ上で実行されるため SIMD・条件付きスレッド利用可）

**対象外（明示的 out-of-scope）**:
- Cloudflare Workers Free — CPU 10ms 制限で AVIF エンコード不可
- Cloudflare Workers Paid — シングルスレッド WASM では大画像が数十秒かかるため非推奨

**フォールバック方針**:
- サーバーサイド・大画像は既存 zenpix ネイティブ（Node/Bun/Deno）を推奨
- ブラウザ側の小画像（〜256×256）や UX 優先シナリオに WASM を使う

**根拠**（CF Workers 公式ドキュメント確認済み）:
- SharedArrayBuffer / WASM スレッド: Workers では **非対応**（Spectre 対策）
- WASM SIMD: Workers でも **対応**（Chrome 相当）
- CPU 時間（Free）: 10ms、（Paid）: 最大 5分
- Worker サイズ上限: gzip 後 Free 3MB / Paid 10MB

### 成功条件

- [x] ブラウザ上で 256×256 PNG → AVIF エンコードが完了し `ftyp` ヘッダーを確認できる
- [x] エンコード時間 10秒以内（ブラウザ実測、speed=10）
- [x] WASM バイナリサイズ 3MB 以下（gzip 後）

### 実装手順

- [x] Emscripten emsdk セットアップ（`~/emsdk` インストール、v5.0.5、cmake / ninja 依存）
- [x] libaom WASM ビルド（`emcmake cmake` + Ninja、`AOM_TARGET_CPU=generic`、マルチスレッド無効）
- [x] libavif WASM ビルド（`AOM_INCLUDE_DIR`/`AOM_LIBRARY` 直接渡し、`SKIP_INSTALL_RULES=ON`）
- [x] `wasm/src/avif_wasm.c` — WASM ブリッジ（`avif_encode` / `avif_get_out_size` / `avif_free_output` / `avif_version`）
- [x] `scripts/build-wasm.sh` — 3ステップビルドスクリプト（libaom → libavif → emcc link、browser + node variant）
- [x] `.github/workflows/build-wasm.yml` — Ubuntu + Emscripten + `perl` で CI ビルド（`pipefail` / CMake ログまわりの修正で安定化）。成果物は npm パッケージ [`zenpix-wasm`](https://www.npmjs.com/package/zenpix-wasm)（**0.1.3** 以降で公開済み・セマバは `wasm/package.json` に追従）
- [x] `wasm/js/index.ts` — TypeScript ラッパー（`createAvifEncoder` / `AvifEncoder` API）
- [x] `wasm/dist/avif.js` + `avif.wasm` 生成（raw 3.4MB / gzip 1.1MB ← 3MB 以下 ✅）
- [x] Node.js smoke test（`wasm/test.node.mjs`、12/12 PASS）
- [x] `wasm/test.html` — ブラウザ動作確認ページ（256×256 グラデーション → AVIF encode + ftyp 検証）
- [x] ブラウザ実測（Chrome で確認済み）
  - WASM module loaded ✅
  - libavif version: 1.4.1 ✅
  - 256×256 RGBA → AVIF エンコード **25.0 ms**（成功条件 10秒以内 ✅）← **小画像・speed=10 最速設定での値**。大画像・低 speed 設定では数秒〜数十秒になる場合あり
  - ftyp brand: "avif" ✅
  - Browser decoded AVIF successfully ✅（ブラウザがデコードして表示）
  - エンコードサイズ: 2453 bytes (2.4 KB)
- [ ] Pages 静的 JS での動作確認（任意・デモ品質向上用。技術検証目的はスキップ可）

#### ビルド成果物サイズ

| ファイル | raw | gzip |
|---------|-----|------|
| avif.wasm | 3.4MB | **1.1MB** ✅（成功条件 3MB 以下） |
| avif.js   | 60KB | — |
| avif.simd.wasm | 5.6MB | 1.3MB |
| avif.simd.js   | 60KB | — |

#### 成功条件達成状況

| 条件 | 結果 |
|------|------|
| ブラウザ上で 256×256 AVIF エンコード完了 + ftyp 確認 | ✅ |
| エンコード時間 10秒以内 | **5.1 ms** ✅（256×256・speed=10、warm-up 除外・3回中央値） |
| WASM バイナリサイズ 3MB 以下（gzip） | **1.1MB** ✅ |

#### SIMD vs Baseline ベンチマーク実測値

環境: Chrome (macOS arm64), RGBA quality=60 speed=10, warm-up×1除外・3回中央値

| サイズ | Baseline (ms) | SIMD (ms) | Speedup | Output (KB) |
|--------|--------------|-----------|---------|-------------|
| 64×64      | 0.5  | 0.5  | 1.00× | 0.4 |
| 256×256    | 5.1  | 4.2  | **1.21×** | 0.8 |
| 512×512    | 16.5 | 14.6 | **1.13×** | 1.2 |
| 1024×1024  | 60.5 | 53.1 | **1.14×** | 2.9 |

**考察**:
- SIMD 効果は 12〜21% 短縮（256×256 以上）。libaom の手書き SIMD は未発動（`AOM_TARGET_CPU=generic`）、Emscripten 自動ベクトル化のみの効果
- 64×64 は初期化コスト支配域のため差なし
- 1024×1024 が 60ms 台 → Worker に移せばメインスレッドをブロックしない実用域

**難易度**: 高（Emscripten ツールチェーン、libaom ビルド設定、WASM バイナリ最適化）  
**推奨着手条件**: 非機能（E2E・ベンチ）安定後 ✅（現在達成）

---

## Phase 11 候補・既知の制約事項

### 今後の優先順位（運用メモ）

1. **tsukasa-art 統合・転送最適化**（`zenpix` 更新・ブラウザ→VPS のフォーマット）
2. **Phase 12-B / 12-C**（zenpix WebP encode、`<picture>` で AVIF+WebP 等）— 要件が付いたら
3. **zenpix-wasm の Pages 実利用確認**（任意）
4. **Phase 5**（`zig build wasm` / Workers）— エッジで本体 pict を動かす方針が付いたら

### zenpix サーバーサイド統合（tsukasa-art PoC）

`tsukasa-art` に zenpix を組み込み、Sharp を置き換えて AVIF 変換をサーバーサイドで実行。

#### 実施内容（2026-04-13）
- `zenpix@0.1.2` を tsukasa-art に追加（`bun add zenpix`）
- `src/lib/utils/imageConvert.ts` 作成：`decode → resize（fit:inside）→ encodeAvif` 共通ユーティリティ
- `upload.ts` / `upload-r18.ts` の Sharp を zenpix に置き換え、出力を `.webp` → `.avif` に変更
- ローカルで curl テスト実施：ftyp brand "avif" ✅ 確認済み

#### 本番デプロイ時に発生した問題

**問題**: `bun:alpine` ベースのコンテナで zenpix が起動失敗

```
Error: Failed to load shared library: Error relocating
  /app/node_modules/zenpix-linux-x64/libpict.so:
  __vsnprintf_chk: symbol not found
```

**原因**: `libpict.so` は glibc 向けにビルドされているが、Alpine Linux は musl libc を使用しており `__vsnprintf_chk`（glibc 拡張）が存在しない。

**対処**: Dockerfile のベースイメージを全ステージで `bun:alpine` → `bun:slim`（Debian ベース・glibc）に変更。あわせて Alpine busybox 固有の `addgroup`/`adduser` を Debian 標準の `groupadd`/`useradd` に修正。

#### musl（Alpine）対応について

zenpix を Alpine コンテナで使うには musl 向けの別配布が必要：

- `zenpix-linux-x64-musl` パッケージを新設
- `js/src/index.ts` のローダーに glibc/musl 判定を追加（現状は `platform + arch` のみ）
- libavif/libaom を musl ツールチェーンで CI ビルド

**工数**: 半日〜1日。需要が出たら将来フェーズで対応。  
**当面の方針**: glibc 系（Debian/Ubuntu ベース）コンテナで運用。

#### ブラウザプリリサイズと zenpix のフォーマット整合

- **履歴（`zenpix` 0.1.2 以前）**: `tsukasa-art` の `imageResize.ts` はリサイズ後を **image/png** で送っていた。当時は **zenpix の `decode()` が WebP 非対応**のため、Canvas を WebP で送ると VPS で `decode failed` となった。
- **`zenpix@0.1.3` 以降**: 静止画 WebP を `decode` 可能。依存を上げたうえで `imageResize.ts` を **image/webp** に戻せば転送量を抑えられる（アニメ WebP は未対応のまま送らないこと）。

---

## Phase 12 候補: zenpix WebP 対応と tsukasa-art フォールバック

ブラウザ表示の AVIF フォールバック（古い Safari 等）と、ブラウザ→VPS 転送の軽量化の両方に WebP を使えるようにする。

### 12-A: WebP decode（zenpix）✅（静止画のみ）

- **難易度**: 中
- **内容**: `libwebp` の `src/dec/*.c` を `build.zig` に追加、`detectFormat` で RIFF+WEBP を検出、`WebpDecoder` + `pict_decode_v2` 経路。アニメーション WebP は拒否。
- **完了後**: `zenpix@0.1.3` 以降を `tsukasa-art` に取り込み → `imageResize.ts` を WebP 送りに戻せる（転送量削減）

### 12-B: WebP encode（zenpix）✅

- **難易度**: 中
- **内容**: `libwebp` の encode API を Zig でラップし、`encodeWebp` 等を公開
- **状態**: `pict_encode_webp` / `pict_encode_webp_v2` / `encodeWebP()`（`js/src/index.ts`）/ E2E `decode→encodeWebP→decode` は **実装済み**。**0.1.4** から WebP への ICC 埋め込みがネイティブ経路で利用可能

### 12-C: tsukasa-art で AVIF + WebP 併用 ✅（主要経路）

- **難易度**: 低〜中
- **内容**:
  - `upload.ts` でフルサイズを AVIF + WebP の両方生成し R2 に保存（並列可）
  - `<picture>` で AVIF → WebP の出し分け
  - 12-A 完了後、`imageResize.ts` の転送フォーマットを WebP に変更可能
- **状態**（2026-04-14）: `works` / `sketches` の `image_webp_url`、公開ページ（作品詳細・WorkCard・習作一覧/詳細/モーダル・R18 作品詳細で WebP があるとき）、管理編集の `initial.imageWebpUrl` まで反映。スキーマ反映は各環境で `bun run db:push`。R18 アップロード経路は従来どおり WebP なし可。

---

## Phase 13 — PNG エンコード / crop / EXIF 自動回転

設計詳細: [`docs/feat-exif-crop-png.md`](./feat-exif-crop-png.md)  
ブランチ: `feat/exif-crop-png`

---

### Phase 13A — PNG エンコード出力

**目的**: `encodePng()` を公開 API として追加。libpng は既存なので追加依存なし。

#### Zig / C 実装

- [x] `src/c/png_decode.c`: `pict_png_encode` → `pict_encode_png` に改修
  - `compression` パラメータ追加（0-9、範囲外は 6 に clamp）
  - channels=3/4 で `PNG_COLOR_TYPE_RGB` / `PNG_COLOR_TYPE_RGBA` を自動選択
  - ICC 埋め込み対応（`icc != NULL && icc_len > 0` なら `png_set_iCCP`、プロファイル名は `"ICC"` 固定）
  - 旧 `pict_png_encode` を完全削除し、ファイル内の参照・コメントをすべて `pict_encode_png` に統一
- [x] `src/pipeline/encode.zig`: `PngOptions` struct と `PngEncoder` vtable を追加
- [x] `src/root.zig`: `pict_encode_png` を export
  - シグネチャ: `pict_encode_png(pixels, width, height, channels, compression, icc, icc_len, out_len) ?[*]u8`
  - 範囲外 compression は 6 に clamp、null ガード付き

#### テスト

- [x] `src/root.zig` または `src/pipeline/encode.zig`: Zig ユニットテスト
  - 正常系: RGB 1×1 PNG、RGBA 1×1 PNG
  - compression=0 / 9 で出力サイズ差を確認
  - ICC 埋め込みあり → PNG ファイル先頭に iCCP チャンク存在
  - null 入力 → null 返却
- [x] `test/ffi/test.ts` (Bun): `pict_encode_png` シンボル追加 + Case H（PNG magic `\x89PNG`）
- [x] `test/ffi/test.node.ts` (Node): 同上
- [x] `test/ffi/test.deno.ts` (Deno): 同上

#### JS API

- [x] `js/src/index.ts`: `encodePng(image, options?)` 実装
  - koffi シンボル登録
  - `PngOptions` のバリデーション（compression 0-9 範囲チェック）
- [x] `js/src/index.deno.ts`: `encodePng` を追加
- [x] TypeScript 型: `PngOptions` / `encodePng` をエクスポート

#### E2E / ドキュメント

- [x] `test/e2e/e2e.node.ts` / `e2e.deno.ts`: `decode → resize → encodePng` 経路を追加（6/6 PASS）
- [x] `README.md`: `encodePng()` の使用例を追記

---

### Phase 13B — crop/extract

**目的**: `crop()` を公開 API として追加。純 Zig 実装、新規 C 依存なし。

#### Zig 実装

- [x] `src/pipeline/crop.zig` を新規作成
  - `CropError`: `OutOfBounds` / `ZeroDimension` / `OutOfMemory`
  - `crop(pixels, src_w, src_h, channels, left, top, crop_w, crop_h, allocator) ![]u8`
  - checked add でオーバーフロー防止、境界チェック前に実施
  - 行単位コピー（memcpy）
- [x] `src/root.zig`: `pict_crop` を export
  - シグネチャ: `pict_crop(pixels, src_w, src_h, channels, left, top, crop_w, crop_h, out_len) ?[*]u8`
  - null / ゼロ次元 / 範囲外 → null 返却、`out_len` 変更なし

#### テスト

- [x] `src/pipeline/crop.zig`: Zig ユニットテスト 4 件（正常系・境界値・エラー系・全体コピー）
- [x] `src/root.zig`: FFI ユニットテスト 3 件（成功・null out_len・null 入力・範囲外）
- [x] `test/ffi/test.ts` (Bun): `pict_crop` Case I 追加（10/10 PASS）
- [x] `test/ffi/test.node.ts` (Node): 同上（10/10 PASS）
- [x] `test/ffi/test.deno.ts` (Deno): `crop` Case I 追加（8/8 PASS）

#### JS API

- [x] `js/src/index.ts`: `crop(image, options)` 実装（koffi）
  - JS 層バリデーション（負値・非整数・NaN・Infinity・u32 超えを弾く）
  - ICC プロファイルを引き継ぐ
- [x] `js/src/index.deno.ts`: `crop` を追加
- [x] TypeScript 型: `CropOptions` / `crop` をエクスポート

#### E2E / ドキュメント

- [x] `test/e2e/`: `decode → crop → encodePng` 追加（Node/Deno 8/8 PASS）
- [x] `README.md`: `crop()` の使用例を追記

---

### Phase 13C — EXIF 自動回転

**目的**: `decode()` が JPEG EXIF の Orientation タグを読んで自動的に正しい向きで返す。

#### C 実装

- [x] `src/c/jpeg_decode.c`: `pict_jpeg_orientation(data, len) uint8_t` を追加
  - `FF D8 FF` マジック確認 → 非 JPEG は 1 を返す
  - バイト列を線形スキャンして `FF E1` (APP1) マーカーを探す
  - **セキュリティ（必須）**: 各 `FF xx` セグメントを読む前に `offset + 2 <= len` を確認し、length フィールドが示す末尾もバッファ内に収まるか検証する。IFD オフセット・エントリ数も EXIF セグメント境界内に収まるか各ステップで確認する
  - `"Exif\0\0"` シグネチャ確認
  - TIFF バイトオーダー（`II` / `MM`）判定
  - IFD0 エントリを走査してタグ `0x0112` を検索
  - 値が 1-8 の範囲外なら 1 を返す

#### Zig 実装

- [x] `src/pipeline/rotate.zig` を新規作成
  - `RotateError`: `OutOfMemory`
  - `rotate(img: ImageBuffer, orientation: u8, allocator) !ImageBuffer`
  - orientation=1 → img のコピーなし、そのまま返す
  - 2/3/4 → 同サイズバッファ確保、ピクセル変換
  - 5/6/7/8 → 幅高さ交換バッファ確保、ピクセル変換
  - 全 orientation で RGB/RGBA（channels=3/4）両対応
- [x] `src/root.zig`: `pict_rotate` / `pict_jpeg_orientation` を export
  - `pict_rotate(pixels, src_w, src_h, channels, orientation, out_w, out_h, out_len) ?[*]u8`
  - `pict_jpeg_orientation(data, len) u8`

#### テスト

- [x] `src/pipeline/rotate.zig`: Zig ユニットテスト
  - orientation=1 → 入力と同一ピクセル列
  - orientation=3 → 180° 回転後のピクセル確認（2×1 RGBA で手計算）
  - orientation=6 → 90° CW 後に幅高さが交換されること
  - orientation=8 → 90° CCW 確認
  - channels=3/4 両方
- [x] `src/c/jpeg_decode.c` テスト: `pict_jpeg_orientation`
  - orientation 付き JPEG フィクスチャ（専用 JPEG を `test/fixtures/` に新規追加）で既知の値が返ること
  - 非 JPEG バイト列 → 1 を返す
  - 壊れた EXIF（マーカー長が範囲外）→ 1 を返す（クラッシュしない）
- [x] `test/ffi/test.ts` など: Case J（orientation=6 な JPEG を decode → 幅高さ交換確認）

#### JS 組み込み

- [x] `js/src/index.ts`: `decode()` 内に自動回転を組み込む
  - `pict_jpeg_orientation` シンボル登録
  - `pict_rotate` シンボル登録
  - decode 後に orientation を取得、1 以外なら rotate して旧バッファを free、1 のときは rotate せず旧バッファのまま使う（free しない）
  - Deno 版 (`index.deno.ts`) にも同様に追加

#### E2E / ドキュメント

- [x] テストフィクスチャ: orientation=1 / 6 / 8 の JPEG を `test/fixtures/` に追加（最低限 1 と 6、余裕があれば 8 も）
- [x] `test/e2e/`: EXIF 付き JPEG を decode → 幅高さが正しいことを確認
- [x] `README.md`: 自動回転の説明を追記（「JPEG の EXIF orientation は自動適用される」）

---

### Phase 13 完了条件

- [x] `zig build test` 全通過（SIMD off/on 両方）
- [x] `bash test/ffi/run.sh` 全 PASS（Mac）
- [x] `npx tsx test/ffi/test.node.ts` 全 PASS
- [x] `deno run --allow-read --allow-ffi test/ffi/test.deno.ts` 全 PASS
- [x] E2E テスト全通過
- [ ] CI（build-native）グリーン
- [ ] バージョン番号を `0.4.0` に更新（`package.json` / `npm/*/package.json` / `CHANGELOG.md`）
- [ ] npm publish（`docs/release.md` 手順に従う）
