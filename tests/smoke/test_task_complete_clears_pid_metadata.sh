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
# Complete PID Cleanup Repo
EOF
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: init"

"$CLI" --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T3-001 | Finish task | AgentA | - | complete path | TODO |
EOF
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"

RUN_OUT="$("$CLI" --repo "$REPO" run start --no-launch --trigger smoke-complete-pid --max-start 1)"
echo "$RUN_OUT"
echo "$RUN_OUT" | grep -q "Started tasks: 1"

WT="$TMP_DIR/repo-worktrees/repo-agenta-t3-001"
if [[ ! -d "$WT" ]]; then
  echo "missing worktree: $WT"
  exit 1
fi

echo "done" > "$WT/agent-output.txt"
git -C "$WT" add agent-output.txt
git -C "$WT" commit -q -m "feat: complete T3-001"
"$CLI" --repo "$WT" --state-dir "$REPO/.state" task update AgentA T3-001 DONE "done"
git -C "$WT" add TODO.md
git -C "$WT" commit -q -m "chore: mark T3-001 done"

PID_META="$REPO/.state/orchestrator/t3-001.pid"
cat > "$PID_META" <<'EOF'
pid=999999
task_id=T3-001
owner=AgentA
scope=app-shell
worktree=/tmp/non-existent
started_at=2026-01-01T00:00:00Z
launch_backend=codex_exec
launch_label=N/A
tmux_session=N/A
log_file=/tmp/non-existent.log
trigger=smoke
EOF

if [[ ! -f "$PID_META" ]]; then
  echo "failed to seed pid metadata"
  exit 1
fi

COMPLETE_OUT="$("$CLI" --repo "$WT" --state-dir "$REPO/.state" task complete AgentA app-shell T3-001 --summary \"done\" --no-run-start)"
echo "$COMPLETE_OUT"
echo "$COMPLETE_OUT" | grep -q "Task completion flow finished: task=T3-001"
echo "$COMPLETE_OUT" | grep -q "Removed pid metadata for task=T3-001"

if [[ -f "$PID_META" ]]; then
  echo "pid metadata should be removed on task completion: $PID_META"
  exit 1
fi

STATUS_OUT="$("$CLI" --repo "$REPO" status --trigger smoke-complete-pid)"
echo "$STATUS_OUT"
echo "$STATUS_OUT" | grep -q "Runtime: total=0 active=0 stale=0"

grep -q "| T3-001 | Finish task | AgentA | - | complete path | DONE |" "$REPO/TODO.md"

echo "task complete clears pid metadata smoke test passed"
