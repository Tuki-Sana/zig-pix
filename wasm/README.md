# zigpix-wasm — ブラウザ向け AVIF エンコーダ

libavif + libaom を Emscripten で WebAssembly にコンパイルしたブラウザ専用 AVIF エンコーダです。

## 用途

| 用途 | 推奨ランタイム |
|------|---------------|
| サーバーサイド / 大画像 | zigpix ネイティブ（Node / Bun / Deno） |
| ブラウザ / Cloudflare Pages 静的 JS | **本モジュール（WASM）** |
| Cloudflare Workers Free | ❌ CPU 10ms 制限で不可 |

## ビルド

```bash
# 事前条件: ~/emsdk で emsdk が有効化されていること
source ~/emsdk/emsdk_env.sh

bash scripts/build-wasm.sh        # リリースビルド
bash scripts/build-wasm.sh --simd # WASM SIMD 有効（モダンブラウザ向け）
```

成果物は `wasm/dist/` に出力されます：

| ファイル | raw | gzip |
|---------|-----|------|
| `avif.wasm` | 3.4MB | **1.1MB** |
| `avif.js` | 60KB | — |
| `avif.node.js` | 60KB | — (Node.js テスト用) |

## テスト

```bash
# Node.js smoke test (12 件)
node wasm/test.node.mjs

# ブラウザテスト
npx serve wasm/
# → http://localhost:3000/test.html を開く
```

## API

```ts
import { createAvifEncoder } from './js/index.ts';

const enc = await createAvifEncoder();

// rgbaPixels: Uint8Array (width × height × 4)
const avif = enc.encode(rgbaPixels, width, height, {
  quality: 60,  // 0–100 (高いほど高品質)
  speed: 10,    // 0–10 (10 = 最速・低品質)
});

if (avif) {
  const blob = new Blob([avif], { type: 'image/avif' });
}
```

## パフォーマンス注意

> **25 ms** はブラウザ実測での基準値ですが、これは **256×256 RGBA・speed=10 最速設定** での値です。

| 画像サイズ | speed | 目安 |
|-----------|-------|------|
| 256×256 | 10 | ~25 ms |
| 512×512 | 10 | ~100 ms |
| 1024×1024 | 10 | ~400 ms |
| 256×256 | 6 | ~数秒 |

大画像・低 speed 設定はブラウザ UI をブロックするため、`Worker` 内での実行を推奨します。

## 依存ライブラリ

| ライブラリ | バージョン | ライセンス |
|-----------|-----------|----------|
| libavif | 1.4.1 | BSD-2-Clause |
| libaom | 3.12.1 | BSD-2-Clause |
| Emscripten | 5.0.5 | MIT |
