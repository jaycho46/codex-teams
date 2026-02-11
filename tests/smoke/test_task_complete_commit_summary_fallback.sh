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
# Complete No Auto Commit Repo
EOF
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: init"

"$CLI" --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T7-001 | Meaningful summary title | AgentA | - | summary fallback check | TODO |
EOF
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"

RUN_OUT="$("$CLI" --repo "$REPO" run start --no-launch --trigger smoke-summary-fallback --max-start 1)"
echo "$RUN_OUT"
echo "$RUN_OUT" | grep -q "Started tasks: 1"

WT="$TMP_DIR/repo-worktrees/repo-agenta-t7-001"
if [[ ! -d "$WT" ]]; then
  echo "missing worktree: $WT"
  exit 1
fi

echo "done" > "$WT/agent-output.txt"
git -C "$WT" add agent-output.txt
git -C "$WT" commit -q -m "feat: complete T7-001"
"$CLI" --repo "$WT" --state-dir "$REPO/.state" task update AgentA T7-001 DONE "Meaningful summary title"
git -C "$WT" add TODO.md
git -C "$WT" commit -q -m "chore: mark T7-001 done"

COMPLETE_OUT="$("$CLI" --repo "$WT" --state-dir "$REPO/.state" task complete AgentA app-shell T7-001 --no-run-start)"
echo "$COMPLETE_OUT"
echo "$COMPLETE_OUT" | grep -q "Task completion flow finished: task=T7-001"

LAST_SUBJECT="$(git -C "$REPO" log -1 --pretty=%s)"
echo "$LAST_SUBJECT"

echo "$LAST_SUBJECT" | grep -q "chore: mark T7-001 done"
if git -C "$REPO" log --pretty=%s | grep -q '^task(T7-001):'; then
  echo "task complete should not create auto-commit subject: task(T7-001): ..."
  exit 1
fi

grep -q "| T7-001 | Meaningful summary title | AgentA | - | summary fallback check | DONE |" "$REPO/TODO.md"

echo "task complete no-auto-commit smoke test passed"
