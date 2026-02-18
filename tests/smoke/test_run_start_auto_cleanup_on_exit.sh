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
      "$CLI" --repo "$REPO" task stop --all --apply --reason "auto cleanup smoke cleanup" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$REPO" "$FAKE_BIN"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main

cat > "$REPO/README.md" <<'EOF'
# Auto Cleanup Repo
EOF
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: init"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "exec" ]] || exit 2
sleep 1
exit 0
EOF
chmod +x "$FAKE_BIN/codex"

"$CLI" --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T9-301 | auto cleanup | AgentA | - | watcher cleanup | TODO |
EOF
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"
"$CLI" --repo "$REPO" task scaffold-specs
git -C "$REPO" add tasks/specs
git -C "$REPO" commit -q -m "chore: scaffold task specs"

RUN_OUT="$(PATH="$FAKE_BIN:$PATH" "$CLI" --repo "$REPO" run start --trigger smoke-auto-cleanup --max-start 1)"
echo "$RUN_OUT"
echo "$RUN_OUT" | grep -q "Started tasks: 1"

PID_META="$REPO/.state/orchestrator/t9-301.pid"
LOCK_FILE="$REPO/.state/locks/app-shell.lock"
WT_PATH="$TMP_DIR/repo-worktrees/repo-agenta-t9-301"
BRANCH_NAME="codex/agenta-t9-301"

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  pid_missing=0
  lock_missing=0
  wt_missing=0
  branch_missing=0

  [[ ! -f "$PID_META" ]] && pid_missing=1
  [[ ! -f "$LOCK_FILE" ]] && lock_missing=1
  [[ ! -d "$WT_PATH" ]] && wt_missing=1
  if ! git -C "$REPO" rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    branch_missing=1
  fi

  if [[ "$pid_missing" -eq 1 && "$lock_missing" -eq 1 && "$wt_missing" -eq 1 && "$branch_missing" -eq 1 ]]; then
    break
  fi
  sleep 1
done

if [[ -f "$PID_META" ]]; then
  echo "pid metadata should be cleaned after worker exit: $PID_META"
  exit 1
fi
if [[ -f "$LOCK_FILE" ]]; then
  echo "lock file should be cleaned after worker exit: $LOCK_FILE"
  exit 1
fi
if [[ -d "$WT_PATH" ]]; then
  echo "worktree should be removed after worker exit: $WT_PATH"
  exit 1
fi
if git -C "$REPO" rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
  echo "branch should be removed after worker exit: $BRANCH_NAME"
  exit 1
fi

grep -q "| T9-301 | auto cleanup | AgentA | - | watcher cleanup | TODO |" "$REPO/TODO.md"
grep -q "Stopped by codex-teams: worker exited (backend=tmux)" "$REPO/.state/LATEST_UPDATES.md"

echo "run start auto cleanup on exit smoke test passed"
