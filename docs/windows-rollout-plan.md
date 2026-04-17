# Windows ネイティブ対応 — 実行計画書

**ブランチ**: **`main`**（大きな Windows 作業はブランチを切って PR する。旧 **`feat/windows-native-avif`** はマージ済み）  
**リリース目標バージョン**: **0.2.0**（Windows 対応を含む変更をまとめて上げる）  
**文書改訂**: **1.8**（Windows on ARM の npm / CI を見送り。1.7 以前の ARM64 ジョブ記述は履歴として Git を参照）  
**最終更新**: 2026-04-17

---

## 0. 概要

本書は、既存の **macOS aarch64 / Linux x86_64** に並べて **Windows x64** 向けネイティブ DLL を npm で配布し、**Node / Bun / Deno** から **AVIF 含む**既存 API と同等に使えるようにするための **実行計画**である。**Windows on ARM64 の npm / CI は見送り**（手元では `zig build lib-windows-arm64` 可、§3.3）。実装の参照実装として Linux ジョブ（`.github/workflows/build-native.yml` の `build-linux-x64`）の **CMake 静的 libavif → `zig build lib -Davif=static`** パターンを前提とする。

**想定読者**: リポジトリメンテナ、将来の Windows 対応を引き継ぐ開発者。

---

## 目次

0. 概要  
1. 目的とスコープ  
2. サポート境界（OS・ランタイム）  
3. 技術方針（実装の柱）  
3.1. `build.zig` 実装メモ  
3.2. CI・成果物パス（x64 実装の正）  
3.3. Windows on ARM64（手元ビルドのみ・npm / CI 見送り）  
4. マイルストーンとチェックリスト  
5. 完了の定義（0.2.0 を出す条件）  
6. リスクと切り戻し  
7. 関連ドキュメント  
8. 改訂履歴

---

## 1. 目的とスコープ

### 1.1 目的

- **ネイティブ Windows**（PowerShell / cmd、**Node / Bun / Deno**）で、既存の **macOS / Linux** と **機能parity** を取る。
- **AVIF** は初回リリースから **Linux/mac と同様に静的リンク**（`-Davif=static` 相当のパイプライン）で提供する（方針 **A**）。
- **CI** でビルド・結合テストを回し、**手元 Windows への依存を補助**に留める。

### 1.2 対象プラットフォーム（ネイティブ DLL）

| OS / CPU | npm サブパッケージ（案） | 備考 |
|----------|-------------------------|------|
| Windows **x64** | `zigpix-win32-x64` | Node の `os.platform()==='win32'` かつ `arch()==='x64'` |
| Windows **ARM64**（WoA） | **（npm 未提供）** | 利用者は **`ZIGPIX_LIB`** で自前の `libpict.dll` を渡すか **x64 版 Node** と `zigpix-win32-x64` を使う。開発者向けに **`zig build lib-windows-arm64`**（`build.zig`）は残す |

- 成果物ファイル名は既存ローダーと揃え **`libpict.dll`**（アーキテクチャごとに別ビルド・別パッケージで配布）。
- **32-bit Windows** は対象外（README で **64-bit のみ**と明記）。

### 1.3 非ゴール（この計画書の範囲外でもよいもの）

- **Windows 7 / 8.1** — 対象外。**下限は Windows 10 以降**（理由は §2.1）。
- **MinGW 系を第一ターゲットにする** — まず **MSVC 系ツールチェーン**（`x86_64-windows-msvc` / `aarch64-windows-msvc`）で一本化。GNU は必要になった段階で検討。
- **Linux の新アーキ**（例: `linux-arm64` npm）— 本計画は **win32** に限定（別イシュー可）。

---

## 2. サポート境界（OS・ランタイム）

### 2.1 Windows の下限

- **Windows 10 以降（64-bit）** とする。
- **根拠**: ルート `package.json` の **`"engines": { "node": ">=18.0.0" }`** に合わせる。Node.js 公式ビルドのサポート OS と整合させ、**「Node が公式サポートする Windows」＝ zigpix がサポートするネイティブ Windows** と定義する。

### 2.2 WSL2

