# pict-zig-engine

Zig で実装する高性能画像パイプラインです。  
JPEG/PNG を WebP/AVIF へ変換し、Lanczos-3 リサイズを低メモリで実行することを目標にしています。

## 現在のステータス

- Phase 1 完了（Lanczos-3 f32 リファレンス実装、StreamingResizer、テスト整備）
- Phase 2 実装中（C vendor 統合、decode/encode の end-to-end）

## セットアップ

### 1. Zig バージョン固定（mise）

```bash
mise use zig@0.13.0
zig version
which zig
```

### 2. submodule 初期化

```bash
git submodule update --init --recursive
```

## よく使うコマンド

```bash
zig build test
zig build bench
zig build linux
zig build wasm
```

## ドキュメント

- 設計要件: `RFC.md`
- 日常運用: `docs/operations.md`
- vendor 依存管理: `docs/deps.md`

## Vendor dependencies

- `vendor/libjpeg-turbo`
- `vendor/zlib`
- `vendor/libpng`
- `vendor/libwebp`

詳細なバージョンと更新方針は `docs/deps.md` を参照してください。
