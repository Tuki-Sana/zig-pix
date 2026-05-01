# zenpix-wasm — ブラウザ向け AVIF エンコーダ

libavif + libaom を Emscripten で WebAssembly にコンパイルしたブラウザ専用 AVIF エンコーダです。

## 用途

| 用途 | 推奨ランタイム |
|------|---------------|
| サーバーサイド / 大画像 | zenpix ネイティブ（Node / Bun / Deno） |
| ブラウザ / Cloudflare Pages 静的 JS | **本モジュール（WASM）** |
| Cloudflare Workers Free | ❌ CPU 10ms 制限で不可 |

## リリース / CI

- **差分の正本**: 利用者向けの変更は **`CHANGELOG.md`**（本ディレクトリ）を更新する。ルート `zenpix` のネイティブ変更はルート **`CHANGELOG.md`**。
- **セマバ**は `wasm/package.json` の `version` のみ。ルートの **`zenpix` と揃える必要はない**が、**同じパッチ番号に揃える運用**も可（運用の詳細は `docs/operations.md` §8 / §9）。
- **GitHub Actions**: リポジトリの **Build WASM (zenpix-wasm)**（`workflow_dispatch`）を手動実行すると、`wasm/dist` を artifact（`zenpix-wasm-dist`）として取得できる。`npm publish` は現状ローカルまたは artifact を展開した上で手動。
- **artifact → `wasm/dist`**: リポジトリルートで `bash scripts/fetch-wasm-artifact.sh <run_id>`（`gh` CLI 必須）。**手順の正本は `docs/release.md` Phase 2**（`docs/operations.md` §9 は概要）。
- **npm レジストリ**: [zenpix-wasm](https://www.npmjs.com/package/zenpix-wasm)（`wasm/package.json` の `version` と一致。例: **0.1.5**）。

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

## パフォーマンス実測値

環境: Chrome (macOS arm64), RGBA quality=60 **speed=10 最速設定**, warm-up×1除外・3回中央値

### Baseline vs SIMD 比較

| サイズ | Baseline (ms) | SIMD (ms) | Speedup | Output (KB) |
|--------|--------------|-----------|---------|-------------|
| 64×64      | 0.5  | 0.5  | 1.00× | 0.4 |
| 256×256    | 5.1  | 4.2  | 1.21× | 0.8 |
| 512×512    | 16.5 | 14.6 | 1.13× | 1.2 |
| 1024×1024  | 60.5 | 53.1 | 1.14× | 2.9 |

> **注意**: これらはすべて **speed=10 最速設定** での値です。speed を下げると数倍〜数十倍遅くなります。

### SIMD の効果について

SIMD 版（`avif.simd.wasm`）は 12〜21% 高速ですが、現時点では **Emscripten の自動ベクトル化のみ** の効果です（libaom の手書き SIMD ルーティンは `AOM_TARGET_CPU=generic` のため未発動）。

- モダンブラウザ（Chrome 91+ / Firefox 89+ / Safari 16.4+）では SIMD 版を推奨
- 古いブラウザ向けには baseline 版にフォールバックしてください

### Worker 使用の推奨

大画像・低 speed 設定はブラウザ UI をブロックするため、`Worker` 内での実行を推奨します。

```js
// 目安: speed=10 で 1024×1024 が ~60ms → Worker 推奨境界
const worker = new Worker('avif-worker.js', { type: 'module' });
```

## 依存ライブラリ

| ライブラリ | バージョン | ライセンス |
|-----------|-----------|----------|
| libavif | 1.4.1 | BSD-2-Clause |
| libaom | 3.12.1 | BSD-2-Clause |
| Emscripten | 5.0.5 | MIT |