- **サポートする。** WSL2 上の Linux ディストリでは **Linux 向けバイナリ**（`zigpix-linux-x64` 等）が使われる。
- README / FAQ で **「ネイティブ Windows は DLL。WSL2 内は Linux 用 `.so`」**と分けて記載し、問い合わせを減らす。

### 2.3 Bun / Deno

- **Windows**: GitHub Actions の **`build-windows-x64`** で **Bun・Node・Deno の FFI / E2E** を実行する（§4 M2）。**`windows-11-arm` ジョブは置かない**（§3.3）。

---

## 3. 技術方針（実装の柱）

1. **`build.zig`**  
   - Windows 向け **共有ライブラリ**（`libpict.dll`）のビルドステップを追加。  
   - C 依存（libjpeg-turbo / libpng / libwebp）の **コンパイル分岐**を Windows + MSVC に合わせて追加。  
   - **AVIF**: CI 上で **libavif（+ AOM）を CMake で静的ビルド** → Zig がリンク（既存の **`.github/workflows/build-native.yml`** 内 Linux ジョブと同型）。

2. **ツールチェーン**  
   - 主経路: **`windows-latest`（x64）** でビルド・**実行テスト**まで完結。  
   - **Windows on ARM64**: **CI ジョブは置かない**。手元では **`zig build lib-windows-arm64 -Davif=static`**（§3.3）。  
   - Zig バージョンは既存 CI に合わせる（現状 **0.13.0**）。

3. **npm optional（3 サブパッケージ）**  
   ルート `zigpix` の **`optionalDependencies`** は **同一バージョン（例: 0.2.0）**で **次の 3 件のみ**。

   | パッケージ | 中身（代表） |
   |------------|----------------|
   | `zigpix-darwin-arm64` | `libpict.dylib` |
   | `zigpix-linux-x64` | `libpict.so` |
   | `zigpix-win32-x64` | `libpict.dll`（x64） |

   各 `npm/zigpix-*/package.json` の **`os` / `cpu`** と `files` を npm の規約に合わせて維持する。

4. **ローダー**  
   - `js/src/index.ts` / `index.deno.ts`: **`win32` + `x64`** は optional **`zigpix-win32-x64`**。  
   - **`win32` + `arm64`**: npm optional は無い。`ZIGPIX_LIB` またはリポジトリ内 **`zig-out/windows-aarch64/libpict.dll`**（自己 `zig build`）のみ。  
   - 解決順: **`ZIGPIX_LIB` → `zig-out` → optional**（従来どおり）。

5. **ランタイム依存（ユーザー向け）**  
   - **既定**: MSVC 系リンクでは **Visual C++ 再頒布可能パッケージ（VCRedist）** が必要な場合がある。  
   - **スパイク（M1 並行・必達ではない）**: CMake 生成の静的 `.lib` と Zig を **`/MD` vs `/MT` 等で揃え**、**再頒布パッケージ不要**に近づけられるか検証する。結果は **README に「必要」または「不要」**のどちらかを確定して記載する（§4 M6）。

---

## 3.1 `build.zig` 実装メモ（ハマりどころのショートカット）

| 論点 | メモ |
|------|------|
| **CRT の一貫性** | CMake 側で MSVC ランタイムを固定する（例: `CMAKE_MSVC_RUNTIME_LIBRARY` で **静的**または **動的**を明示）し、Zig 側のターゲット **`abi` が `.msvc`** であることとリンク方針を揃える。**CMake の `.lib` と Zig のオブジェクトでランタイムが食い違う**とリンク・実行時に落ちやすい。 |
| **libjpeg-turbo の x86_64 SIMD（NASM）** | `build.zig` から NASM を直接叩くのが重い場合は、**最初は非 SIMD（C のみ）で Windows x64 を通し**、後続タスク（**M1.5** 等）で **NASM を CI に入れてパスを通し**、SIMD を有効化する段階導入も可（パフォーマンスは後追い）。 |
| **C++（AOM）** | libavif / AOM 経由で **C++ ランタイム**が必要になる。**Windows + `ilammy/msvc-dev-cmd` では `linkLibCpp()` を使わない** — Zig 同梱の libc++abi と MSVC の `vcruntime_*.h` が衝突しサブコンパイルが落ちる。静的 `aom.lib` は MSVC でビルド済みのため **`linkSystemLibrary("msvcprt")`** と **`linkLibC()`** で揃え、CMake 側は **`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`（/MD）** で Zig の MSVC ターゲットと一致させる。Unix 向けは従来どおり（必要なら pthread / m 等）。 |
| **DLL のファイル名** | Zig の COFF 出力は **`pict.dll`**（`lib` 接頭辞なし）。ローダー・npm・ドキュメントは **`libpict.dll`** で統一するため、`addInstallArtifact` の **`dest_sub_path = "libpict.dll"`** で **`zig-out/windows-x86_64/`**（x64）または **`zig-out/windows-aarch64/`**（ARM64）にインストールする。 |

