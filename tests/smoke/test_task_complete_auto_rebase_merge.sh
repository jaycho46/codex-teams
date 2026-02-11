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
# Auto Rebase Merge Repo
EOF
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: init"

"$CLI" --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T6-001 | Rebase merge task | AgentA | - | auto rebase merge | TODO |
EOF
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"

RUN_OUT="$("$CLI" --repo "$REPO" run start --no-launch --trigger smoke-auto-rebase --max-start 1)"
echo "$RUN_OUT"
echo "$RUN_OUT" | grep -q "Started tasks: 1"

WT="$TMP_DIR/repo-worktrees/repo-agenta-t6-001"
if [[ ! -d "$WT" ]]; then
  echo "missing worktree: $WT"
  exit 1
fi

# Advance main after task worktree starts to force non-ff merge condition.
echo "main advanced" > "$REPO/main-advance.txt"
git -C "$REPO" add main-advance.txt
git -C "$REPO" commit -q -m "chore: advance main during task"

COMPLETE_OUT="$("$CLI" --repo "$WT" --state-dir "$REPO/.state" task complete AgentA app-shell T6-001 --summary "auto rebase merge" --no-run-start)"
echo "$COMPLETE_OUT"
echo "$COMPLETE_OUT" | grep -q "Fast-forward merge failed, attempting auto-rebase"
echo "$COMPLETE_OUT" | grep -q "Merged branch into primary after auto-rebase"

test -f "$REPO/main-advance.txt"
grep -q "| T6-001 | Rebase merge task | AgentA | - | auto rebase merge | DONE |" "$REPO/TODO.md"

LAST_SUBJECT="$(git -C "$REPO" log -1 --pretty=%s)"
echo "$LAST_SUBJECT" | grep -q "task(T6-001): auto rebase merge"

if [[ -d "$WT" ]]; then
  echo "completed worktree should be removed: $WT"
  exit 1
fi

STATUS_OUT="$("$CLI" --repo "$REPO" status --trigger smoke-auto-rebase)"
echo "$STATUS_OUT"
echo "$STATUS_OUT" | grep -q "Runtime: total=0 active=0 stale=0"
echo "$STATUS_OUT" | grep -q "Coordination: locks=0"

echo "task complete auto-rebase merge smoke test passed"
