#!/usr/bin/env bash
# scripts/fetch-wasm-artifact.sh
#
# GitHub Actions の artifact「zigpix-wasm-dist」を取得し、wasm/dist/ に展開する。
# その後: cd wasm && npm test && npm publish
#
# 前提: gh CLI が認証済み。リポジトリルート（または wasm/）から実行してよい。
#
# Usage:
#   bash scripts/fetch-wasm-artifact.sh RUN_ID
#   RUN_ID は gh run list --workflow=build-wasm.yml の databaseId

set -euo pipefail

RUN_ID="${1:?usage: bash scripts/fetch-wasm-artifact.sh <run_id>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$REPO_ROOT/wasm/dist"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$REPO_ROOT"

echo "[fetch-wasm-artifact] downloading run $RUN_ID artifact zigpix-wasm-dist ..."
gh run download "$RUN_ID" -n zigpix-wasm-dist -D "$TMP"

# artifact の zip 構造は環境でずれることがあるため、avif.js を探して親を SRC にする
AVIF_JS="$(find "$TMP" -name avif.js -type f ! -path '*/node_modules/*' | head -1)"
if [[ -z "$AVIF_JS" ]]; then
  echo "[fetch-wasm-artifact] ERROR: avif.js not found under $TMP" >&2
  find "$TMP" -type f | head -40 >&2 || true
  exit 1
fi

SRC="$(dirname "$AVIF_JS")"
echo "[fetch-wasm-artifact] using source dir: $SRC"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SRC"/* "$DEST/"

echo "[fetch-wasm-artifact] OK — contents of wasm/dist:"
ls -la "$DEST"
