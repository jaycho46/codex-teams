#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-teams"

TMP_DIR="$(mktemp -d)"
REPO="$TMP_DIR/repo"
FAKE_BIN="$TMP_DIR/fake-bin"
FAKE_ARGS="$TMP_DIR/fake-codex.args"

cleanup() {
  if [[ -d "$REPO" ]]; then
    PATH="$FAKE_BIN:$PATH" \
      "$CLI" --repo "$REPO" task stop --all --apply --reason "smoke launch cleanup" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$REPO" "$FAKE_BIN"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main

cat > "$REPO/README.md" <<'EOF'
# Launch Smoke Repo
EOF
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "chore: init"

cat > "$FAKE_BIN/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "exec" ]] || exit 2
shift
printf '%s\n' "\$@" > "$FAKE_ARGS"
while true; do sleep 5; done
EOF
chmod +x "$FAKE_BIN/codex"

"$CLI" --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T8-001 | Launch worker | AgentA | - | launch smoke | TODO |
EOF
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"
"$CLI" --repo "$REPO" task scaffold-specs
git -C "$REPO" add tasks/specs
git -C "$REPO" commit -q -m "chore: scaffold task specs"

RUN_OUT="$(PATH="$FAKE_BIN:$PATH" "$CLI" --repo "$REPO" run start --trigger smoke-launch --max-start 1)"
echo "$RUN_OUT"

echo "$RUN_OUT" | grep -q "Started tasks: 1"
echo "$RUN_OUT" | grep -q "Launched codex worker: task=T8-001"

PID_META="$REPO/.state/orchestrator/t8-001.pid"
if [[ ! -f "$PID_META" ]]; then
  echo "missing pid metadata: $PID_META"
  exit 1
fi

PID="$(awk -F'=' '$1=="pid"{print $2}' "$PID_META" | tr -d '[:space:]')"
if [[ ! "$PID" =~ ^[0-9]+$ ]]; then
  echo "invalid pid in metadata: $PID"
  exit 1
fi

if ! kill -0 "$PID" >/dev/null 2>&1; then
  echo "worker pid is not alive: $PID"
  exit 1
fi

grep -q '^launch_backend=tmux$' "$PID_META"
grep -q '^task_id=T8-001$' "$PID_META"

SESSION="$(awk -F'=' '$1=="tmux_session"{print $2}' "$PID_META" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [[ -z "$SESSION" || "$SESSION" == "N/A" ]]; then
  echo "missing tmux session in metadata: $SESSION"
  exit 1
fi

if ! tmux has-session -t "$SESSION" >/dev/null 2>&1; then
  echo "tmux session not alive: $SESSION"
  exit 1
fi

LOG_FILE="$(awk -F'=' '$1=="log_file"{print $2}' "$PID_META" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
  echo "missing launch log file: $LOG_FILE"
  exit 1
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [[ -s "$FAKE_ARGS" ]]; then
    break
  fi
  sleep 0.5
done
if [[ ! -s "$FAKE_ARGS" ]]; then
  echo "missing fake codex args capture: $FAKE_ARGS"
  exit 1
fi

PRIMARY_REPO="$(git -C "$REPO" rev-parse --show-toplevel)"
EXPECTED_STATE_DIR="$PRIMARY_REPO/.state"

grep -Fx -- "--cd" "$FAKE_ARGS" >/dev/null
grep -Fx -- "--add-dir" "$FAKE_ARGS" >/dev/null
grep -Fx -- "$EXPECTED_STATE_DIR" "$FAKE_ARGS" >/dev/null
grep -Fx -- "$PRIMARY_REPO" "$FAKE_ARGS" >/dev/null
grep -Fx -- "--dangerously-bypass-approvals-and-sandbox" "$FAKE_ARGS" >/dev/null
if grep -Fx -- "--full-auto" "$FAKE_ARGS" >/dev/null; then
  echo "unexpected --full-auto in launched command"
  exit 1
fi
grep -F -- '$codex-teams' "$FAKE_ARGS" >/dev/null
grep -F -- 'Task lifecycle contract: this task was started by run start, and must end via task complete.' "$FAKE_ARGS" >/dev/null

PATH="$FAKE_BIN:$PATH" \
  "$CLI" --repo "$REPO" task stop --all --apply --reason "smoke launch cleanup"

sleep 1
if kill -0 "$PID" >/dev/null 2>&1; then
  echo "worker pid still alive after stop: $PID"
  exit 1
fi

if tmux has-session -t "$SESSION" >/dev/null 2>&1; then
  echo "tmux session still alive after stop: $SESSION"
  exit 1
fi

echo "run start launch tmux worker smoke test passed"
