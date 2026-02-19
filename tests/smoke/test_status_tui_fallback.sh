#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/scripts/codex-tasks"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

cat > "$REPO/TODO.md" <<'EOF'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T9-001 | Ready task | AgentA | - | | TODO |
EOF

"$CLI" --repo "$REPO" task scaffold-specs >/dev/null

assert_status_like_output() {
  local output="$1"

  echo "$output"

  echo "$output" | grep -q "Scheduler: ready=1 excluded=0"
  echo "$output" | grep -q "Runtime: total=0 active=0 stale=0"
  echo "$output" | grep -q "Coordination: locks=0"
}

assert_status_like_output "$($CLI --repo "$REPO" status --tui)"
assert_status_like_output "$($CLI --repo "$REPO" dashboard)"
assert_status_like_output "$($CLI --repo "$REPO")"

echo "tui/dashboard default entry smoke test passed"
