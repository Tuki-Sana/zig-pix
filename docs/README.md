# ドキュメント案内

各ファイルの**役割**と、だいたいの**読む順**をまとめる。詳細は各ファイル本文を正とする。

## 一覧

| パス | 役割 | 主な読者 |
|------|------|----------|
| [`README.md`](../README.md) | 利用者向け（インストール・API・環境・ベンチ・トラブルシュート） | ライブラリ利用者・新規開発者の入口 |
| [`RFC.md`](../RFC.md) | 初期の設計意図・スコープ（北極星） | 設計を把握したい人 |
| [`CHANGELOG.md`](../CHANGELOG.md) | ネイティブ `zigpix` の**利用者向け**バージョン差分 | 利用者・依存更新するアプリ作者 |
| [`wasm/CHANGELOG.md`](../wasm/CHANGELOG.md) | **`zigpix-wasm` 単体**の差分（npm パッケージはルートと別） | WASM 利用者 |
| [`docs/operations.md`](./operations.md) | 日常運用（Zig / submodule / libavif / FFI・ローカル overlay、**Windows MSVC 手順**） | リポジトリでビルド・検証する人 |
| [`docs/windows-rollout-plan.md`](./windows-rollout-plan.md) | **Windows ネイティブ**（x64/ARM64 計画、CI 実装メモ、チェックリスト） | Windows 対応・リリース 0.2.0 を追う人 |
| [`docs/release.md`](./release.md) | **`main` へ push 済みから npm 公開まで**（チェックリスト。ネイティブと **`zigpix-wasm` は別セマバ**でよい旨は §1.4） | メンテナ（リリース作業） |
| [`docs/CHECKLIST.md`](./CHECKLIST.md) | 実装フェーズの**追跡用チェックリスト**（長い・時系列） | 実装中に見失わないため |
| [`docs/dev_log.md`](./dev_log.md) | 開発メモ（日付つき抜粋）。正本にしない | メンテナの作業記録 |
| [`docs/deps.md`](./deps.md) | vendor submodule とシステム libavif の一覧・更新方針 | 依存を触る人 |

## 読む順（目安）

1. **ライブラリとして使うだけ**  
   `README.md` → 必要なら `CHANGELOG.md`

2. **ソースをビルド・テストする**  
   `README.md`（開発者向け）→ `docs/operations.md` → `docs/deps.md`（依存を触るとき）

3. **実装や大きめの変更を進める**  
   上記に加え `RFC.md`（意図の確認）→ `docs/CHECKLIST.md`（該当フェーズだけでよい）

4. **npm に publish する**  
   `docs/release.md` を上から（`docs/operations.md` は補足・ローカル検証用）

### パッケージとバージョン

- **`zigpix`**（ルート + `zigpix-*` optional）と **`zigpix-wasm`** は **npm 上で別物**。**バージョン番号を揃える義務はない**（ネイティブだけ先に上げてよい）。方針は **`docs/release.md` の §1.4**。

## コミットしないメモ

リポジトリに載せたくない一行メモ（例: 直近の Actions `RUN_ID`）用に、**`docs/LOCAL.md`** を置いてよい（`.gitignore` 済みでコミットされない）。初めては `touch docs/LOCAL.md` で空ファイルからでよい。
