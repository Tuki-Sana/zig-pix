# OPERATIONS: 開発運用ガイド

このドキュメントは、`pict-zig-engine` の日常運用で迷いやすい項目をまとめたものです。  
設計思想は `RFC.md`、実務手順はこのファイルを正とします。

## 1) ツールチェーン方針

- Zig は `mise` でプロジェクト単位に固定する。
- `latest` 追従は避け、明示バージョンで pin する。
- チームで同じバージョンを使うことを最優先とする。

### 推奨手順

```bash
# プロジェクトルートで実行
mise use zig@0.13.0
zig version
which zig
```

確認基準:

- `zig version` がプロジェクトで合意した値
- `which zig` が `mise` 管理のパス

## 2) vendor 依存の管理方針

このプロジェクトでは C 依存を `git submodule` で管理する。

対象:

- `vendor/libjpeg-turbo`
- `vendor/zlib`
- `vendor/libpng`
- `vendor/libwebp`

理由:

- 依存バージョンをコミット SHA で厳密固定できる
- 更新差分とリスクを追跡しやすい
- vendor 一式を直接コミットする方式よりリポジトリ肥大化を抑えやすい

## 3) submodule 基本操作

### 初回 clone

```bash
git clone --recurse-submodules <repo-url>
```

### 既存 clone で submodule を取得

```bash
git submodule update --init --recursive
```

### submodule 更新（明示的に行う）

```bash
git submodule update --remote --recursive
git status
```

注意:

- 更新後は必ずビルド・テストを通してからコミットする
- submodule 更新コミットは、通常の機能変更コミットと分ける

## 4) 日常チェックコマンド

```bash
zig build test
zig build bench
zig build linux
zig build wasm
```

目安:

- テスト成功を Phase 完了条件の最低ラインにする
- ベンチ結果は次フェーズ最適化の比較基準として記録する

## 5) 変更時のルール（短縮版）

- まず正しさ（f32 リファレンス）を作り、最適化は後段で行う
- panic/abort より recoverable error を優先する
- API 仕様とコメントを必ず一致させる
- 境界条件（入力長、channel 数、flush 条件）のテストを先に置く
