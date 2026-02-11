#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-teams"

TMP_DIR="$(mktemp -d)"
REPO="$TMP_DIR/repo"
FAKE_BIN="$TMP_DIR/fake-bin"

cleanup() {
  if [[ -d "$REPO" ]]; then
    PATH="$FAKE_BIN:$PATH" \
      "$CLI" --repo "$REPO" task stop --all --apply --reason "smoke complete cleanup" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main

cat > "$REPO/README.md" <<'EOF'
# Complete Flow Repo
EOF

cp -R "$ROOT/scripts" "$REPO/"
rm -rf "$REPO/scripts/py/__pycache__"

git -C "$REPO" add README.md
git -C "$REPO" add scripts
git -C "$REPO" commit -q -m "chore: initial"

mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "exec" ]] || exit 2
while true; do sleep 5; done
EOF
chmod +x "$FAKE_BIN/codex"

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

RUN_OUT="$($CLI --repo "$REPO" run start --no-launch --trigger smoke-complete-initial)"
echo "$RUN_OUT"

echo "$RUN_OUT" | grep -q "Started tasks: 1"

echo "$RUN_OUT" | grep -q "T1-002 .*reason=deps_not_ready"

WT_A="$TMP_DIR/repo-worktrees/repo-agenta-t1-001"
if [[ ! -d "$WT_A" ]]; then
  echo "missing AgentA worktree: $WT_A"
  exit 1
fi
WORKTREE_CLI="$WT_A/scripts/codex-teams"
if [[ ! -x "$WORKTREE_CLI" ]]; then
  echo "missing worktree-local codex-teams CLI: $WORKTREE_CLI"
  exit 1
fi

# Simulate implementation commit on task branch before completion.
echo "done" > "$WT_A/agent-output.txt"
git -C "$WT_A" add agent-output.txt
git -C "$WT_A" commit -q -m "feat: complete T1-001"
"$WORKTREE_CLI" --repo "$WT_A" --state-dir "$REPO/.state" task update AgentA T1-001 DONE "smoke complete"
git -C "$WT_A" add TODO.md
git -C "$WT_A" commit -q -m "chore: mark T1-001 done"

COMPLETE_OUT="$(PATH="$FAKE_BIN:$PATH" "$WORKTREE_CLI" --repo "$WT_A" --state-dir "$REPO/.state" task complete AgentA app-shell T1-001 --summary "smoke complete" --trigger smoke-complete-next)"
echo "$COMPLETE_OUT"

echo "$COMPLETE_OUT" | grep -q "Completion prerequisites satisfied"
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

echo "$STATUS_OUT" | grep -q "\[EXCLUDED\] T1-002 owner=AgentB reason=active_worker source=pid"
echo "$STATUS_OUT" | grep -q "Runtime: total=1 active=1 stale=0"

PID_META="$REPO/.state/orchestrator/t1-002.pid"
if [[ ! -f "$PID_META" ]]; then
  echo "missing pid metadata for auto-started task: $PID_META"
  exit 1
fi

PID="$(awk -F'=' '$1=="pid"{print $2}' "$PID_META" | tr -d '[:space:]')"
if [[ ! "$PID" =~ ^[0-9]+$ ]]; then
  echo "invalid pid for auto-started task: $PID"
  exit 1
fi

if ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "auto-started worker pid is not alive: $PID"
  exit 1
fi

grep -q "| T1-001 | App shell bootstrap | AgentA | - | seed | DONE |" "$REPO/TODO.md"

LAST_SUBJECT="$(git -C "$REPO" log -1 --pretty=%s)"
echo "$LAST_SUBJECT" | grep -q "chore: mark T1-001 done"
if git -C "$REPO" log --pretty=%s | grep -q '^task(T1-001):'; then
  echo "task complete should not create auto-commit subject: task(T1-001): ..."
  exit 1
fi

echo "task complete auto run-start smoke test passed"
