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
| T9-101 | Spec required task | AgentA | - | | TODO |
EOF

OUT_MISSING="$($CLI --repo "$REPO" run start --dry-run --trigger smoke-requires-spec-missing)"
echo "$OUT_MISSING"
echo "$OUT_MISSING" | grep -q "reason=missing_task_spec"
echo "$OUT_MISSING" | grep -q "Started tasks: 0"

"$CLI" --repo "$REPO" task scaffold-specs >/dev/null

OUT_READY="$($CLI --repo "$REPO" run start --dry-run --trigger smoke-requires-spec-ready)"
echo "$OUT_READY"
echo "$OUT_READY" | grep -q "Started tasks: 1"
echo "$OUT_READY" | grep -q "\[DRY-RUN\].*T9-101"

echo "run start requires task spec smoke test passed"
