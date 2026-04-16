#!/usr/bin/env bash
# Visual Studio ジェネレータ（マルチコンフィグ）では avif.lib / aom.lib が lib/Release/ 等に
# 置かれ、build.zig の固定パス（.../lib/avif.lib と .../libaom-build/aom.lib）とずれる。
# Ninja 単一コンフィグでは通常ずれない。CI の libavif 手順の直後に実行する。
set -euo pipefail

ROOT="${1:-.}"
INST="${ROOT}/build/libavif-install"
DEPS="${ROOT}/build/libavif/_deps/libaom-build"

mkdir -p "${INST}/lib" "${DEPS}"

find_one() {
  local dir="$1"
  local name="$2"
  # Git Bash / GNU find 想定
  find "${dir}" -name "${name}" 2>/dev/null | head -n 1 || true
}

# ── avif.lib → build/libavif-install/lib/avif.lib
if [[ -f "${INST}/lib/avif.lib" ]]; then
  echo "ok: ${INST}/lib/avif.lib (already flat)"
else
  found="$(find_one "${INST}" "avif.lib")"
  if [[ -z "${found}" ]]; then
    echo "error: avif.lib not found under ${INST}" >&2
    find "${INST}" -name "*.lib" 2>/dev/null || true
    exit 1
  fi
  cp "${found}" "${INST}/lib/avif.lib"
  echo "normalized: ${found} -> ${INST}/lib/avif.lib"
fi

# ── aom.lib → build/libavif/_deps/libaom-build/aom.lib
if [[ -f "${DEPS}/aom.lib" ]]; then
  echo "ok: ${DEPS}/aom.lib (already flat)"
else
  found="$(find_one "${DEPS}" "aom.lib")"
  if [[ -z "${found}" ]]; then
    echo "error: aom.lib not found under ${DEPS}" >&2
    find "${DEPS}" -name "*.lib" 2>/dev/null || true
    exit 1
  fi
  cp "${found}" "${DEPS}/aom.lib"
  echo "normalized: ${found} -> ${DEPS}/aom.lib"
fi
