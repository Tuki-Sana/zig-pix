#!/usr/bin/env bash
# scripts/mem-peak.sh — zigpix FFI / ベンチのピーク RSS（GNU time -v）
#
# 前提:
#   - Linux: /usr/bin/time -v が使える（util-linux / GNU time）
#   - macOS: brew install gnu-time → gtime が PATH にあること
#
# 使い方（リポジトリルート）:
#   zig build lib
#   bash scripts/mem-peak.sh
#
# 出力末尾の "Maximum resident set size (kbytes):" がピーク RSS。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pick_gnu_time() {
  if [[ "$(uname -s)" == "Linux" ]]; then
    if /usr/bin/time -v /usr/bin/true 2>&1 | grep -Fq "Maximum resident set size"; then
      echo "/usr/bin/time -v"
      return 0
    fi
  fi
  if command -v gtime >/dev/null 2>&1 && gtime -v /usr/bin/true 2>&1 | grep -Fq "Maximum resident set size"; then
    echo "gtime -v"
    return 0
  fi
  return 1
}

# mktemp -t は ':' や空白を含むと失敗するため、テンプレート用に安全な文字列へ
mktemp_for_label() {
  local raw="$1"
  local safe
  safe="$(printf '%s' "$raw" | tr -c 'a-zA-Z0-9._-' '_' | cut -c1-48)"
  [[ -n "$safe" ]] || safe="run"
  mktemp -t "zigpix-mem-${safe}.XXXXXX"
}

TIME_PREFIX="$(pick_gnu_time)" || {
  echo "ERROR: GNU time (-v) が見つかりません。"
  echo "  Linux: apt install time  などで /usr/bin/time -v を用意"
  echo "  macOS: brew install gnu-time  → gtime を PATH に"
  exit 1
}

# shellcheck disable=SC2206
TIME_ARR=(${TIME_PREFIX})

ensure_lib() {
  if [[ -f zig-out/lib/libpict.dylib ]] || [[ -f zig-out/lib/libpict.so ]]; then
    return 0
  fi
  echo "zig-out/lib/libpict.* が無いため zig build lib を実行します…"
  zig build lib
}

extract_stats() {
  local log="$1"
  echo ""
  echo "--- サマリ（$log）---"
  grep -E "Maximum resident set size|Elapsed \(wall clock\) time|User time|System time" "$log" 2>/dev/null || true
}

run_one() {
  local name="$1"
  shift
  local log
  log="$(mktemp_for_label "$name")"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " ${name}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  "${TIME_ARR[@]}" "$@" 2>&1 | tee "$log"
  extract_stats "$log"
  rm -f "$log"
}

ensure_lib

run_one "FFI: bun test/ffi/test.ts" bun run test/ffi/test.ts

if [[ -f node_modules/sharp/package.json ]]; then
  run_one "Bench: npx tsx bench/bench.ts" npx tsx bench/bench.ts
else
  echo ""
  echo "（スキップ）bench/bench.ts — node_modules/sharp がありません。"
  echo "  計測する場合: npm install && npm install sharp"
fi

echo ""
echo "完了。README の「メモリ（ピーク RSS）」表に Maximum resident の値を転記してください。"
