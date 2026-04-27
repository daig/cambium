#!/usr/bin/env bash
# Build DocC for the Cambium target and publish to the gh-pages branch.
#
# Prereqs (one-time):
#   - swift-docc-plugin is in Package.swift dependencies
#   - In GitHub repo settings: Pages → Source = "Deploy from a branch", branch = gh-pages, folder = /
#
# After running this, docs land at:
#   https://daig.github.io/cambium/documentation/cambium/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGETS=(
  Cambium
  CambiumCore
  CambiumBuilder
  CambiumIncremental
  CambiumAnalysis
  CambiumASTSupport
  CambiumOwnedTraversal
  CambiumSerialization
  CambiumTesting
  CambiumSyntaxMacros
)
HOSTING_BASE_PATH="cambium"
BRANCH="gh-pages"
BUILD_DIR="$(mktemp -d)"
WORKTREE_DIR="$(mktemp -d)"

cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_DIR" 2>/dev/null || true
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash before publishing docs." >&2
  exit 1
fi

SOURCE_SHA="$(git rev-parse --short HEAD)"

echo "==> Building combined DocC for ${TARGETS[*]}"
TARGET_ARGS=()
for t in "${TARGETS[@]}"; do
  TARGET_ARGS+=(--target "$t")
done
swift package \
  --allow-writing-to-directory "$BUILD_DIR" \
  generate-documentation \
  "${TARGET_ARGS[@]}" \
  --enable-experimental-combined-documentation \
  --disable-indexing \
  --transform-for-static-hosting \
  --hosting-base-path "$HOSTING_BASE_PATH" \
  --output-path "$BUILD_DIR"

echo "==> Preparing $BRANCH worktree"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git worktree add "$WORKTREE_DIR" "$BRANCH"
else
  git worktree add --no-checkout "$WORKTREE_DIR" --detach
  git -C "$WORKTREE_DIR" checkout --orphan "$BRANCH"
  git -C "$WORKTREE_DIR" rm -rf . 2>/dev/null || true
fi

echo "==> Syncing built docs into worktree"
# Wipe existing contents (preserve .git) then copy fresh build.
find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
cp -R "$BUILD_DIR"/. "$WORKTREE_DIR"/
# Tell GitHub Pages not to run Jekyll on this content.
touch "$WORKTREE_DIR/.nojekyll"

cd "$WORKTREE_DIR"
git add -A
if git diff --cached --quiet; then
  echo "==> No documentation changes; nothing to publish."
  exit 0
fi
git commit -m "Publish DocC @ $SOURCE_SHA"
git push origin "$BRANCH"

echo "==> Done. Live at: https://daig.github.io/${HOSTING_BASE_PATH}/documentation/cambium/"
