# RFC: pict-zig-engine (High-Performance Image Pipeline)

## 1. 概要

イラストレーターのポートフォリオサイト向けに、JPEG/PNGをWebP/AVIFへ高速・高品質に変換・リサイズする画像処理エンジン。Zigで開発し、ライブラリとしての再利用性と、CLIとしての利便性を両立する。

## 2. ターゲット環境と実行形式

- **Primary (Native):** Linux VPS (vCPU: 2コア / RAM: 2GB) - Linux x86_64 バイナリ。
- **Secondary (Edge):** Cloudflare Workers / Edge 配信 - WebAssembly (Wasm/WASI)。
- **Development:** Mac (Apple Silicon) - クロスコンパイルを前提とする。

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
