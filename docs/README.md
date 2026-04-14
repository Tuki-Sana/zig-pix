# ドキュメント案内

各ファイルの**役割**と、だいたいの**読む順**をまとめる。詳細は各ファイル本文を正とする。

## 一覧

| パス | 役割 | 主な読者 |
|------|------|----------|
| [`README.md`](../README.md) | 利用者向け（インストール・API・環境・ベンチ・トラブルシュート） | ライブラリ利用者・新規開発者の入口 |
| [`RFC.md`](../RFC.md) | 初期の設計意図・スコープ（北極星） | 設計を把握したい人 |
| [`CHANGELOG.md`](../CHANGELOG.md) | ネイティブ `zigpix` の**利用者向け**バージョン差分 | 利用者・依存更新するアプリ作者 |
| [`wasm/CHANGELOG.md`](../wasm/CHANGELOG.md) | **`zigpix-wasm` 単体**の差分（npm パッケージはルートと別） | WASM 利用者 |
| [`docs/operations.md`](./operations.md) | 日常運用（Zig / submodule / libavif / FFI・ローカル overlay） | リポジトリでビルド・検証する人 |
| [`docs/release.md`](./release.md) | **`main` へ push 済みから npm 公開まで**（チェックリスト） | メンテナ（リリース作業） |
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

## このリポジトリのドキュメントに**載せない方がよい**もの

次は **git にコミットしない**か、**別の安全な場所**（パスワードマネージャ、社内 Wiki の権限付きページ等）に置く。

- **認証情報**: npm トークン、SSH 鍵、API キー、`.npmrc` の認証行
- **個人・社内の固定情報**: 非公開 URL、社内ホスト名、個人のメール・電話を必須としない
- **未整理のセキュリティ詳細**: 再現手順のない脆弱性の断定、修正前の exploit 詳細（GitHub Security Advisories の運用に従う）
- **他人の個人情報・顧客データ**、契約上共有できない内容

手順書には **「`npm whoami` が通ること」**のように**状態だけ**書き、**秘密そのものは書かない**。
