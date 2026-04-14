# RFC: zigpix (High-Performance Image Pipeline)

## 1. 概要

イラストレーターのポートフォリオサイト向けに、JPEG/PNG/静止画WebPを入出力し、WebP/AVIFへ高速・高品質に変換・リサイズする画像処理エンジン。Zigで開発し、ライブラリとしての再利用性と、CLIとしての利便性を両立する。

## 2. ターゲット環境と実行形式

- **Primary (Native):** Linux VPS (vCPU: 2コア / RAM: 2GB) - Linux x86_64 バイナリ。
- **Secondary (Browser):** Cloudflare Pages など静的ホスティング - ブラウザ側 WebAssembly（`zigpix-wasm`）。
- **Development:** Mac (Apple Silicon) - クロスコンパイルを前提とする。

> **Cloudflare Workers (Edge) はスコープ外。**  
> AVIF エンコードは最速設定でも 256×256 で約 5ms、512×512 で約 17ms かかる。  
> Cloudflare Workers の CPU 制限（無料 10ms / 有料 50ms）と相容れず、実用に耐えない。  
> 代替として「ブラウザ側 WASM でエンコード → Cloudflare Pages でホスティング」を採用。

## 3. 技術的要件

- **品質:** イラストのディテールを保持するため、Lanczos-3補間アルゴリズムを採用。
- **メモリ管理:** Edge環境(128MB)および2GB VPSを考慮し、ストリーミングまたはタイルベースの処理を必須とする。
- **並列処理:** 2コアを最大活用するマルチスレッド設計。
- **色空間:** イラストの再現性を守るため、YUV 4:4:4 出力および10-bit深度をサポート。

## 4. アーキテクチャ方針

- **Library-First:** コアロジックを独立したZigモジュールとして設計し、Bun/Node.js等のFFIからも利用可能にする。
- **Zero-copy:** メモリコピーを最小限に抑え、リソース制約下でのスループットを最大化する。
- **Simplicity:** 依存関係を最小限に抑え、Zigのビルドシステムのみで完結させる。

## 5. ゴール

1. `pict-zig-engine` CLIバイナリの生成。
2. JSランタイム(Bun/Node.js/Edge)から呼び出し可能なライブラリ形式の提供。
3. 既存のSharp(Node.js)を超える実行速度と低いメモリピークの実現。

## 6. 運用ドキュメント

- 日常運用（Zig/mise、submodule、チェック手順）は `docs/operations.md` を参照。
- **`main` へ push 済みから npm 公開まで**は `docs/release.md`（チェックリスト付き）。
