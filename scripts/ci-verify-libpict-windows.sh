#!/usr/bin/env bash
# CI / 手元 (MSVC 開発者コマンド + Git Bash): libpict.dll の exports と動的依存を検証する。
# 使い方: bash scripts/ci-verify-libpict-windows.sh [path/to/libpict.dll]
#
# 主経路: llvm-readobj / llvm-objdump（VS の LLVM が PATH に入る環境で Git Bash からも安定）。
# dumpbin は同環境でリダイレクト時に異常終了することがあるためフォールバックに回す。
set -euo pipefail

DLL="${1:-zig-out/windows-x86_64/libpict.dll}"

if [[ ! -f "$DLL" ]]; then
  echo "error: DLL not found: $DLL" >&2
  exit 1
fi

tmpdir="${TMPDIR:-/tmp}"
exports_txt="${tmpdir}/libpict-exports-$$.txt"
deps_txt="${tmpdir}/libpict-deps-$$.txt"
trap 'rm -f "$exports_txt" "$deps_txt"' EXIT

use_llvm=false
if command -v llvm-readobj >/dev/null 2>&1 && command -v llvm-objdump >/dev/null 2>&1; then
  use_llvm=true
fi

if [[ "$use_llvm" == true ]]; then
  llvm-readobj --coff-exports "$DLL" >"$exports_txt"
  llvm-objdump -p "$DLL" >"$deps_txt"
else
  if ! command -v dumpbin >/dev/null 2>&1; then
    echo "error: need llvm-readobj+llvm-objdump (VS LLVM) or dumpbin in PATH" >&2
    exit 1
  fi
  # Git Bash では dumpbin のリダイレクトが不安定なことがあるため、失敗時は LLVM を促す
  if ! dumpbin /exports "$DLL" >"$exports_txt" 2>"${exports_txt}.err"; then
    echo "error: dumpbin /exports failed (try VS LLVM tools on PATH). stderr:" >&2
    cat "${exports_txt}.err" >&2
    exit 1
  fi
  rm -f "${exports_txt}.err"
  if ! dumpbin /dependents "$DLL" >"$deps_txt" 2>"${deps_txt}.err"; then
    echo "error: dumpbin /dependents failed. stderr:" >&2
    cat "${deps_txt}.err" >&2
    exit 1
  fi
  rm -f "${deps_txt}.err"
fi

required_exports=(
  pict_decode_v2
  pict_decode_v3
  pict_resize
  pict_encode_webp_v2
  pict_encode_avif
  pict_free_buffer
)

if [[ "$use_llvm" == true ]]; then
  echo "=== Required exports (llvm-readobj --coff-exports) ==="
else
  echo "=== Required exports (dumpbin /exports) ==="
fi
for sym in "${required_exports[@]}"; do
  if ! grep -q "$sym" "$exports_txt"; then
    echo "error: missing export symbol: $sym" >&2
    echo "--- exports dump (full) ---" >&2
    cat "$exports_txt" >&2
    exit 1
  fi
  echo "ok: $sym"
done

echo ""
if [[ "$use_llvm" == true ]]; then
  echo "=== Import DLL names (llvm-objdump -p, DLL Name lines) ==="
  grep -F "DLL Name:" "$deps_txt" || true
else
  echo "=== Dynamic dependents (dumpbin /dependents) ==="
  cat "$deps_txt"
fi

# 静的リンク想定: libavif / libaom / dav1d を別 DLL として引いていないこと
if grep -qiE '(^|[[:space:]])(lib)?avif[^[:space:]]*\.dll|libaom[^[:space:]]*\.dll|(^|[[:space:]])aom\.dll|dav1d[^[:space:]]*\.dll' "$deps_txt"; then
  echo "error: unexpected dynamic dependency on avif/aom/dav1d DLL (expected statically linked stack)" >&2
  echo "--- dependency dump tail ---" >&2
  tail -n 80 "$deps_txt" >&2
  exit 1
fi

echo ""
echo "ci-verify-libpict-windows.sh: OK"