### 3.2 CI・成果物パス（x64 実装の正）

参照実装: **`.github/workflows/build-native.yml`** のジョブ **`build-windows-x64`**。

1. **`ilammy/msvc-dev-cmd@v1`**（`arch: x64`）で MSVC + Windows SDK を有効化する。  
2. **Ninja / NASM**（Chocolatey）— libaom / libjpeg-turbo x86_64 SIMD 用。  
3. **`vendor/libavif`** を CMake + Ninja で **静的インストール**（`build/libavif-install/`）。Windows ジョブでは **`-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`** を付与。  
4. **`zig build lib-windows -Doptimize=ReleaseFast -Davif=static`** — 成果物のインストール先は **`zig-out/windows-x86_64/libpict.dll`**（上記 `dest_sub_path`）。  
5. **`scripts/ci-verify-libpict-windows.sh`** — 主に **`llvm-readobj --coff-exports`** と **`llvm-objdump -p`**（VS 同梱 LLVM）で FFI 必須シンボル（`pict_*`）と **libavif / libaom / dav1d の DLL 非依存**を検証。Git Bash では `dumpbin` のリダイレクトが不安定なことがあるため、LLVM 優先・`dumpbin` はフォールバック。  
6. **`npm install` → `npm run build`** のあと、**`node_modules/zigpix-win32-x64/libpict.dll`** を `zig-out` で上書き（optional 未公開時と同型の overlay）。  
7. **FFI / E2E**: Bun・Node（koffi）・Deno が **`test/ffi/*` / `test/e2e/*`** を実行。Bun/Node のテストは **`zig-out/windows-x86_64/libpict.dll`** を参照する（`zig-out/lib/` は Unix 用）。  
8. **artifact** `libpict-win32-x64` に `npm/zigpix-win32-x64/` を載せる。

### 3.3 Windows on ARM64（手元ビルドのみ・npm / CI 見送り）

**方針（2026-04）**: **`zigpix-win32-arm64` を npm に出さない**。**`build-native.yml` に `windows-11-arm` ジョブは置かない**（ホストが ARM64EC と純 ARM64 DLLの組み合わせで FFI を CI 保証しづらい、Bun FFI が WoA で非対応、コスト対効果）。

手元で **`libpict.dll`（aarch64-windows-msvc）** を試す場合の目安:

1. **`ilammy/msvc-dev-cmd`**（`arch: arm64`）で MSVC + Windows SDK。  
2. **CMake（libavif）** — **`Visual Studio 17 2022` + `-A ARM64`**、`cmake --build --config Release` + install。  
3. **`scripts/ci-normalize-libavif-msvc-libs.sh`**（VS マルチコンフィグで `avif.lib` / `aom.lib` を `build.zig` と揃える）。  
4. **`zig build lib-windows-arm64 -Doptimize=ReleaseFast -Davif=static`** → **`zig-out/windows-aarch64/libpict.dll`**。  
5. **`scripts/ci-verify-libpict-windows.sh zig-out/windows-aarch64/libpict.dll`**。必要なら **`scripts/verify_win_dll_load.zig`**（純 ARM64 exe；CRT を DLL 同ディレクトリに置く等はスクリプト先頭コメント参照）。

**トラブルシュート（Windows・x64 中心 + 手元 ARM64）**

