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
| T1-001 | Active task | AgentA | - | | TODO |
| T1-002 | Same owner | AgentA | - | | TODO |
| T1-003 | Ready task | AgentB | - | | TODO |
EOF

mkdir -p "$REPO/.state/locks" "$REPO/.state/orchestrator"
cat > "$REPO/.state/locks/app-shell.lock" <<EOF
owner=AgentA
scope=app-shell
task_id=T1-001
worktree=$REPO
EOF
cat > "$REPO/.state/orchestrator/worker.pid" <<EOF
owner=AgentA
scope=app-shell
task_id=T1-001
pid=$$
worktree=$REPO
EOF

"$CLI" --repo "$REPO" task scaffold-specs >/dev/null

OUTPUT="$($CLI --repo "$REPO" run start --dry-run --trigger smoke)"

echo "$OUTPUT"

echo "$OUTPUT" | grep -q "Excluded tasks: 2"
echo "$OUTPUT" | grep -q "reason=active_worker"
echo "$OUTPUT" | grep -q "reason=owner_busy"
echo "$OUTPUT" | grep -q "\[DRY-RUN\].*T1-003"

echo "smoke test passed"
