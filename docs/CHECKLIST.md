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

### Phase 3C — C vendor SIMD 有効化 (未着手)

- [ ] libjpeg-turbo `WITH_SIMD` 有効化 (ARM NEON / x86 SSE2, `build.zig`)
- [ ] libpng `PNG_ARM_NEON_OPT` / `PNG_INTEL_SSE_OPT` 有効化
- [ ] `zig build bench` でベンチマーク基準値取得
- [ ] SIMD 有効後のベンチマーク比較・記録

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
