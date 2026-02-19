#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-tasks"

TMP_DIR="$(mktemp -d)"
REPO="$TMP_DIR/repo"

cleanup() {
  if [[ -d "$REPO" ]]; then
    "$CLI" --repo "$REPO" task stop --all --apply --reason "done guard cleanup" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main

cat > "$REPO/README.md" <<'EOF'
# Done Guard Repo
EOF
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: init"

"$CLI" --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T9-401 | done guard | AgentA | - | preserve done | TODO |
EOF
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"
"$CLI" --repo "$REPO" task scaffold-specs
git -C "$REPO" add tasks/specs
git -C "$REPO" commit -q -m "chore: scaffold task specs"

RUN_OUT="$("$CLI" --repo "$REPO" run start --no-launch --trigger smoke-done-guard --max-start 1)"
echo "$RUN_OUT"
echo "$RUN_OUT" | grep -q "Started tasks: 1"

WT_PATH="$TMP_DIR/repo-worktrees/repo-agenta-t9-401"
if [[ ! -d "$WT_PATH" ]]; then
  echo "missing worktree: $WT_PATH"
  exit 1
fi

awk -F'|' '
  BEGIN { OFS="|"; found=0 }
  {
    if ($0 ~ /^\|/) {
      id=$2
      gsub(/^[ \t]+|[ \t]+$/, "", id)
      if (id == "T9-401") {
        $(NF-1) = " DONE "
        found=1
      }
    }
    print
  }
  END {
    if (!found) exit 42
  }
' "$REPO/TODO.md" > "$REPO/TODO.md.tmp"
mv "$REPO/TODO.md.tmp" "$REPO/TODO.md"
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: mark T9-401 done in primary"

PID_META="$REPO/.state/orchestrator/t9-401.pid"
cat > "$PID_META" <<EOF
pid=999991
task_id=T9-401
owner=AgentA
scope=app-shell
worktree=$WT_PATH
started_at=2026-01-01T00:00:00Z
launch_backend=tmux
launch_label=N/A
tmux_session=N/A
log_file=/tmp/non-existent.log
trigger=smoke
EOF

AUTO_OUT="$("$CLI" --repo "$REPO" task auto-cleanup-exit T9-401 999991 --reason "done guard check")"
echo "$AUTO_OUT"
echo "$AUTO_OUT" | grep -q "task-auto-cleanup-exit"
echo "$AUTO_OUT" | grep -q "TODO rollback skipped: task status is DONE"

LOCK_FILE="$REPO/.state/locks/app-shell.lock"
if [[ -f "$LOCK_FILE" ]]; then
  echo "lock should be removed by auto-cleanup: $LOCK_FILE"
  exit 1
fi
if [[ -f "$PID_META" ]]; then
  echo "pid metadata should be removed by auto-cleanup: $PID_META"
  exit 1
fi
if [[ -d "$WT_PATH" ]]; then
  echo "worktree should be removed by auto-cleanup: $WT_PATH"
  exit 1
fi
if git -C "$REPO" rev-parse --verify "codex/agenta-t9-401" >/dev/null 2>&1; then
  echo "branch should be removed by auto-cleanup: codex/agenta-t9-401"
  exit 1
fi

grep -q "| T9-401 | done guard | AgentA | - | preserve done | DONE |" "$REPO/TODO.md"

echo "auto cleanup done guard smoke test passed"
