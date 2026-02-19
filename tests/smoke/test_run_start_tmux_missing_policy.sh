#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-tasks"

TMP_DIR="$(mktemp -d)"
REPO="$TMP_DIR/repo"
FAKE_BIN="$TMP_DIR/fake-bin"

cleanup() {
  if [[ -d "$REPO" ]]; then
    "$CLI" --repo "$REPO" task stop --all --apply --reason "tmux missing policy cleanup" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$REPO" "$FAKE_BIN"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b main

cat > "$REPO/README.md" <<'EOF'
# Tmux Missing Policy Repo
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

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 127
EOF
chmod +x "$FAKE_BIN/tmux"

"$CLI" --repo "$REPO" task init

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T9-201 | tmux policy | AgentA | - | policy check | TODO |
EOF
git -C "$REPO" add TODO.md
git -C "$REPO" commit -q -m "chore: seed todo"
"$CLI" --repo "$REPO" task scaffold-specs
git -C "$REPO" add tasks/specs
git -C "$REPO" commit -q -m "chore: scaffold task specs"

set +e
OUT_FAIL="$(PATH="$FAKE_BIN:$PATH" "$CLI" --repo "$REPO" run start --trigger smoke-tmux-missing --max-start 1 2>&1)"
RC_FAIL=$?
set -e
echo "$OUT_FAIL"
if [[ "$RC_FAIL" -eq 0 ]]; then
  echo "run start should fail when tmux is unavailable"
  exit 1
fi
echo "$OUT_FAIL" | grep -q "tmux command is not usable\|tmux command not found"

OUT_NO_LAUNCH="$(PATH="$FAKE_BIN:$PATH" "$CLI" --repo "$REPO" run start --no-launch --trigger smoke-tmux-missing --max-start 1)"
echo "$OUT_NO_LAUNCH"
echo "$OUT_NO_LAUNCH" | grep -q "Started tasks: 1"

echo "run start tmux missing policy smoke test passed"
