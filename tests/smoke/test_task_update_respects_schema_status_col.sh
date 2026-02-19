#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-tasks"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Status | Notes |
|---|---|---|---|---|---|
| T1-001 | Schema status task | AgentA | - | TODO | keep note |
EOF

mkdir -p "$REPO/.state"
cat > "$REPO/.state/orchestrator.toml" <<'EOF'
[todo]
status_col = 6
EOF

git -C "$REPO" add TODO.md .state/orchestrator.toml
git -C "$REPO" commit -q -m "seed"

BASE_BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
WT_PARENT="$TMP_DIR/repo-worktrees"
WT="$WT_PARENT/repo-agenta-t1-001"
git -C "$REPO" worktree add -q -b codex/agenta-t1-001 "$WT" "$BASE_BRANCH"

OUT="$($CLI --repo "$WT" --state-dir "$REPO/.state" --config "$REPO/.state/orchestrator.toml" task update AgentA T1-001 IN_PROGRESS 'schema status update')"
echo "$OUT"
echo "$OUT" | grep -q "Update logged: task=T1-001 status=IN_PROGRESS"

grep -q "| T1-001 | Schema status task | AgentA | - | IN_PROGRESS | keep note |" "$REPO/TODO.md"

if grep -q "| T1-001 | Schema status task | AgentA | - | TODO | IN_PROGRESS |" "$REPO/TODO.md"; then
  echo "status update wrote to the wrong column"
  exit 1
fi

echo "task update schema status column smoke test passed"