| 症状 | 原因の例 | 対処の方向 |
|------|-----------|------------|
| `libcxxabi` サブコンパイル失敗、`vcruntime_typeinfo` 二重定義 | Windows で `linkLibCpp()` + MSVC ヘッダ混在 | `msvcprt` + CMake `/MD` 明示（§3.1） |
| `cp: ... libpict.dll: No such file` | Zig 既定出力が `pict.dll` のみ | `dest_sub_path` で `libpict.dll` インストール |
| Bun `dlopen` **126**、`zig-out/lib/libpict.dll` | FFI テストが Unix パス固定 | `test/ffi/test.ts` / `test.node.ts` で **`win32` + `os.arch()`** と **`zig-out/windows-x86_64` / `windows-aarch64`**（**aarch64 は手元ビルド時のみ**） |
| libwebp SIMD 系コンパイルエラー（x86） | ターゲット ISA フラグ | `build.zig` で x86 WebP 用 **`-msse2 -mssse3 -msse4.1`** 等、`windows_x64_msvc` の **`cpu_model`** 調整（ログ駆動） |
| CI の verify が **exit 157** などで即死（ログに `ok:` が無い） | Git Bash から **`dumpbin` を stdout リダイレクト**すると異常終了することがある | **`llvm-readobj` / `llvm-objdump` 主経路**（`scripts/ci-verify-libpict-windows.sh` 実装） |
| **`Failed to load shared library`**（koffi、Windows x64） | 旧 koffi / 依存探索 | ルート **`koffi` を ^2.16 系**に上げる |
| **`zig build lib-windows-arm64` が即失敗**（.lib が無い等） | **VS マルチコンフィグ**で `avif.lib` が **`lib/Release/`** にあり、`build.zig` の **`lib/avif.lib`** と不一致 | **`scripts/ci-normalize-libavif-msvc-libs.sh`** を CMake install の直後に実行 |

---

## 4. マイルストーンとチェックリスト

### M0 — ドキュメント・ブランチ

- [x] 本計画書（`docs/windows-rollout-plan.md`）の作成  
- [x] 作業ブランチ `feat/windows-native-avif` の利用  

### M1 — Windows x64: ビルドのみ通す

- [x] `build.zig`: ターゲット **`x86_64-windows-msvc`** で **DLL が生成**する（インストール名 **`libpict.dll`**、`zig-out/windows-x86_64/`）  
- [x] C スタック（JPEG/PNG/WebP）が **リンクまで通る**  
- [x] **静的 AVIF** を CMake → Zig で **x64 ジョブ内**で通す（`zig build lib-windows -Davif=static`）  
- [x] **シンボルエクスポート検証**: **`scripts/ci-verify-libpict-windows.sh`**（`llvm-readobj --coff-exports` 主／`dumpbin /exports` フォールバック）で **`test/ffi/` と同じ `pict_*` 一覧**を CI ゲート化  

### M1.5 —（任意・段階導入）x64 SIMD / NASM

- [x] **GitHub Actions（`build-windows-x64`）**: Chocolatey で **Ninja + NASM** を入れ、**`GITHUB_PATH` に NASM** を追加（`build-native.yml` に明記済み）。**libaom** は CMake ビルドが NASM を利用可能。  
- [x] **libwebp（x86_64・Windows 含む）**: `build.zig` で **SSE2 / SSSE3 / SSE4.1** 用の intrinsics ソースと **`-msse2 -mssse3 -msse4.1`** を付与済み（Actions 成功時点の実装）。  
- [ ] **libjpeg-turbo x86_64 の NASM 前提 SIMD（.asm）**を `build.zig` から有効化し、品質・ベンチで支障がないか確認（現状は x86_64 で **`WITH_SIMD` を付けず** C 実装中心。計画どおり **後追いでよい**）。  

### M2 — Windows x64: CI とテスト

