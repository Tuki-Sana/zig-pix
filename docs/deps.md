# Vendor Dependencies

C ライブラリは `git submodule` で管理し、特定タグに pin する。
更新手順は `scripts/vendor-update.sh` を参照。

| Library | Version | Tag | Commit | Role |
|---|---|---|---|---|
| [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) | 3.0.4 | `3.0.4` | f29eda6 | JPEG デコード |
| [zlib](https://github.com/madler/zlib) | 1.3.1 | `v1.3.1` | 51b7f2a | libpng 依存 |
| [libpng](https://github.com/glennrp/libpng) | 1.6.43 | `v1.6.43` | ed217e3 | PNG デコード |
| [libwebp](https://github.com/webmproject/libwebp) | 1.4.0 | `v1.4.0` | 845d547 | WebP エンコード・デコード |

## System Library（vendor 管理外）

| Library | 管理方法 | インストール |
|---------|---------|------------|
| libavif (+ libaom) | OS パッケージマネージャ | Mac: `brew install libavif` / Linux: `apt install libavif-dev` |

`build.zig` の `addLibAvifSystem()` が `pkg-config` で自動解決します。  
詳細は `docs/operations.md` の「system library 依存（AVIF）」を参照してください。

## 更新方針

- セキュリティパッチ: マイナーバージョン内で随時更新
- メジャーバージョンアップ: API 変更を確認後に `build.zig` と合わせて更新
- 更新後は必ず `zig build test` と `zig build linux` でクロスコンパイルを確認

## ビルドシステムとの統合

Zig の `addCSourceFiles` で直接コンパイルする。外部ツールチェーン (CMake, autoconf) は不要。
SIMD (libjpeg-turbo の NASM アセンブリ) は `build.zig` で条件分岐:
- Phase 3 完了: aarch64 NEON / x86_64 SSE2 で Lanczos-3 H-pass / V-pass を SIMD 実装済み
- wasm32 は SIMD 無効のまま (`-Dsimd=false` 相当)
