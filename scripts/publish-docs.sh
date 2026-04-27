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
DOCC_BUNDLE="$REPO_ROOT/Sources/Cambium/Cambium.docc"
BUNDLE_NAME="Cambium"
BUNDLE_ID="org.cambium.Cambium"
BUNDLE_VERSION="0.1.0"
HOSTING_BASE_PATH="cambium"
BRANCH="gh-pages"
SYMBOLGRAPH_DIR="$REPO_ROOT/.build/symbolgraph"
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

echo "==> Building package with symbol-graph emission"
RAW_SYMGRAPH_DIR="$REPO_ROOT/.build/symbolgraph-raw"
rm -rf "$RAW_SYMGRAPH_DIR" "$SYMBOLGRAPH_DIR"
mkdir -p "$RAW_SYMGRAPH_DIR" "$SYMBOLGRAPH_DIR"
swift build \
  -Xswiftc -emit-extension-block-symbols \
  -Xswiftc -emit-symbol-graph \
  -Xswiftc -emit-symbol-graph-dir -Xswiftc "$RAW_SYMGRAPH_DIR"

echo "==> Filtering to Cambium* symbol graphs"
# Only keep our own modules — exclude swift-syntax and other deps.
shopt -s nullglob
for f in "$RAW_SYMGRAPH_DIR"/Cambium*.symbols.json; do
  case "$(basename "$f")" in
    CambiumSyntaxMacrosPlugin*) continue ;;  # internal macro plugin
  esac
  cp "$f" "$SYMBOLGRAPH_DIR/"
done
shopt -u nullglob

echo "==> Converting Cambium.docc with all symbol graphs"
xcrun docc convert "$DOCC_BUNDLE" \
  --fallback-display-name "$BUNDLE_NAME" \
  --fallback-bundle-identifier "$BUNDLE_ID" \
  --fallback-bundle-version "$BUNDLE_VERSION" \
  --additional-symbol-graph-dir "$SYMBOLGRAPH_DIR" \
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
