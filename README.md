# zigpix

Zig 製の高速画像処理エンジンです。  
JPEG / PNG をデコードし、Lanczos-3 リサイズを経て WebP / AVIF にエンコードします。  
CLI ツールとして使えるほか、Bun / Node.js から FFI 経由でライブラリとして呼び出せます。

## 特徴

- **AVIF エンコード**: libaom バックエンド。speed=10 で Sharp より 1.6× 高速 (wall-clock)、CPU 効率は約 14×
- **WebP エンコード**: libwebp をフル活用した lossy / lossless 出力
- **Lanczos-3 リサイズ**: SIMD 最適化（aarch64 NEON / x86_64 SSE2）
- **マルチスレッド**: `--threads` で V-pass を並列化
- **FFI API**: `pict_decode_v2` / `pict_resize` / `pict_encode_webp` / `pict_encode_avif` を C 互換シンボルで公開

## ステータス

Phase 7C 完了 — CLI + Mac/Linux FFI で AVIF エンコードが動作確認済み。

## システム依存ライブラリ

`libavif` は system library として使用します（vendor 管理外）。

**Mac (Apple Silicon)**
```bash
brew install libavif
```

**Linux VPS (Ubuntu / Debian 系)**
```bash
apt install libavif-dev pkg-config
```

## セットアップ

### 1. Zig バージョン固定（mise）

```bash
mise use zig@0.13.0
zig version   # 0.13.0 であること
```

### 2. submodule 初期化

```bash
git submodule update --init --recursive
```

## よく使うコマンド

```bash
zig build                          # Native dev binary (Mac ARM, Debug)
zig build -Doptimize=ReleaseFast   # Native release
zig build test                     # ユニットテスト
zig build lib                      # FFI 用共有ライブラリ (.dylib / .so)
zig build linux                    # Linux x86_64 クロスコンパイル (CLI)
zig build lib-linux                # Linux x86_64 クロスコンパイル (FFI、AVIF 無効)
zig build bench                    # ベンチマーク
```

## CLI 使用例

```bash
# WebP に変換
pict input.png output.webp -w 1920

# AVIF に変換（speed=10 で最速）
pict input.png output.avif -w 1920 --avif-speed 10

# AVIF デフォルト品質 (speed=6)
pict input.jpg output.avif -w 1920 -q 60

# リサイズ + マルチスレッド
pict input.png output.webp -w 1920 --threads 4
```

```
Options:
  -w, --width  <px>       出力幅 (省略時: アスペクト比維持)
  -h, --height <px>       出力高さ
  -q, --quality <0-100>   WebP / AVIF 品質 (デフォルト: 92 / 60)
  -t, --threads <n>       並列スレッド数 (0=自動, デフォルト: 1)
  --lossless              ロスレス出力 (WebP のみ)
  --avif-speed <0-10>     AVIF エンコーダスピード (デフォルト: 6)
```

## FFI API

```c
// デコード
uint8_t* pict_decode_v2(const uint8_t* data, size_t len,
                        uint32_t* out_w, uint32_t* out_h, uint8_t* out_ch,
                        size_t* out_len);

// リサイズ
uint8_t* pict_resize(const uint8_t* src,
                     uint32_t src_w, uint32_t src_h, uint8_t channels,
                     uint32_t dst_w, uint32_t dst_h, uint32_t n_threads,
                     size_t* out_len);

// WebP エンコード
uint8_t* pict_encode_webp(const uint8_t* pixels,
                          uint32_t width, uint32_t height, uint8_t channels,
                          float quality, bool lossless,
                          size_t* out_len);

// AVIF エンコード (has_avif=false のビルドでは null を返す)
uint8_t* pict_encode_avif(const uint8_t* pixels,
                          uint32_t width, uint32_t height, uint8_t channels,
                          uint8_t quality, uint8_t speed,
                          size_t* out_len);

// バッファ解放
void pict_free_buffer(uint8_t* ptr, size_t len);
```

返却ポインタはすべて `pict_free_buffer(ptr, out_len)` で解放してください。

## FFI テスト（Bun）

```bash
bash test/ffi/run.sh   # zig build lib + bun run test/ffi/test.ts
```

## ベンチマーク結果

3840×2160 PNG → 1920×1080 AVIF / Mac aarch64 (Apple M) / ReleaseFast

| ツール | wall-clock (中央値) | CPU user | ファイルサイズ |
|--------|--------------------:|:--------:|---------------:|
| **zigpix speed=10** (シングルスレッド) | **0.710s** | 0.66s | 2.5 MB |
| zigpix speed=6 (シングルスレッド) | 2.109s | 2.05s | 2.5 MB |
| Sharp 0.34 quality=60 (~8コア) | 1.141s | 9.27s | 1.5 MB |

## Vendor dependencies

| Library | Version | Role |
|---------|---------|------|
| libjpeg-turbo | 3.0.4 | JPEG デコード |
| zlib | 1.3.1 | libpng 依存 |
| libpng | 1.6.43 | PNG デコード |
| libwebp | 1.4.0 | WebP エンコード |
| **libavif** | system | **AVIF エンコード（brew / apt 管理）** |

詳細は `docs/deps.md` を参照してください。

## ドキュメント

- 設計要件: `RFC.md`
- 日常運用・libavif セットアップ: `docs/operations.md`
- vendor 依存管理: `docs/deps.md`
