#!/usr/bin/env bash
# CI / 手元 (MSVC 開発者コマンド + Git Bash): libpict.dll の exports と動的依存を検証する。
# 使い方: bash scripts/ci-verify-libpict-windows.sh [path/to/libpict.dll]
set -euo pipefail

DLL="${1:-zig-out/windows-x86_64/libpict.dll}"

if ! command -v dumpbin >/dev/null 2>&1; then
  echo "error: dumpbin not in PATH (use MSVC x64 dev environment or ilammy/msvc-dev-cmd in CI)" >&2
  exit 1
fi

if [[ ! -f "$DLL" ]]; then
  echo "error: DLL not found: $DLL" >&2
  exit 1
fi

tmpdir="${TMPDIR:-/tmp}"
exports_txt="${tmpdir}/libpict-exports-$$.txt"
deps_txt="${tmpdir}/libpict-deps-$$.txt"
trap 'rm -f "$exports_txt" "$deps_txt"' EXIT

dumpbin /exports "$DLL" >"$exports_txt"
dumpbin /dependents "$DLL" >"$deps_txt"

required_exports=(
  pict_decode_v2
  pict_decode_v3
  pict_resize
  pict_encode_webp_v2
  pict_encode_avif
  pict_free_buffer
)

echo "=== Required exports (dumpbin /exports) ==="
for sym in "${required_exports[@]}"; do
  if ! grep -q "$sym" "$exports_txt"; then
    echo "error: missing export symbol: $sym" >&2
    echo "--- dumpbin /exports (full) ---" >&2
    cat "$exports_txt" >&2
    exit 1
  fi
  echo "ok: $sym"
done

echo ""
echo "=== Dynamic dependents (dumpbin /dependents) ==="
cat "$deps_txt"

# 静的リンク想定: libavif / libaom / dav1d を別 DLL として引いていないこと
if grep -qiE '(^|[[:space:]])(lib)?avif[^[:space:]]*\.dll|libaom[^[:space:]]*\.dll|(^|[[:space:]])aom\.dll|dav1d[^[:space:]]*\.dll' "$deps_txt"; then
  echo "error: unexpected dynamic dependency on avif/aom/dav1d DLL (expected statically linked stack)" >&2
  exit 1
fi

echo ""
echo "ci-verify-libpict-windows.sh: OK"
