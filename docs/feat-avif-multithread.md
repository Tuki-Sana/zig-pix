# feat: AVIF エンコード マルチスレッド対応 — 設計書

ブランチ: `feat/avif-multithread`

## 概要

`encodeAvif()` に `threads` オプションを追加し、libaom の行ベース並列（`encoder->maxThreads`）を有効化する。

| 項目 | 内容 |
|---|---|
| デフォルト | `threads: 1`（シングルスレッド、既存挙動を維持） |
| 品質への影響 | **なし**（行ベース並列のみ、タイル分割は行わない） |
| 破壊的変更 | **なし**（`threads` 省略時は従来と同一） |

---

## 1. 背景

現在 libaom は `encoder->maxThreads = 1` 固定のため、マルチコア環境（Mac M4 Pro・Windows など）で Sharp に対して不利になりやすい。行ベース並列（`maxThreads`）はタイル境界を作らないため圧縮効率への影響がなく、最も安全なマルチスレッド化手段。

### 方式の比較

| 方式 | 設定 | 速度向上 | 品質影響 |
|---|---|---|---|
| 行ベース並列 | `maxThreads = N` | 中〜大 | **なし** |
| タイル分割 | `tileRows` / `tileColumns` | 大 | わずかに低下（境界効率） |

Phase 14 では**行ベース並列のみ**実装。タイル分割は将来オプションとして検討。

---

## 2. API 変更

### `AvifOptions`（`js/src/index.ts` / `index.deno.ts`）

```typescript
interface AvifOptions {
  quality?: number; // 0–100（デフォルト: 60）
  speed?: number;   // 0–10（デフォルト: 6）
  threads?: number; // エンコーダスレッド数（デフォルト: 1）
}
```

### 使用例

```typescript
// シングルスレッド（デフォルト、VPS・本番向け）
const avif = encodeAvif(image, { quality: 60, speed: 6 });

// マルチスレッド（バッチ処理・ローカル向け）
import os from "os";
const avif = encodeAvif(image, { quality: 60, speed: 6, threads: os.cpus().length });
```

---

## 3. 実装詳細

### 3.1 `src/c/avif_encode.c`

`threads` 引数を追加し `encoder->maxThreads` に渡す。

```c
// 変更前
uint8_t *pict_encode_avif(
    const uint8_t *pixels,
    uint32_t width, uint32_t height,
    int channels, int quality, int speed,
    uint64_t *out_len
);

// 変更後
uint8_t *pict_encode_avif(
    const uint8_t *pixels,
    uint32_t width, uint32_t height,
    int channels, int quality, int speed,
    int threads,           // 追加（1 以下は 1 として扱う）
    uint64_t *out_len
);
```

エンコーダ設定に追加する箇所：

```c
encoder->speed = speed;
encoder->maxThreads = (threads > 1) ? threads : 1;  // 追加
```

### 3.2 `src/root.zig`

`export fn pict_encode_avif` に `threads: c_int` を追加。

```zig
export fn pict_encode_avif(
    pixels: [*c]const u8,
    width: c_uint,
    height: c_uint,
    channels: c_int,
    quality: c_int,
    speed: c_int,
    threads: c_int,        // 追加
    out_len: ?*u64,
) ?[*]u8 { ... }
```

### 3.3 `js/src/index.ts`（koffi）

```typescript
// FFI シグネチャ更新
const _encode_avif = _lib.func(
  "uint8 *pict_encode_avif(const uint8 *pixels, uint32 width, uint32 height, int channels, int quality, int speed, int threads, uint64 *out_len)"
);

// encodeAvif() 内
const threads = options?.threads ?? 1;
const ptr = _encode_avif(img.data, img.width, img.height, img.channels, quality, speed, threads, outLen);
```

### 3.4 `js/src/index.deno.ts`（Deno.dlopen）

```typescript
pict_encode_avif: {
  parameters: ["pointer", "u32", "u32", "i32", "i32", "i32", "i32", "pointer"],
  //                                                              ^^^^ threads 追加
  result: "pointer",
},
```

---

## 4. テスト方針

### FFI テスト（`test/ffi/test.ts` / `test.node.ts` / `test.deno.ts`）

- **Case K**: `threads=4` で AVIF エンコード → `ftyp` ヘッダ確認、バイト長 > 100
- `threads=1`（デフォルト）は既存ケースで担保済み

### E2E テスト（`test/e2e/e2e.node.ts` / `e2e.deno.ts`）

- **Step 9**: `encodeAvif(small, { quality: 60, speed: 8, threads: 4 })` → decode して寸法確認

---

## 5. ABI 互換性

`pict_encode_avif` のシグネチャに `threads` 引数を追加するため、**既存の `libpict` バイナリとは非互換**になる。npm publish 時は必ず新バイナリ（0.5.0）を全プラットフォームで揃えること。

既存ユーザーは `npm install zenpix@0.5.0` で更新すれば自動的に新バイナリが入る。`threads` を指定しなければ動作は従来と同一。

---

## 6. バージョン

`0.4.0` → **`0.5.0`**（ABI 変更を伴うため minor バンプ）
