# 開発ログ（抜粋）

日付は作業メモ用。詳細は Git 履歴と `docs/CHECKLIST.md` を参照。

## 2026-04-14 — ドキュメント: ベンチ比較の「立ち位置」

- README のベンチマーク直下に **「比較の読み方」** を追加。wall-clock / CPU user（マルチコア合算）/ 条件の限定を明示し、**低コア VPS での CPU 予算**に効く旨を書いた。
- 冒頭の AVIF 一文を、数値の誤読を減らす表現に差し替え。
- **メモリピーク実測**（RSS 等）は別コミットで追記する方針（CHECKLIST の非機能タスク）。

## 2026-04-14 — メモリ: `scripts/mem-peak.sh`

- GNU `time -v`（macOS は `gtime -v`）で `bun run test/ffi/test.ts` と、sharp がある場合は `bench/bench.ts` のピーク RSS を出すシェルを追加。
- README に「メモリ（ピーク RSS）」節と表の骨子を追加。**数値は Linux VPS 等でスクリプト実行後に表へ転記**する。
- npm script: `npm run mem:peak`
