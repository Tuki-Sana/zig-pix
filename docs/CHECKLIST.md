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

---

## Phase 4 — マルチスレッド

- [ ] タイル並列リサイズ (`std.Thread`, `mem/tile.zig` 統合)
- [ ] スレッド数 CLI オプション (`--threads <n>`)
- [ ] 2 コア VPS での実測確認

---

## Phase 5 — WebAssembly / WASI

- [ ] C ライブラリの Wasm ビルド接続 (`zig build wasm`)
- [ ] `wasm32-freestanding` 切り替え (Cloudflare Workers 向け)
- [ ] WASI ランタイムでの動作確認

---

## Phase 6 — FFI 公開シンボル

- [ ] `export fn pict_decode / pict_resize / pict_encode` (`root.zig`)
- [ ] Bun/Node.js FFI バインディング動作確認
- [ ] `turbojpeg.c` 統合検討 (TurboJPEG API が必要になった場合)

---

## Phase 7 — 高品質出力

- [ ] `rgba16`, `yuv444_10bit` PixelFormat 追加
- [ ] YUV 4:4:4 出力対応
- [ ] AVIF 出力対応

---

## 非機能 / 運用

- [ ] E2E テスト自動化 (`build.zig` に `zig build e2e` ステップ)
- [ ] メモリピーク計測・Sharp との比較
- [ ] Linux VPS クロスコンパイル動作確認 (`zig build linux`)
- [ ] `docs/operations.md` 更新 (Phase 2 完了時点の手順)
