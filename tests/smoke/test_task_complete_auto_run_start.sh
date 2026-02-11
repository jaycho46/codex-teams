#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-teams"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main

cat > "$REPO/README.md" <<'EOF'
# Complete Flow Repo
EOF

git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: initial"

$CLI --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T1-001 | App shell bootstrap | AgentA | - | seed | TODO |
| T1-002 | Domain core service | AgentB | T1-001 | wait T1-001 | TODO |
EOF

git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"

RUN_OUT="$($CLI --repo "$REPO" run start --trigger smoke-complete-initial)"
echo "$RUN_OUT"

echo "$RUN_OUT" | grep -q "Started tasks: 1"

echo "$RUN_OUT" | grep -q "T1-002 .*reason=deps_not_ready"

WT_A="$TMP_DIR/repo-worktrees/repo-agenta-t1-001"
if [[ ! -d "$WT_A" ]]; then
  echo "missing AgentA worktree: $WT_A"
  exit 1
fi

# Simulate implementation commit on task branch before completion.
echo "done" > "$WT_A/agent-output.txt"
git -C "$WT_A" add agent-output.txt
git -C "$WT_A" commit -q -m "feat: complete T1-001"

COMPLETE_OUT="$($CLI --repo "$WT_A" --state-dir "$REPO/.state" task complete AgentA app-shell T1-001 --summary "smoke complete" --trigger smoke-complete-next)"
echo "$COMPLETE_OUT"

echo "$COMPLETE_OUT" | grep -q "Marked task DONE"
echo "$COMPLETE_OUT" | grep -q "Merged branch into primary"
echo "$COMPLETE_OUT" | grep -q "Triggering scheduler after completion"

# Completed worktree should be removed.
if [[ -d "$WT_A" ]]; then
  echo "completed worktree should be removed: $WT_A"
  exit 1
fi

# Auto-triggered run start should start T1-002.
STATUS_OUT="$($CLI --repo "$REPO" status --trigger smoke-complete-next)"
echo "$STATUS_OUT"

echo "$STATUS_OUT" | grep -q "\[EXCLUDED\] T1-002 owner=AgentB reason=active_lock source=lock"
echo "$STATUS_OUT" | grep -q "Runtime: total=1 active=1 stale=0"

grep -q "| T1-001 | App shell bootstrap | AgentA | - | seed | DONE |" "$REPO/TODO.md"

echo "task complete auto run-start smoke test passed"
