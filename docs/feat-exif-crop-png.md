# feat: EXIF 自動回転 / crop / PNG エンコード — 設計書

ブランチ: `feat/exif-crop-png`

## 概要

ポートフォリオサイトのユースケースで「zenpix だけで完結できる」状態を目指す 3 機能。

| 機能 | 目的 |
|------|------|
| EXIF 自動回転 | スマホ撮影 JPEG が正しい向きで出力される |
| crop/extract | サムネイル生成で resize と組み合わせて使える |
| PNG エンコード出力 | ロスレスが必要なケースに対応（libpng は既存） |

---

## 1. EXIF 自動回転

### 背景

JPEG には EXIF APP1 マーカーに向き情報（Orientation タグ 0x0112、値 1〜8）が埋め込まれる。
現在の `pict_decode_v3` はこれを無視するため、スマホ撮影画像が横向きや逆さまになる。

### EXIF Orientation 値の意味

| 値 | 変換 | 幅高さ変化 |
|----|------|-----------|
| 1 | なし（正常） | なし |
| 2 | 水平反転 | なし |
| 3 | 180° 回転 | なし |
| 4 | 垂直反転 | なし |
| 5 | 転置（90° CW + 水平反転） | 交換 |
| 6 | 90° CW 回転 | 交換 |
| 7 | 逆転置（90° CW + 垂直反転） | 交換 |
| 8 | 90° CCW 回転 | 交換 |

### 実装方針

**新規 FFI シンボル 2 つ（ABI 非破壊）:**

```c
// JPEG バイト列から Orientation タグを返す（非 JPEG・解析失敗は 1 を返す）
uint8_t pict_jpeg_orientation(const uint8_t *data, uint64_t len);

// orientation に従いピクセルを回転・反転した新バッファを返す
// 向き 5-8 では out_w/out_h が src_w/src_h と入れ替わる
uint8_t *pict_rotate(
    const uint8_t *pixels,
    uint32_t src_w, uint32_t src_h,
    uint8_t channels,
    uint8_t orientation,
    uint32_t *out_w, uint32_t *out_h,
    uint64_t *out_len
);
```

**JS 層での自動適用:**

`decode()` 内で:
1. `pict_decode_v3` → raw pixels（`pixPtr`）
2. `pict_jpeg_orientation(data, len)` → orientation（非 JPEG は 1 を返す）
3. 分岐:
   - orientation === 1 → `pixPtr` をそのまま使う（`pict_rotate` 呼び出しなし）
   - orientation !== 1 → `pict_rotate(pixPtr, ...)` → 新バッファ `rotPtr`、その後 `pict_free_buffer(pixPtr)` で旧バッファ解放。`rotPtr` を使う
4. 正しい向きの `ImageBuffer` を返す

`decode()` のシグネチャ変更なし。ユーザーは意識せず自動回転が適用される。  
**注意**: orientation=1 の分岐では `pict_rotate` を呼ばないため、`pixPtr` の二重 free は起きない。

### C 実装: `pict_jpeg_orientation`

`src/c/jpeg_decode.c` に追加:
- JPEG マジック（`FF D8 FF`）確認
- `FF E1` APP1 マーカーを線形スキャン
  - **セキュリティ**: 各 `FF xx` セグメントの length フィールドを読む前に、`offset + 2 <= len` を確認する。length が示す末尾 `offset + 2 + seg_len` もバッファ内に収まるか検証してからセグメント内を読む。壊れた JPEG で OOB にならないための必須チェック
- `"Exif\0\0"` シグネチャ確認
- TIFF ヘッダでバイトオーダー（`II` / `MM`）判定
- IFD0 エントリを走査してタグ `0x0112` を検索
  - IFD オフセット・エントリ数が EXIF セグメント内に収まるかを各ステップで確認
- libjpeg-turbo は使わずバイト列を直接パース（軽量）
- **スコープ**: JPEG のみ対応。PNG の eXIf チャンク・WebP の EXIF チャンクは対象外（README にも明示）

### Zig 実装: `pict_rotate`

`src/pipeline/rotate.zig` を新規作成:

```zig
pub fn rotate(img: ImageBuffer, orientation: u8, allocator: Allocator) !ImageBuffer
```

- orientation 1 → `img` をそのまま返す（コピーなし）
- 2/3/4 → 同サイズバッファを確保してピクセル変換
- 5/6/7/8 → 幅高さ交換バッファを確保してピクセル変換
- メモリ確保は `c_allocator`（FFI との対称性）

### JS 型定義変更

なし（`decode()` のシグネチャは変わらない）。

---

## 2. crop/extract

### 設計

```typescript
export interface CropOptions {
  left: number;   // 0 origin
  top: number;
  width: number;
  height: number;
}

export function crop(image: ImageBuffer, options: CropOptions): ImageBuffer
```

**制約:**
- `left + width <= image.width` かつ `top + height <= image.height` でなければエラー
- `width` または `height` が 0 の場合はエラー
- ICC プロファイルは引き継ぐ

**整数安全性**（Zig 実装で境界チェックより前に行う）:
- `left + crop_w`、`top + crop_h` → checked add（オーバーフロー → `OutOfBounds`）
- `crop_w * crop_h * channels` → `mul3SizeChecked` 相当（オーバーフロー → `OutOfMemory`）
- 行オフセット `(top + i) * src_w * channels` → checked mul（ループ内）
- ラップアラウンド後に「範囲内に見える」ケースを防ぐため、加算・乗算の checked 演算を境界比較より前に置く