- [x] `.github/workflows/build-native.yml` に **`windows-latest`** ジョブ（**`build-windows-x64`**）追加済み  
- [x] **libavif 静的ビルド** → **`zig build lib-windows -Davif=static`**（Linux ジョブの `zig build lib` とは別ステップ名）  
- [x] **動的に libavif/libaom が付いていない**ことの検証（**`scripts/ci-verify-libpict-windows.sh`** の `llvm-objdump -p` / `dumpbin /dependents` で avif/aom/dav1d DLL を拒否）  
- [x] **Node** FFI / E2E  
- [x] **Bun** FFI / E2E  
- [x] **Deno** FFI / E2E  
- [x] artifact **`libpict-win32-x64`** → `npm/zigpix-win32-x64/` をアップロード  
- [ ] **手動確認（推奨）**: ユーザー名など **非 ASCII を含むパス**上の `libpict.dll` を `ZIGPIX_LIB` で指定し、**Node / Bun / Deno からロード・実行**できること（日本語環境での退避用）  

### M3 — Windows ARM64（npm / CI 見送り）

- [x] **`build.zig`**: **`lib-windows-arm64`** ステップは **維持**（`zig build lib-windows-arm64 -Davif=static` → **`zig-out/windows-aarch64/libpict.dll`**、手元・上級者向け）。  
- [x] **`zigpix-win32-arm64` npm と `build-windows-arm64` CI** — **見送り**（2026-04）。理由: ARM64EC ホストと純 ARM64 DLL の FFI を CI で保証しづらい、Bun FFI が WoA で非対応、優先度。再開は別イシュー。  

### M4 — npm メタパッケージとバージョン

- [x] ルート `package.json`: **`optionalDependencies` は 3 件**（`zigpix-darwin-arm64` / `zigpix-linux-x64` / `zigpix-win32-x64`）。バージョンは **同一（例: 0.2.0）**で揃える。  
- [x] 各 `npm/zigpix-*/package.json` の **`version`** をルートと整合  
- [x] `CHANGELOG.md` に Windows x64・WSL2・VCRedist / Defender 注記。**WoA npm は載せない**旨を明記  

### M5 — リリース手順の更新

- [x] `docs/release.md` の用語表・artifact・**publish 順**は **3 optional + ルート**のみ  
- [x] **publish 順**: **`zigpix-darwin-arm64` → `zigpix-linux-x64` → `zigpix-win32-x64` → ルート `zigpix`**  

### M6 — README / 運用（UX）

- [x] README: 動作環境表を **Windows x64 向け optional 0.2.0** に更新（**Windows 10+**、WSL2 は表下の補足）  
- [x] **セキュリティ / UX 注記**: **SmartScreen / Defender** を動作環境表に短く記載  
- [x] **VCRedist**: **多くの環境では既存**／不足時は **VC++ 再頒布可能パッケージ (x64)** を README・CHANGELOG に明記（`/MD` ビルドに整合）  

---

## 5. 完了の定義（0.2.0 を出す条件）

1. **`main`（またはマージ予定ブランチ）**で、**Windows x64** の CI が **ビルド＋シンボル検証＋ Node/Bun/Deno テスト**まで緑（必須チェックに含める）。  
2. **AVIF を含む**既存の FFI / E2E が **Node・Bun・Deno** で **Windows x64** 上で通る。  
3. **Windows on ARM64**: **npm 同梱・`build-windows-arm64` CI は対象外**（§3.3 M3）。利用者向け文言は README / CHANGELOG で **x64 のみ公式**と明示する。  
4. **手動リリース手順**（`docs/release.md`）に従い、**3 件の optional を先に publish → 最後にルート `zigpix`**。  

---

## 6. リスクと切り戻し

| リスク | 対応の目安 |
|--------|------------|
| **libaom / libavif の Windows 静的ビルド**が時間制限やディスクで CI 不安定 | キャッシュ、ビルド並列の抑制、ジョブ分割の検討 |
| **Windows on ARM の需要**が出た | **別イシュー**で optional / CI / Zig ARM64EC 対応を再検討（§3.3） |
| **CRT / VCRedist** 不足でユーザー環境のみ失敗 | README を確定文で明記し、issue テンプレに環境欄 |
| **Defender / SmartScreen** が DLL をブロック | README の M6 注記、必要ならコード署名を将来検討（本計画の必須にはしない） |

---

