# Vendor Dependencies

C ライブラリは `git submodule` で管理し、特定タグに pin する。
更新手順は `scripts/vendor-update.sh` を参照。

| Library | Version | Tag | Commit | Role |
|---|---|---|---|---|
| [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) | 3.0.4 | `3.0.4` | f29eda6 | JPEG デコード |
| [zlib](https://github.com/madler/zlib) | 1.3.1 | `v1.3.1` | 51b7f2a | libpng 依存 |
| [libpng](https://github.com/glennrp/libpng) | 1.6.43 | `v1.6.43` | ed217e3 | PNG デコード |
| [libwebp](https://github.com/webmproject/libwebp) | 1.4.0 | `v1.4.0` | 845d547 | WebP エンコード |

## 更新方針

- セキュリティパッチ: マイナーバージョン内で随時更新
- メジャーバージョンアップ: API 変更を確認後に `build.zig` と合わせて更新
- 更新後は必ず `zig build test` と `zig build linux` でクロスコンパイルを確認

## ビルドシステムとの統合

Zig の `addCSourceFiles` で直接コンパイルする。外部ツールチェーン (CMake, autoconf) は不要。
SIMD (libjpeg-turbo の NASM アセンブリ) は `build.zig` で条件分岐:
- Phase 2: 全ターゲットで SIMD 無効 (non-SIMD で end-to-end を安定化)
- Phase 3 で有効化予定: x86_64 Linux に AVX2, wasm32 は無効のまま
