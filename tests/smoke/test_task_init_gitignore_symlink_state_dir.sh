#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-tasks"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

ln -s "$TMP_DIR" "$TMP_DIR/link-root"
STATE_DIR_LINK="$TMP_DIR/link-root/repo/.state"

OUT="$($CLI --repo "$REPO" --state-dir "$STATE_DIR_LINK" init --gitignore yes)"
echo "$OUT"

echo "$OUT" | grep -q "Added state path to .gitignore: .state/"
if echo "$OUT" | grep -q "outside repository"; then
  echo "state dir symlink path should be treated as repository-internal"
  exit 1
fi

grep -qxF ".state/" "$REPO/.gitignore"

echo "task init symlink state dir smoke test passed"