## 7. 関連ドキュメント

- 既存リリース手順: [`docs/release.md`](release.md)  
- 開発者向けビルド・FFI: [`docs/operations.md`](operations.md)  
- ネイティブ CI（参照実装）: [`.github/workflows/build-native.yml`](../.github/workflows/build-native.yml)  

---

## 8. 改訂履歴

| 日付 | 内容 |
|------|------|
| 2026-04-16 | 初版（要件: Win10+、x64+ARM64、AVIF 初回同梱、Bun/Deno 必須、0.2.0、WSL2） |
| 2026-04-16 | 1.1: M1/M2 検証強化、M1.5、M3 二段階ゲート、M6 UX、CRT スパイク、§3.1 `build.zig` メモ、§5 完了定義・§6 リスク更新 |
| 2026-04-16 | **1.2（最終調整）**: §0 概要・想定読者、目次、§1.2 DLL ファイル名、§3 optional 4 件の表、M1 ターゲット名確定・シンボル一覧のヒント、M3 artifact 分離、M5 publish 順の具体列挙、§5 の「4 件」明記、§7 に `build-native.yml` リンク、§1.3 の §2 参照を §2.1 に |
| 2026-04-16 | **1.3**: §3.1 を実装に合わせ更新（C++/COFF ファイル名）、**§3.2**（CI 手順・成果物パス・トラブルシュート表）、M1/M2 の **x64 到達項目を [x]**、未達（dumpbin・依存 DLL 検証・手動パス）を明示 |
| 2026-04-16 | **1.4**: **`scripts/ci-verify-libpict-windows.sh`**（`dumpbin /exports` + `/dependents`）、workflow ステップ追加、§3.2 手順更新、M1 シンボル検証・M2 動的依存検証を **[x]** |
| 2026-04-16 | **1.4.1**: verify スクリプトを **`llvm-readobj` / `llvm-objdump` 優先**に変更（Git Bash + `dumpbin` リダイレクトの exit 157 回避）、§3.2・トラブルシュート追記 |
| 2026-04-16 | **1.5**: **0.2.0 リリース準備**（ルート + 3 optional の `package.json`、`CHANGELOG`、`release.md`、README 動作環境、§3 optional 表の現実合わせ、M4〜M6・§5 のチェック反映） |
| 2026-04-16 | **1.5.1**: **§4 M1.5** を実態に合わせ分割（NASM+workflow **[x]**、libwebp x86 SIMD **[x]**、libjpeg NASM .asm は **[ ]** のまま・任意明記） |
| 2026-04-16 | **1.6**: **`zigpix` と `zigpix-wasm` のバージョンは揃えなくてよい**旨を `docs/release.md` §1.4 / Phase 2、`docs/operations.md` §8、`docs/README.md` に追記。`gh run download` 前の **`rm -rf /tmp/libpict-*`** を `release.md` に追記。本書先頭のブランチ表記を **`main`** に更新 |
| 2026-04-17 | **1.7**: ARM64EC 非互換を既知制約として整理。§2.3 に x64/ARM64 の分岐注記を追加。§3 npm 表のバージョンを 0.2.0/0.2.1 で明示。§3.3 item 7 を「FFI/E2E すべてスキップ」に更新。§4 M3 ゲート B に制約ブロックを追加。§5 完了定義を「ゲート B スキップ」に修正。トラブルシュート表の Bun 行・ARM64EC 行を現在の CI 実態（verify コマンド含む）に合わせ更新。目次に §3.3 を追加 |
| 2026-04-17 | **1.7.1**: 文書先頭の改訂番号を **1.7** に修正（表紙が 1.6 のまま残っていた件）。§3.3 の手順 6 に **CRT ステージ + verify exe 実行**を追記。トラブルシュート ARM64EC 行を **`build-native.yml` のステージ手順**と test 2 の扱いに合わせ更新 |
| 2026-04-17 | **1.8**: **WoA npm / CI 見送り**（`zigpix-win32-arm64` 削除、`build-windows-arm64` 削除、optional 3 件、§0・§3・§4 M3〜M5・§5・§6・トラブルシュートを現方針に更新） |