**JS バリデーション**（`crop()` 呼び出し時に JS 層で弾く）:
- 負値・非整数（小数・NaN・Infinity）→ エラー
- u32 超え（> 4294967295）→ エラー

### FFI シンボル

```c
uint8_t *pict_crop(
    const uint8_t *pixels,
    uint32_t src_w, uint32_t src_h,
    uint8_t channels,
    uint32_t left, uint32_t top,
    uint32_t crop_w, uint32_t crop_h,
    uint64_t *out_len
);
```

失敗時（範囲外・ゼロ次元・null）: `null` を返す、`out_len` 変更なし。

### Zig 実装

`src/pipeline/crop.zig` を新規作成:

```zig
pub const CropError = error{ OutOfBounds, ZeroDimension, OutOfMemory };

pub fn crop(
    pixels: []const u8,
    src_w: u32, src_h: u32,
    channels: u8,
    left: u32, top: u32,
    crop_w: u32, crop_h: u32,
    allocator: Allocator,
) CropError![]u8
```

- checked 加算・乗算がすべて成功したうえで `crop_w * crop_h * channels` バイトを確保
- 行単位でコピー: 行 i → `src[(top+i)*src_w*ch + left*ch .. +crop_w*ch]`
- 新規 C ライブラリ不要（純 Zig）

### JS 型定義

```typescript
export interface CropOptions {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function crop(image: ImageBuffer, options: CropOptions): ImageBuffer
```

戻り値の `ImageBuffer.icc` は元画像の ICC をそのまま引き継ぐ。

---

## 3. PNG エンコード出力

### 設計

```typescript
export interface PngOptions {
  compression?: number; // 0-9, default 6 (zlib 準拠: 0=無圧縮, 9=最高圧縮)
}

export function encodePng(image: ImageBuffer, options?: PngOptions): Buffer
```

### 既存コード

`src/c/png_decode.c` に `pict_png_encode()` がテスト用として存在するが:
- ICC 埋め込み未対応
- 圧縮レベル固定
- FFI シンボルとして未公開

これを改修して本番品質に引き上げる。

### FFI シンボル（新規）

```c
uint8_t *pict_encode_png(
    const uint8_t *pixels,
    uint32_t width, uint32_t height,
    uint8_t channels,        // 3=RGB, 4=RGBA
    int compression,         // 0-9 (範囲外は 6 に clamp)
    const uint8_t *icc,      // nullable
    uint64_t icc_len,
    uint64_t *out_len
);
```

### C 実装変更点

`src/c/png_decode.c` の `pict_png_encode` を更新:
1. `png_set_compression_level(png_ptr, compression)` を追加
2. channels=3/4 を自動判定（`PNG_COLOR_TYPE_RGB` / `PNG_COLOR_TYPE_RGBA`）
3. ICC 埋め込み: `icc != NULL && icc_len > 0` なら `png_set_iCCP(png_ptr, info_ptr, "ICC", PNG_COMPRESSION_TYPE_DEFAULT, (png_const_bytep)icc, (png_uint_32)icc_len)` を呼ぶ
   - libpng シグネチャ: `(png_ptr, info_ptr, name, compression_type, profile, proflen)` — 第 3 引数が名前、第 4 が compression_type
4. 関数名を `pict_encode_png` に変更（旧 `pict_png_encode` は削除）
   - `src/c/png_decode.c` 内の参照・コメントをすべて更新する

### Zig 実装

`src/pipeline/encode.zig` に `PngEncoder` / `PngOptions` を追加（他エンコーダと同じ vtable パターン）。

### メモリ管理

他エンコーダと同一: Zig `c_allocator` で確保、呼び出し元が `pict_free_buffer` で解放。

### JS 型定義

```typescript
export interface PngOptions {
  compression?: number;
}
export function encodePng(image: ImageBuffer, options?: PngOptions): Buffer
```

---

## 実装順序

```
Phase 13A: PNG エンコード（最も単純・既存コードを昇格するだけ）
Phase 13B: crop/extract（純 Zig・新 C ライブラリ不要）
Phase 13C: EXIF 自動回転（EXIF パーサ + 回転変換、最も複雑）
```

PNG を先に入れることでテスト用の出力フォーマットとして使えるようになり、
crop・回転のテストで「回転/切り抜き結果を PNG で確認」できる。

---

## 影響範囲まとめ

| ファイル | 変更種別 |
|---------|--------|
| `src/c/jpeg_decode.c` | `pict_jpeg_orientation` 追加 |
| `src/c/png_decode.c` | `pict_png_encode` → `pict_encode_png` 改修（ICC + compression 追加） |
| `src/pipeline/rotate.zig` | 新規作成 |
| `src/pipeline/crop.zig` | 新規作成 |
| `src/pipeline/encode.zig` | `PngEncoder` / `PngOptions` 追加 |
| `src/root.zig` | `pict_jpeg_orientation` / `pict_rotate` / `pict_crop` / `pict_encode_png` export |
| `js/src/index.ts` | `crop()` / `encodePng()` 追加、`decode()` に自動回転を組み込む |
| `test/ffi/test.ts` など | 各フェーズでテストケース追加 |
