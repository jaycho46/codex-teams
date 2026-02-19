#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-tasks"

TMP_DIR="$(mktemp -d)"
REPO="$TMP_DIR/repo"
FAKE_BIN="$TMP_DIR/fake-bin"

cleanup() {
  if [[ -d "$REPO" ]]; then
    PATH="$FAKE_BIN:$PATH" \
      "$CLI" --repo "$REPO" task stop --all --apply --reason "smoke rollback cleanup" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$REPO" "$FAKE_BIN"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main

cat > "$REPO/README.md" <<'EOF'
# Rollback Kill Repo
EOF
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: init"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "exec" ]] || exit 2
while true; do sleep 5; done
EOF
chmod +x "$FAKE_BIN/codex"

"$CLI" --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T8-009 | Rollback kill check | AgentA | - | force pid-meta write error | TODO |
EOF
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"
"$CLI" --repo "$REPO" task scaffold-specs
git -C "$REPO" add tasks/specs
git -C "$REPO" commit -q -m "chore: scaffold task specs"

# Force launch metadata write failure after codex is spawned.
mkdir -p "$REPO/.state/orchestrator/t8-009.pid"

BEFORE_PIDS="$(pgrep -f "$FAKE_BIN/codex" || true)"
OUT="$(PATH="$FAKE_BIN:$PATH" "$CLI" --repo "$REPO" run start --trigger smoke-rollback-kill --max-start 1)"
echo "$OUT"

echo "$OUT" | grep -Eq "Failed to write pid metadata|Invalid pid metadata path"
echo "$OUT" | grep -q "Failed to launch codex worker"
echo "$OUT" | grep -q "Started tasks: 0"

AFTER_PIDS="$(pgrep -f "$FAKE_BIN/codex" || true)"
if [[ -n "$AFTER_PIDS" && "$AFTER_PIDS" != "$BEFORE_PIDS" ]]; then
  echo "leftover fake codex process detected:"
  echo "$AFTER_PIDS"
  exit 1
fi

LOCK_FILE="$REPO/.state/locks/app-shell.lock"
if [[ -f "$LOCK_FILE" ]]; then
  echo "lock file should be removed by rollback: $LOCK_FILE"
  exit 1
fi

WT_PATH="$TMP_DIR/repo-worktrees/repo-agenta-t8-009"
if [[ -d "$WT_PATH" ]]; then
  echo "worktree should be removed by rollback: $WT_PATH"
  exit 1
fi

if git -C "$REPO" rev-parse --verify "codex/agenta-t8-009" >/dev/null 2>&1; then
  echo "branch should be removed by rollback: codex/agenta-t8-009"
  exit 1
fi

grep -q "| T8-009 | Rollback kill check | AgentA | - | force pid-meta write error | TODO |" "$REPO/TODO.md"

echo "run start rollback kills codex process smoke test passed"
