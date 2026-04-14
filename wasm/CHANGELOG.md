# Changelog — zigpix-wasm

[`zigpix-wasm`](https://www.npmjs.com/package/zigpix-wasm)（ブラウザ向け AVIF エンコード専用）の利用者向け差分。ルートの `zigpix`（ネイティブ）とは別パッケージ。

## [0.1.4] - 2026-04-14

### 変更

- **セマバのみ** `0.1.4` に更新。ルート `zigpix@0.1.4` と番号を揃えた配布リリース。

### 互換性

- **API・成果物**（`dist/avif.js` / `avif.wasm`、SIMD 版、エンコードオプション）に **機能変更なし**。ブラウザ側 AVIF エンコードの挙動は 0.1.3 と同様。
- ICC / WebP / ネイティブ `decode` の変更は **`zigpix` 本パッケージ側**（ルート `CHANGELOG.md`）。

---

## [0.1.3] 以前

概要はリポジトリルートの `docs/CHECKLIST.md`（Phase 10 / npm）を参照。
