#!/bin/sh
# vendor-update.sh — vendor submodule を指定バージョンに更新する
#
# 使い方:
#   ./scripts/vendor-update.sh              # 全ライブラリを docs/deps.md の最新タグに更新
#   ./scripts/vendor-update.sh libjpeg-turbo 3.1.0  # 特定ライブラリを指定タグに更新
#
# 更新後: docs/deps.md のコミットハッシュを手動で更新して git commit すること。

set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# submodule が初期化されていなければ初期化
git submodule update --init --recursive

update_lib() {
  local name="$1"
  local tag="$2"
  echo "→ Updating vendor/$name to $tag ..."
  git -C "vendor/$name" fetch --depth 1 origin "$tag"
  git -C "vendor/$name" checkout FETCH_HEAD
  local commit
  commit=$(git -C "vendor/$name" rev-parse --short HEAD)
  echo "  vendor/$name pinned to $commit ($tag)"
}

if [ $# -eq 2 ]; then
  # 引数指定: 特定ライブラリのみ更新
  update_lib "$1" "$2"
else
  # 全ライブラリを現行タグで更新 (主に CI での再現用)
  update_lib libjpeg-turbo 3.0.4
  update_lib zlib          v1.3.1
  update_lib libpng        v1.6.43
  update_lib libwebp       v1.4.0
fi

echo ""
echo "Done. Update docs/deps.md commit hashes if versions changed, then:"
echo "  git add .gitmodules vendor/ docs/deps.md"
echo "  git commit -m 'vendor: update <library> to <version>'"
