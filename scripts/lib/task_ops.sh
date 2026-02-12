#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-}"

resolve_python_bin() {
  if [[ -n "$PYTHON_BIN" ]]; then
    if "$PYTHON_BIN" -c 'import tomllib' >/dev/null 2>&1 || "$PYTHON_BIN" -c 'import tomli' >/dev/null 2>&1; then
      echo "$PYTHON_BIN"
      return 0
    fi
    die "Configured PYTHON_BIN does not support TOML parsing: $PYTHON_BIN"
  fi

  local -a candidates=()
  local seen_blob=""
  local candidate

  for candidate in python3 python3.12 python3.11 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      candidate="$(command -v "$candidate")"
      if [[ ":$seen_blob:" != *":$candidate:"* ]]; then
        candidates+=("$candidate")
        seen_blob="${seen_blob}:$candidate"
      fi
    fi
  done

  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [[ -x "$candidate" && ":$seen_blob:" != *":$candidate:"* ]]; then
      candidates+=("$candidate")
      seen_blob="${seen_blob}:$candidate"
    fi
  done

  for candidate in "${candidates[@]}"; do
    if "$candidate" -c 'import tomllib' >/dev/null 2>&1 || "$candidate" -c 'import tomli' >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done

  die "No compatible Python runtime found. Install Python 3.11+ or tomli, or set PYTHON_BIN."
}

load_runtime_context() {
  PYTHON_BIN="${PYTHON_BIN:-$(resolve_python_bin)}"

  local -a cmd=(paths)
  if [[ -n "${TEAM_REPO_ARG:-}" ]]; then
    cmd+=(--repo "$TEAM_REPO_ARG")
  fi
  if [[ -n "${TEAM_STATE_DIR_ARG:-}" ]]; then
    cmd+=(--state-dir "$TEAM_STATE_DIR_ARG")
  fi
  if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
    cmd+=(--config "$TEAM_CONFIG_ARG")
  fi
  cmd+=(--format env)

  local env_dump
  env_dump="$("$PYTHON_BIN" "$PY_ENGINE" "${cmd[@]}")"
  eval "$env_dump"

  ACTIVE_PID_FILE="$ORCH_DIR/active_pids.tsv"
  mkdir -p "$ORCH_DIR"
  [[ -f "$ACTIVE_PID_FILE" ]] || : > "$ACTIVE_PID_FILE"
}

is_primary_worktree() {
  local repo="${1:-}"
  local gd cd
  gd="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)" || return 1
  cd="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$gd" == "$cd" ]]
}

require_agent_worktree_context() {
  local gd cd branch
  gd="$(git -C "$REPO_ROOT" rev-parse --git-dir)"
  cd="$(git -C "$REPO_ROOT" rev-parse --git-common-dir)"
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"

  if [[ "$gd" == "$cd" ]]; then
    die "Denied: task mutation commands must run from an agent worktree on codex/* branch"
  fi

  if [[ "$branch" != codex/* ]]; then
    die "Denied: agent worktree branch must start with codex/ (current: $branch)"
  fi
}

ensure_todo_template() {
  if [[ -f "$TODO_FILE" ]]; then
    return
  fi

  mkdir -p "$(dirname "$TODO_FILE")"
  cat > "$TODO_FILE" <<'TODO_TEMPLATE'
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
TODO_TEMPLATE
}

update_todo_status() {
  local task_id="${1:-}"
  local status="${2:-}"

  if [[ -z "$task_id" || -z "$status" ]]; then
    die "update_todo_status: missing task_id or status"
  fi

  ensure_todo_template

  local tmp_file
  tmp_file="$(mktemp)"
  if ! awk -F'|' -v task="$task_id" -v st="$status" '
    BEGIN { OFS="|"; found=0 }
    {
      if ($0 ~ /^\|/) {
        id=$2
        gsub(/^[ \t]+|[ \t]+$/, "", id)
        if (id == task) {
          $(NF-1) = " " st " "
          found=1
        }
      }
      print
    }
    END {
      if (!found) exit 42
    }
  ' "$TODO_FILE" > "$tmp_file"; then
    rm -f "$tmp_file"
    die "Task not found in TODO board: $task_id"
  fi

  mv "$tmp_file" "$TODO_FILE"
}

initialize_task_state() {
  mkdir -p "$LOCK_DIR"
  ensure_updates_file
  ensure_todo_template
}

state_dir_gitignore_entry() {
  local root="${REPO_ROOT%/}"
  local state="${STATE_DIR%/}"

  if [[ "$state" == "$root" ]]; then
    echo ""
    return 0
  fi

  if [[ "$state" == "$root/"* ]]; then
    local rel="${state#"$root/"}"
    [[ -n "$rel" ]] || {
      echo ""
      return 0
    }
    echo "${rel}/"
    return 0
  fi

  echo ""
}

gitignore_has_state_entry() {
  local entry="${1:-}"
  local gitignore_file="$REPO_ROOT/.gitignore"
  [[ -n "$entry" && -f "$gitignore_file" ]] || return 1

  local bare="${entry%/}"
  awk -v e="$entry" -v b="$bare" '
    {
      line=$0
      sub(/\r$/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      if (line == e || line == b || line == "/" e || line == "/" b) {
        found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$gitignore_file"
}

append_state_entry_to_gitignore() {
  local entry="${1:-}"
  local gitignore_file="$REPO_ROOT/.gitignore"
  [[ -n "$entry" ]] || return 1

  if [[ ! -f "$gitignore_file" ]]; then
    printf "%s\n" "$entry" > "$gitignore_file"
    return 0
  fi

  if [[ -s "$gitignore_file" ]]; then
    printf "\n%s\n" "$entry" >> "$gitignore_file"
  else
    printf "%s\n" "$entry" >> "$gitignore_file"
  fi
}

maybe_configure_state_gitignore() {
  local mode="${1:-ask}"
  local entry answer

  entry="$(state_dir_gitignore_entry)"
  if [[ -z "$entry" ]]; then
    echo "State dir is outside repository; skip .gitignore update: $STATE_DIR"
    return 0
  fi

  if gitignore_has_state_entry "$entry"; then
    echo ".gitignore already contains state path: $entry"
    return 0
  fi

  case "$mode" in
    yes)
      append_state_entry_to_gitignore "$entry"
      echo "Added state path to .gitignore: $entry"
      ;;
    no)
      echo "Skipped .gitignore update for state path: $entry"
      ;;
    ask)
      if [[ -t 0 && -t 1 ]]; then
        printf "Add '%s' to .gitignore? [y/N]: " "$entry"
        read -r answer
        if [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
          append_state_entry_to_gitignore "$entry"
          echo "Added state path to .gitignore: $entry"
        else
          echo "Skipped .gitignore update for state path: $entry"
        fi
      else
        echo "State path missing in .gitignore: $entry"
        echo "Tip: run 'codex-teams init --gitignore yes' to add it automatically."
      fi
      ;;
    *)
      die "Invalid --gitignore mode: $mode (expected ask|yes|no)"
      ;;
  esac
}

cmd_task_init() {
  local gitignore_mode="ask"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gitignore)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --gitignore"
        gitignore_mode="$1"
        ;;
      --gitignore=*)
        gitignore_mode="${1#*=}"
        ;;
      *)
        die "Unknown task init option: $1"
        ;;
    esac
    shift || true
  done

  load_runtime_context
  initialize_task_state
  maybe_configure_state_gitignore "$gitignore_mode"
  echo "Initialized state store: $STATE_DIR"
}

cmd_task_scaffold_specs() {
  load_runtime_context
  initialize_task_state

  local target_task=""
  local dry_run=0
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --task"
        target_task="$1"
        ;;
      --dry-run)
        dry_run=1
        ;;
      --force)
        force=1
        ;;
      *)
        die "Unknown task scaffold-specs option: $1"
        ;;
    esac
    shift || true
  done

  local selected_rows
  if ! selected_rows="$("$PYTHON_BIN" - "$SCRIPT_DIR/py" "$TODO_FILE" "$TODO_SCHEMA_JSON" "$target_task" <<'PY'
import json
import sys
from pathlib import Path

py_dir = Path(sys.argv[1]).resolve()
todo_file = Path(sys.argv[2]).resolve()
schema = json.loads(sys.argv[3])
target_task = (sys.argv[4] or "").strip()

sys.path.insert(0, str(py_dir))
from todo_parser import TodoError, parse_todo

try:
    tasks, _ = parse_todo(todo_file, schema)
except TodoError as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(2)

if target_task:
    selected = [task for task in tasks if str(task.get("id") or "") == target_task]
    if not selected:
        print(f"Task not found in TODO board: {target_task}", file=sys.stderr)
        raise SystemExit(2)
else:
    selected = [task for task in tasks if str(task.get("status") or "") == "TODO"]

for task in selected:
    task_id = str(task.get("id") or "")
    title = str(task.get("title") or "")
    print(f"{task_id}\t{title}")
PY
)"; then
    die "Failed to resolve scaffold targets from TODO board."
  fi

  if [[ -z "$(trim "$selected_rows")" ]]; then
    echo "No TODO tasks selected for spec scaffolding."
    return 0
  fi

  local generated=0
  local skipped=0
  local action_label
  while IFS=$'\t' read -r task_id task_title; do
    [[ -n "${task_id:-}" ]] || continue

    local spec_rel spec_abs
    spec_rel="tasks/specs/${task_id}.md"
    spec_abs="$REPO_ROOT/$spec_rel"

    if [[ -f "$spec_abs" && "$force" -eq 0 ]]; then
      echo "[SKIP] exists: $spec_rel"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$dry_run" -eq 1 ]]; then
      action_label="create"
      if [[ -f "$spec_abs" ]]; then
        action_label="overwrite"
      fi
      echo "[DRY-RUN] ${action_label}: $spec_rel"
      generated=$((generated + 1))
      continue
    fi

    mkdir -p "$(dirname "$spec_abs")"
    cat > "$spec_abs" <<EOF
# Task Spec: $task_id

Task title: ${task_title:-N/A}

## Goal
Define the concrete outcome for $task_id.

## In Scope
- Describe what must be implemented for this task.
- List files, modules, or behaviors that are in scope.

## Acceptance Criteria
- [ ] Implementation is complete and testable.
- [ ] Relevant tests or validation steps are added or updated.
- [ ] Changes are ready to merge with a clear completion summary.
EOF
    echo "[OK] wrote: $spec_rel"
    generated=$((generated + 1))
  done <<< "$selected_rows"

  echo "Spec scaffold summary: generated=$generated skipped=$skipped dry_run=$dry_run force=$force"
}

cmd_task_new() {
  load_runtime_context
  initialize_task_state

  local task_id="${1:-}"
  shift || true
  local deps_raw="-"
  local -a summary_parts=()
  local summary=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deps)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --deps"
        deps_raw="$1"
        ;;
      --deps=*)
        deps_raw="${1#--deps=}"
        [[ -n "$deps_raw" ]] || die "Missing value for --deps"
        ;;
      --)
        shift || true
        while [[ $# -gt 0 ]]; do
          summary_parts+=("$1")
          shift || true
        done
        break
        ;;
      --*)
        die "Unknown task new option: $1"
        ;;
      *)
        summary_parts+=("$1")
        ;;
    esac
    shift || true
  done

  summary="$(trim "${summary_parts[*]:-}")"

  [[ -n "$task_id" && -n "$summary" ]] || die "Usage: codex-teams task new <task_id> [--deps <task_id[,task_id...]>] <summary>"
  [[ "$task_id" != *"|"* ]] || die "task_id must not contain '|': $task_id"

  local default_owner
  default_owner="$("$PYTHON_BIN" - "$OWNERS_JSON" <<'PY'
import json
import sys

owners = json.loads(sys.argv[1])
if not isinstance(owners, dict) or not owners:
    raise SystemExit(2)
print(next(iter(owners.keys())))
PY
)"
  [[ -n "$default_owner" ]] || die "Unable to resolve default owner from [owners] config."

  if ! "$PYTHON_BIN" - "$TODO_FILE" "$TODO_SCHEMA_JSON" "$task_id" "$summary" "$default_owner" "$deps_raw" <<'PY'
import json
import re
import sys
from pathlib import Path

todo_file = Path(sys.argv[1])
schema = json.loads(sys.argv[2])
task_id = sys.argv[3].strip()
title = sys.argv[4].strip()
owner = sys.argv[5].strip()
deps_input = sys.argv[6].strip()

if not task_id:
    print("Error: task_id is empty", file=sys.stderr)
    raise SystemExit(2)
if not title:
    print("Error: summary is empty", file=sys.stderr)
    raise SystemExit(2)

deps_value = "-"
if deps_input and deps_input != "-":
    dep_values = []
    seen = set()
    for dep_raw in re.split(r"[,\s]+", deps_input):
        dep = dep_raw.strip()
        if not dep:
            continue
        if dep == task_id:
            print(f"Error: task cannot depend on itself: {task_id}", file=sys.stderr)
            raise SystemExit(2)
        if not re.fullmatch(r"T\d+-\d+", dep):
            print(f"Error: invalid dependency id '{dep}' (expected T<digits>-<digits>)", file=sys.stderr)
            raise SystemExit(2)
        if dep in seen:
            continue
        seen.add(dep)
        dep_values.append(dep)
    if dep_values:
        deps_value = ",".join(dep_values)

id_col = int(schema["id_col"])
title_col = int(schema["title_col"])
owner_col = int(schema["owner_col"])
deps_col = int(schema["deps_col"])
status_col = int(schema["status_col"])

lines = todo_file.read_text(encoding="utf-8").splitlines()
table_rows = [idx for idx, line in enumerate(lines) if line.startswith("|")]
if not table_rows:
    print("Error: TODO board table not found", file=sys.stderr)
    raise SystemExit(2)

header_idx = table_rows[0]
template_cols = [cell.strip() for cell in lines[header_idx].split("|")]
for idx in table_rows:
    cols = [cell.strip() for cell in lines[idx].split("|")]
    if id_col - 1 < len(cols) and cols[id_col - 1] == "ID":
        header_idx = idx
        template_cols = cols
        break

for idx in table_rows:
    cols = [cell.strip() for cell in lines[idx].split("|")]
    if id_col - 1 >= len(cols):
        continue
    existing = cols[id_col - 1]
    if not existing or existing == "ID" or set(existing) == {"-"}:
        continue
    if existing == task_id:
        print(f"Error: Task already exists in TODO board: {task_id}", file=sys.stderr)
        raise SystemExit(2)

width = max(len(template_cols), status_col + 1)
if width < 3:
    width = 3

row_cells = [""] * (width - 2)

def set_by_col(col_no: int, value: str) -> None:
    i = col_no - 2
    if 0 <= i < len(row_cells):
        row_cells[i] = value

set_by_col(id_col, task_id)
set_by_col(title_col, title)
set_by_col(owner_col, owner)
set_by_col(deps_col, deps_value)
set_by_col(status_col, "TODO")

notes_col = None
for i, cell in enumerate(template_cols):
    if cell.strip().lower() == "notes":
        notes_col = i + 1
        break
if notes_col is not None:
    set_by_col(notes_col, "")

escaped_cells = [cell.replace("|", "\\|").strip() for cell in row_cells]
new_row = "| " + " | ".join(escaped_cells) + " |"

insert_idx = max(table_rows) + 1
lines.insert(insert_idx, new_row)

todo_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Added task to TODO board: {task_id} (owner={owner})")
PY
  then
    die "Failed to append new task to TODO board."
  fi

  local new_task_id="$task_id"
  cmd_task_scaffold_specs --task "$new_task_id"
  echo "Created task: id=$new_task_id owner=$default_owner title=$summary"
}

cmd_task_lock() {
  load_runtime_context

  local agent="${1:-}"
  local scope_raw="${2:-}"
  local task_id="${3:-N/A}"
  local scope
  scope="$(normalize_scope "$scope_raw")"

  [[ -n "$agent" && -n "$scope" ]] || die "Usage: codex-teams task lock <agent> <scope> [task_id]"

  require_agent_worktree_context
  initialize_task_state

  local lock_file="$LOCK_DIR/$scope.lock"
  if [[ -f "$lock_file" ]]; then
    local owner existing_task created
    owner="$(read_field "$lock_file" "owner")"
    existing_task="$(read_field "$lock_file" "task_id")"
    created="$(read_field "$lock_file" "created_at")"
    die "Lock exists: scope=$scope owner=$owner task=$existing_task created_at=$created"
  fi

  local now branch worktree
  now="$(timestamp_utc)"
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  worktree="$REPO_ROOT"

  cat > "$lock_file" <<LOCK_META
owner=$agent
scope=$scope
task_id=$task_id
branch=$branch
worktree=$worktree
created_at=$now
heartbeat_at=$now
LOCK_META

  echo "Locked: scope=$scope owner=$agent task=$task_id"
}

cmd_task_unlock() {
  load_runtime_context

  local agent="${1:-}"
  local scope_raw="${2:-}"
  local scope
  scope="$(normalize_scope "$scope_raw")"

  [[ -n "$agent" && -n "$scope" ]] || die "Usage: codex-teams task unlock <agent> <scope>"

  require_agent_worktree_context
  initialize_task_state

  local lock_file="$LOCK_DIR/$scope.lock"
  [[ -f "$lock_file" ]] || die "No lock: scope=$scope"

  local owner
  owner="$(read_field "$lock_file" "owner")"
  [[ "$owner" == "$agent" ]] || die "Unlock denied: scope=$scope owner=$owner requested_by=$agent"

  rm -f "$lock_file"
  echo "Unlocked: scope=$scope by=$agent"
}

cmd_task_heartbeat() {
  load_runtime_context

  local agent="${1:-}"
  local scope_raw="${2:-}"
  local scope
  scope="$(normalize_scope "$scope_raw")"

  [[ -n "$agent" && -n "$scope" ]] || die "Usage: codex-teams task heartbeat <agent> <scope>"

  require_agent_worktree_context
  initialize_task_state

  local lock_file="$LOCK_DIR/$scope.lock"
  [[ -f "$lock_file" ]] || die "No lock: scope=$scope"

  local owner now
  owner="$(read_field "$lock_file" "owner")"
  [[ "$owner" == "$agent" ]] || die "Heartbeat denied: scope=$scope owner=$owner requested_by=$agent"

  now="$(timestamp_utc)"
  awk -F'=' -v now="$now" 'BEGIN{OFS="="} $1=="heartbeat_at"{$2=now} {print}' "$lock_file" > "$lock_file.tmp"
  mv "$lock_file.tmp" "$lock_file"

  echo "Heartbeat updated: scope=$scope owner=$agent at=$now"
}

cmd_task_update() {
  load_runtime_context

  local agent="${1:-}"
  local task_id="${2:-}"
  local status="${3:-}"
  shift 3 || true
  local summary="${*:-}"

  [[ -n "$agent" && -n "$task_id" && -n "$status" && -n "$summary" ]] || die "Usage: codex-teams task update <agent> <task_id> <status> <summary>"
  is_valid_status "$status" || die "Invalid status: $status"

  require_agent_worktree_context
  initialize_task_state

  update_todo_status "$task_id" "$status"
  append_update_log "$agent" "$task_id" "$status" "$summary"

  echo "Update logged: task=$task_id status=$status"
}

merge_task_branch_into_primary() {
  local primary_repo="${1:-}"
  local branch_name="${2:-}"
  local base_branch="${3:-main}"
  local task_worktree="${4:-}"
  local merge_strategy="${5:-rebase-then-ff}"

  [[ -n "$primary_repo" && -n "$branch_name" ]] || return 1
  case "$merge_strategy" in
    ff-only|rebase-then-ff) ;;
    *)
      die "Invalid merge strategy: $merge_strategy (expected: ff-only|rebase-then-ff)"
      ;;
  esac

  if [[ -n "$(git -C "$primary_repo" status --porcelain --untracked-files=no)" ]]; then
    die "primary repo has tracked uncommitted changes: $primary_repo"
  fi

  if ! git -C "$primary_repo" rev-parse --verify "$base_branch" >/dev/null 2>&1; then
    die "Base branch not found in primary repo: $base_branch"
  fi
  if ! git -C "$primary_repo" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    die "Task branch not found in primary repo: $branch_name"
  fi

  if [[ "$(git -C "$primary_repo" rev-parse --abbrev-ref HEAD)" != "$base_branch" ]]; then
    git -C "$primary_repo" checkout --quiet "$base_branch"
  fi

  if git -C "$primary_repo" merge-base --is-ancestor "$branch_name" "$base_branch"; then
    echo "Branch already merged: $branch_name -> $base_branch"
    return 0
  fi

  if git -C "$primary_repo" merge --ff-only "$branch_name" >/dev/null 2>&1; then
    echo "Merged branch into primary: $branch_name -> $base_branch"
    return 0
  fi

  if [[ "$merge_strategy" == "ff-only" ]]; then
    die "Fast-forward merge failed: $branch_name -> $base_branch (manual merge required)"
  fi

  [[ -n "$task_worktree" ]] || die "Fast-forward merge failed: $branch_name -> $base_branch (task worktree required for auto-rebase)"
  if [[ ! -d "$task_worktree" ]]; then
    die "Fast-forward merge failed: task worktree not found for auto-rebase: $task_worktree"
  fi

  if [[ -n "$(git -C "$task_worktree" status --porcelain --untracked-files=no)" ]]; then
    die "Fast-forward merge failed and task worktree has tracked uncommitted changes: $task_worktree"
  fi
  if [[ "$(git -C "$task_worktree" rev-parse --abbrev-ref HEAD)" != "$branch_name" ]]; then
    git -C "$task_worktree" checkout --quiet "$branch_name"
  fi

  echo "Fast-forward merge failed, attempting auto-rebase: $branch_name onto $base_branch"
  if ! git -C "$task_worktree" rebase "$base_branch" >/dev/null 2>&1; then
    git -C "$task_worktree" rebase --abort >/dev/null 2>&1 || true
    die "Auto-rebase failed: $branch_name onto $base_branch (manual merge required)"
  fi

  if ! git -C "$primary_repo" merge --ff-only "$branch_name" >/dev/null 2>&1; then
    die "Merge failed after auto-rebase: $branch_name -> $base_branch (manual merge required)"
  fi
  echo "Merged branch into primary after auto-rebase: $branch_name -> $base_branch"
}

remove_completed_worktree_and_branch() {
  local primary_repo="${1:-}"
  local worktree_path="${2:-}"
  local branch_name="${3:-}"

  [[ -n "$primary_repo" && -n "$worktree_path" && -n "$branch_name" ]] || return 1

  if [[ "$worktree_path" == "$primary_repo" ]]; then
    die "Refusing cleanup: worktree path points to primary repo ($worktree_path)"
  fi

  if [[ -d "$worktree_path" ]]; then
    if ! git -C "$primary_repo" worktree remove --force "$worktree_path" >/dev/null 2>&1; then
      die "Failed to remove completed worktree: $worktree_path"
    fi
    echo "Removed completed worktree: $worktree_path"
  else
    echo "Worktree already absent: $worktree_path"
  fi

  if git -C "$primary_repo" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    if ! git -C "$primary_repo" branch -D "$branch_name" >/dev/null 2>&1; then
      die "Failed to delete completed branch: $branch_name"
    fi
    echo "Deleted completed branch: $branch_name"
  else
    echo "Branch already absent: $branch_name"
  fi
}

cmd_task_complete() {
  load_runtime_context

  local agent="${1:-}"
  local scope_raw="${2:-}"
  local task_id="${3:-}"
  shift 3 || true

  local scope
  scope="$(normalize_scope "$scope_raw")"
  local summary=""
  local trigger_label="task_done"
  local auto_run_start=1
  local merge_strategy="rebase-then-ff"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --summary)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --summary"
        summary="$1"
        ;;
      --trigger)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --trigger"
        trigger_label="$1"
        ;;
      --no-run-start)
        auto_run_start=0
        ;;
      --merge-strategy)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --merge-strategy"
        merge_strategy="$1"
        ;;
      *)
        die "Unknown task complete option: $1"
        ;;
    esac
    shift || true
  done

  [[ -n "$agent" && -n "$scope" && -n "$task_id" ]] || die "Usage: codex-teams task complete <agent> <scope> <task_id> [--summary <text>] [--trigger <label>] [--no-run-start] [--merge-strategy <ff-only|rebase-then-ff>]"
  case "$merge_strategy" in
    ff-only|rebase-then-ff) ;;
    *)
      die "Invalid --merge-strategy: $merge_strategy (expected: ff-only|rebase-then-ff)"
      ;;
  esac

  require_agent_worktree_context
  initialize_task_state

  local lock_file="$LOCK_DIR/$scope.lock"
  [[ -f "$lock_file" ]] || die "No lock: scope=$scope"

  local owner lock_task
  owner="$(read_field "$lock_file" "owner")"
  lock_task="$(read_field "$lock_file" "task_id")"
  [[ "$owner" == "$agent" ]] || die "Complete denied: scope=$scope owner=$owner requested_by=$agent"
  [[ "$lock_task" == "$task_id" ]] || die "Complete denied: scope=$scope lock_task=$lock_task requested_task=$task_id"

  local tracked_changes line changed_path task_status
  tracked_changes="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)"
  if [[ -n "$tracked_changes" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      changed_path="${line:3}"
      if [[ "$changed_path" == *" -> "* ]]; then
        changed_path="${changed_path##* -> }"
      fi
      die "agent worktree has tracked uncommitted changes: $changed_path (commit everything before task complete)"
    done <<< "$tracked_changes"
  fi

  task_status="$(awk -F'|' -v task="$task_id" '
    $0 ~ /^\|/ {
      id=$2
      gsub(/^[ \t]+|[ \t]+$/, "", id)
      if (id == task) {
        status=$(NF-1)
        gsub(/^[ \t]+|[ \t]+$/, "", status)
        print status
        exit
      }
    }
  ' "$TODO_FILE")"
  [[ -n "$task_status" ]] || die "Task not found in TODO board: $task_id"
  case "$task_status" in
    DONE|완료|Complete|complete) ;;
    *)
      die "Task status must be DONE before task complete: task=$task_id status=$task_status (commit everything first)"
      ;;
  esac

  local log_summary
  log_summary="$(trim "$summary")"
  if [[ -z "$log_summary" ]]; then
    log_summary="task complete"
  fi

  append_update_log "$agent" "$task_id" "DONE" "$log_summary"
  echo "Completion prerequisites satisfied: task=$task_id owner=$agent status=$task_status"

  local branch_name primary_repo scheduler_bin primary_team_bin repo_root_phys team_bin_phys team_bin_dir
  branch_name="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  primary_repo="$(primary_repo_root_for "$REPO_ROOT" || true)"
  [[ -n "$primary_repo" ]] || die "Unable to resolve primary repo from worktree: $REPO_ROOT"
  primary_team_bin="$primary_repo/scripts/codex-teams"
  repo_root_phys="$(cd "$REPO_ROOT" && pwd -P)"
  team_bin_phys=""
  if [[ -x "$TEAM_BIN" ]]; then
    team_bin_dir="$(cd "$(dirname "$TEAM_BIN")" && pwd -P 2>/dev/null || true)"
    if [[ -n "$team_bin_dir" ]]; then
      team_bin_phys="$team_bin_dir/$(basename "$TEAM_BIN")"
    fi
  fi

  if [[ -x "$primary_team_bin" ]]; then
    scheduler_bin="$primary_team_bin"
  elif [[ -n "$team_bin_phys" && "$team_bin_phys" != "$repo_root_phys/"* ]]; then
    scheduler_bin="$TEAM_BIN"
  elif command -v codex-teams >/dev/null 2>&1; then
    scheduler_bin="$(command -v codex-teams)"
  else
    die "Unable to resolve codex-teams binary for post-complete scheduler run."
  fi

  merge_task_branch_into_primary "$primary_repo" "$branch_name" "$BASE_BRANCH" "$REPO_ROOT" "$merge_strategy"

  rm -f "$lock_file"
  echo "Unlocked: scope=$scope by=$agent"

  remove_completed_worktree_and_branch "$primary_repo" "$REPO_ROOT" "$branch_name"
  remove_pid_metadata_for_task "$task_id"

  if [[ "$auto_run_start" -eq 1 ]]; then
    local -a run_cmd=("$scheduler_bin" --repo "$primary_repo" --state-dir "$STATE_DIR")
    if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
      run_cmd+=(--config "$TEAM_CONFIG_ARG")
    fi
    run_cmd+=(run start --trigger "$trigger_label")

    echo "Triggering scheduler after completion: trigger=$trigger_label"
    (
      cd "$primary_repo"
      "${run_cmd[@]}"
    )
  fi

  echo "Task completion flow finished: task=$task_id owner=$agent scope=$scope"
}

cmd_worktree_create() {
  load_runtime_context

  local agent="${1:-}"
  local task_id="${2:-}"
  local base_branch="${3:-$BASE_BRANCH}"
  local parent_dir="${4:-$WORKTREE_PARENT_DIR}"

  [[ -n "$agent" && -n "$task_id" ]] || die "Usage: codex-teams worktree create <agent> <task_id> [base_branch] [parent_dir]"

  local branch_name worktree_path shared_state
  branch_name="$(branch_name_for "$agent" "$task_id")"
  worktree_path="$(ensure_agent_worktree "$REPO_ROOT" "$REPO_NAME" "$agent" "$task_id" "$base_branch" "$parent_dir")"
  shared_state="$(shared_state_dir_for "$parent_dir")"

  echo "Created worktree: $worktree_path"
  echo "Branch: $branch_name"
  echo "Recommended shared state dir: $shared_state"
}

cmd_worktree_start() {
  load_runtime_context

  local agent="${1:-}"
  local scope="${2:-}"
  local task_id="${3:-}"
  local base_branch="${4:-$BASE_BRANCH}"
  local parent_dir="${5:-$WORKTREE_PARENT_DIR}"
  local summary="${6:-Starting ${task_id}}"

  [[ -n "$agent" && -n "$scope" && -n "$task_id" ]] || die "Usage: codex-teams worktree start <agent> <scope> <task_id> [base_branch] [parent_dir] [summary]"

  local branch_name worktree_path shared_state scope_key lock_file lock_owner lock_task
  local -a cli_base

  branch_name="$(branch_name_for "$agent" "$task_id")"
  worktree_path="$(ensure_agent_worktree "$REPO_ROOT" "$REPO_NAME" "$agent" "$task_id" "$base_branch" "$parent_dir")"
  shared_state="${AI_STATE_DIR:-$(shared_state_dir_for "$parent_dir")}"
  scope_key="$(normalize_scope "$scope")"
  lock_file="${shared_state}/locks/${scope_key}.lock"

  cli_base=("$TEAM_BIN" --repo "$worktree_path" --state-dir "$shared_state")
  if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
    cli_base+=(--config "$TEAM_CONFIG_ARG")
  fi

  (cd "$worktree_path" && AI_STATE_DIR="$shared_state" "${cli_base[@]}" task init)

  if [[ -f "$lock_file" ]]; then
    lock_owner="$(read_field "$lock_file" "owner")"
    lock_task="$(read_field "$lock_file" "task_id")"
    if [[ "$lock_owner" != "$agent" || "$lock_task" != "$task_id" ]]; then
      die "Lock conflict: scope=$scope owner=$lock_owner task=$lock_task"
    fi
    echo "Lock already held: scope=$scope owner=$agent task=$task_id"
  else
    (cd "$worktree_path" && AI_STATE_DIR="$shared_state" "${cli_base[@]}" task lock "$agent" "$scope" "$task_id")
  fi

  (cd "$worktree_path" && AI_STATE_DIR="$shared_state" "${cli_base[@]}" task update "$agent" "$task_id" "IN_PROGRESS" "$summary")

  echo "Task started:"
  echo "  agent=$agent"
  echo "  task=$task_id"
  echo "  scope=$scope"
  echo "  branch=$branch_name"
  echo "  worktree=$worktree_path"
  echo "  state=$shared_state"
  echo "worktree=$worktree_path"
}

cmd_worktree_list() {
  load_runtime_context
  git -C "$REPO_ROOT" worktree list
}

refresh_active_pid_registry() {
  mkdir -p "$ORCH_DIR"
  local tmp_file
  tmp_file="$(mktemp)"

  shopt -s nullglob
  local pid_meta pid task_id owner scope started backend label session worktree alive
  for pid_meta in "$ORCH_DIR"/*.pid; do
    [[ -f "$pid_meta" ]] || continue

    pid="$(read_field "$pid_meta" "pid")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue

    task_id="$(read_field "$pid_meta" "task_id")"
    owner="$(read_field "$pid_meta" "owner")"
    scope="$(read_field "$pid_meta" "scope")"
    started="$(read_field "$pid_meta" "started_at")"
    backend="$(read_field "$pid_meta" "launch_backend")"
    label="$(read_field "$pid_meta" "launch_label")"
    session="$(read_field "$pid_meta" "tmux_session")"
    worktree="$(read_field "$pid_meta" "worktree")"

    if kill -0 "$pid" >/dev/null 2>&1; then
      alive=1
    else
      alive=0
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$pid" "$alive" "$task_id" "$owner" "$scope" "$started" "$backend" "$label" "$session" "$worktree" >> "$tmp_file"
  done
  shopt -u nullglob

  mv "$tmp_file" "$ACTIVE_PID_FILE"
}

print_active_pid_registry() {
  refresh_active_pid_registry

  local total alive
  total="$(awk 'NF > 0 {count++} END {print count+0}' "$ACTIVE_PID_FILE")"
  alive="$(awk -F'\t' 'NF > 0 && $2 == "1" {count++} END {print count+0}' "$ACTIVE_PID_FILE")"

  echo "Active pid registry: $ACTIVE_PID_FILE"
  echo "Registry entries: total=$total alive=$alive"

  if [[ "$total" -eq 0 ]]; then
    return
  fi

  echo "  PID    ALIVE TASK             OWNER        SCOPE            BACKEND   STARTED_AT"
  awk -F'\t' '
    NF > 0 {
      pid=$1; alive=$2; task=$3; owner=$4; scope=$5; started=$6; backend=$7
      if (task == "") task="-"
      if (owner == "") owner="-"
      if (scope == "") scope="-"
      if (backend == "") backend="-"
      if (started == "") started="-"
      printf "  %-6s %-5s %-16s %-12s %-16s %-9s %s\n", pid, alive, task, owner, scope, backend, started
    }
  ' "$ACTIVE_PID_FILE"
}

terminate_pid() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  kill "$pid" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  kill -9 "$pid" >/dev/null 2>&1 || true
  ! kill -0 "$pid" >/dev/null 2>&1
}

kill_tmux_session_if_any() {
  local session="${1:-}"
  [[ -n "$session" && "$session" != "N/A" ]] || return 0
  command -v tmux >/dev/null 2>&1 || return 0

  if tmux has-session -t "$session" >/dev/null 2>&1; then
    tmux kill-session -t "$session" >/dev/null 2>&1 || return 1
  fi

  return 0
}

kill_launch_label_if_any() {
  local label="${1:-}"
  [[ -n "$label" && "$label" != "N/A" ]] || return 0
  command -v launchctl >/dev/null 2>&1 || return 0
  [[ "$(uname -s)" == "Darwin" ]] || return 0

  local uid
  uid="$(id -u)"
  launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
  launchctl bootout "user/${uid}/${label}" >/dev/null 2>&1 || true
  launchctl remove "$label" >/dev/null 2>&1 || true

  if launchctl list | awk -v l="$label" '$3==l{found=1} END{exit(found?0:1)}'; then
    return 1
  fi

  return 0
}

rollback_task_to_todo() {
  local task_id="${1:-}"
  local owner="${2:-OrchestratorSuite}"
  local reason="${3:-manual stop}"

  [[ -n "$task_id" && "$task_id" != "N/A" ]] || {
    echo "task id missing"
    return 2
  }

  ensure_todo_template

  local tmp_file
  tmp_file="$(mktemp)"
  if ! awk -F'|' -v task="$task_id" -v st="TODO" '
    BEGIN { OFS="|"; found=0 }
    {
      if ($0 ~ /^\|/) {
        id=$2
        gsub(/^[ \t]+|[ \t]+$/, "", id)
        if (id == task) {
          $(NF-1) = " " st " "
          found=1
        }
      }
      print
    }
    END {
      if (!found) exit 42
    }
  ' "$TODO_FILE" > "$tmp_file"; then
    rm -f "$tmp_file"
    echo "task not found in TODO board"
    return 2
  fi

  mv "$tmp_file" "$TODO_FILE"
  append_update_log "$owner" "$task_id" "TODO" "Stopped by codex-teams: $reason"
  echo "updated TODO to TODO"
  return 0
}

remove_worktree_and_branch() {
  local worktree="${1:-}"
  local owner="${2:-}"
  local task_id="${3:-}"

  if [[ -n "$worktree" && "$worktree" != "N/A" ]]; then
    if [[ "$worktree" == "$REPO_ROOT" ]]; then
      echo "refusing to remove primary repository worktree: $worktree"
      return 1
    fi

    if [[ -d "$worktree" ]]; then
      if ! git -C "$REPO_ROOT" worktree remove --force "$worktree" >/dev/null 2>&1; then
        echo "failed to remove worktree: $worktree"
        return 1
      fi
    fi
  fi

  if [[ -n "$owner" && -n "$task_id" && "$task_id" != "N/A" ]]; then
    local branch_name
    branch_name="$(branch_name_for "$(normalize_agent_name "$owner")" "$task_id" || true)"
    if [[ -n "$branch_name" ]] && git -C "$REPO_ROOT" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
      if ! git -C "$REPO_ROOT" branch -D "$branch_name" >/dev/null 2>&1; then
        echo "failed to delete branch: $branch_name"
        return 1
      fi
    fi
  fi

  return 0
}

apply_actions_for_record() {
  local task_id="${1:-}"
  local owner="${2:-}"
  local scope="${3:-}"
  local state="${4:-}"
  local pid="${5:-}"
  local pid_alive="${6:-0}"
  local pid_file="${7:-}"
  local lock_file="${8:-}"
  local worktree="${9:-}"
  local reason="${10:-manual stop}"
  local failed=0

  local tmux_session=""
  local launch_label=""
  if [[ -n "$pid_file" && -f "$pid_file" ]]; then
    tmux_session="$(read_field "$pid_file" "tmux_session")"
    launch_label="$(read_field "$pid_file" "launch_label")"
  fi

  echo "- task=$task_id owner=${owner:-N/A} scope=${scope:-N/A} state=$state"

  if [[ -n "$pid_file" && "$pid_alive" == "1" ]]; then
    if terminate_pid "$pid"; then
      echo "  [OK] pid terminated: $pid"
    else
      echo "  [ERROR] failed to terminate pid: $pid"
      failed=1
    fi
  elif [[ -n "$pid_file" ]]; then
    echo "  [OK] pid already exited: ${pid:-N/A}"
  else
    echo "  [SKIP] no pid metadata"
  fi

  if [[ -n "$tmux_session" && "$tmux_session" != "N/A" ]]; then
    if kill_tmux_session_if_any "$tmux_session"; then
      echo "  [OK] tmux session removed: $tmux_session"
    else
      echo "  [ERROR] failed to remove tmux session: $tmux_session"
      failed=1
    fi
  fi

  if [[ -n "$launch_label" && "$launch_label" != "N/A" ]]; then
    if kill_launch_label_if_any "$launch_label"; then
      echo "  [OK] launch label removed: $launch_label"
    else
      echo "  [ERROR] failed to remove launch label: $launch_label"
      failed=1
    fi
  fi

  if [[ -n "$lock_file" && -f "$lock_file" ]]; then
    if rm -f "$lock_file"; then
      echo "  [OK] lock removed: $lock_file"
    else
      echo "  [ERROR] failed to remove lock: $lock_file"
      failed=1
    fi
  elif [[ -n "$lock_file" ]]; then
    echo "  [OK] lock already absent: $lock_file"
  else
    echo "  [SKIP] no lock metadata"
  fi

  local rollback_note
  if rollback_note="$(rollback_task_to_todo "$task_id" "${owner:-OrchestratorSuite}" "$reason" 2>&1)"; then
    echo "  [OK] TODO rollback: $rollback_note"
  else
    case "$?" in
      2)
        echo "  [SKIP][unsupported] TODO rollback: $rollback_note"
        ;;
      *)
        echo "  [ERROR] TODO rollback failed: $rollback_note"
        failed=1
        ;;
    esac
  fi

  local cleanup_note
  if cleanup_note="$(remove_worktree_and_branch "$worktree" "$owner" "$task_id" 2>&1)"; then
    echo "  [OK] worktree/branch cleanup: ${cleanup_note:-done}"
  else
    echo "  [ERROR] worktree/branch cleanup failed: $cleanup_note"
    failed=1
  fi

  if [[ -n "$pid_file" && -f "$pid_file" ]]; then
    if rm -f "$pid_file"; then
      echo "  [OK] pid metadata removed: $pid_file"
    else
      echo "  [ERROR] failed to remove pid metadata: $pid_file"
      failed=1
    fi
  elif [[ -n "$pid_file" ]]; then
    echo "  [OK] pid metadata already absent: $pid_file"
  else
    echo "  [SKIP] no pid metadata file"
  fi

  return "$failed"
}

run_selected_actions() {
  local selected_tsv="${1:-}"
  local action_label="${2:-task-stop}"
  local reason_text="${3:-manual action}"
  local apply="${4:-0}"

  local normalized_tsv
  normalized_tsv="$("$PYTHON_BIN" - "$selected_tsv" <<'PY'
import sys

raw = sys.argv[1]
placeholder = "__EMPTY__"
out = []
for line in raw.splitlines():
    if not line.strip():
        continue
    cols = line.split("\t")
    cols += [""] * max(0, 12 - len(cols))
    cols = cols[:12]
    cols = [c if c else placeholder for c in cols]
    out.append("\t".join(cols))
print("\n".join(out))
PY
)"

  local total success failed
  total="$(printf '%s\n' "$normalized_tsv" | awk 'NF > 0' | wc -l | tr -d ' ')"
  success=0
  failed=0

  echo "Action: $action_label"
  echo "Target records: $total"
  if [[ "$apply" -eq 0 ]]; then
    echo "Mode: DRY-RUN (no mutations)"
  else
    echo "Mode: APPLY"
  fi

  while IFS=$'\t' read -r key task_id owner scope state pid pid_alive pid_file lock_file worktree tmux_session worktree_exists; do
    [[ -n "${key:-}" ]] || continue

    [[ "$task_id" == "__EMPTY__" ]] && task_id=""
    [[ "$owner" == "__EMPTY__" ]] && owner=""
    [[ "$scope" == "__EMPTY__" ]] && scope=""
    [[ "$state" == "__EMPTY__" ]] && state=""
    [[ "$pid" == "__EMPTY__" ]] && pid=""
    [[ "$pid_alive" == "__EMPTY__" ]] && pid_alive=""
    [[ "$pid_file" == "__EMPTY__" ]] && pid_file=""
    [[ "$lock_file" == "__EMPTY__" ]] && lock_file=""
    [[ "$worktree" == "__EMPTY__" ]] && worktree=""

    if [[ "$apply" -eq 0 ]]; then
      echo "- task=$task_id owner=${owner:-N/A} scope=${scope:-N/A} state=$state"
      echo "  [PLAN] terminate pid (if alive), remove lock, rollback TODO->TODO, remove worktree+branch, remove pid metadata"
      success=$((success + 1))
      continue
    fi

    if apply_actions_for_record "$task_id" "$owner" "$scope" "$state" "$pid" "$pid_alive" "$pid_file" "$lock_file" "$worktree" "$reason_text"; then
      success=$((success + 1))
    else
      failed=$((failed + 1))
    fi
  done <<< "$normalized_tsv"

  echo "Summary: success=$success failed=$failed"
  refresh_active_pid_registry
  [[ "$failed" -eq 0 ]]
}

cmd_task_stop() {
  load_runtime_context

  local target_mode=""
  local target_task=""
  local target_owner=""
  local reason="requested by operator"
  local apply=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --task"
        [[ -z "$target_mode" ]] || die "Use only one of --task/--owner/--all"
        target_mode="task"
        target_task="$1"
        ;;
      --owner)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --owner"
        [[ -z "$target_mode" ]] || die "Use only one of --task/--owner/--all"
        target_mode="owner"
        target_owner="$1"
        ;;
      --all)
        [[ -z "$target_mode" ]] || die "Use only one of --task/--owner/--all"
        target_mode="all"
        ;;
      --reason)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --reason"
        reason="$1"
        ;;
      --apply)
        apply=1
        ;;
      *)
        die "Unknown task stop option: $1"
        ;;
    esac
    shift || true
  done

  [[ -n "$target_mode" ]] || die "task stop requires one target: --task <id> | --owner <owner> | --all"

  local -a cmd=(select-stop --repo "$REPO_ROOT" --state-dir "$STATE_DIR" --format tsv)
  case "$target_mode" in
    task) cmd+=(--task "$target_task") ;;
    owner) cmd+=(--owner "$target_owner") ;;
    all) cmd+=(--all) ;;
  esac
  if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
    cmd+=(--config "$TEAM_CONFIG_ARG")
  fi

  local selected_tsv
  selected_tsv="$("$PYTHON_BIN" "$PY_ENGINE" "${cmd[@]}")"
  [[ -n "$selected_tsv" ]] || die "No matching records for task stop target"

  run_selected_actions "$selected_tsv" "task-stop" "$reason" "$apply"
}

cmd_task_cleanup_stale() {
  load_runtime_context

  local apply=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)
        apply=1
        ;;
      *)
        die "Unknown task cleanup-stale option: $1"
        ;;
    esac
    shift || true
  done

  local -a cmd=(select-stale --repo "$REPO_ROOT" --state-dir "$STATE_DIR" --format tsv)
  if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
    cmd+=(--config "$TEAM_CONFIG_ARG")
  fi

  local selected_tsv
  selected_tsv="$("$PYTHON_BIN" "$PY_ENGINE" "${cmd[@]}")"
  if [[ -z "$selected_tsv" ]]; then
    echo "No stale records found."
    return
  fi

  run_selected_actions "$selected_tsv" "task-cleanup-stale" "cleanup stale runtime metadata" "$apply"
}

cmd_task_emergency_stop() {
  local reason="emergency stop requested"
  local assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --reason"
        reason="$1"
        ;;
      --yes|-y)
        assume_yes=1
        ;;
      --apply)
        # Backward-compatible no-op: emergency-stop now always applies.
        ;;
      *)
        die "Unknown task emergency-stop option: $1"
        ;;
    esac
    shift || true
  done

  if [[ "$assume_yes" -eq 0 ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
      die "task emergency-stop requires interactive confirmation. Re-run with --yes to proceed."
    fi
    echo "Action: EMERGENCY STOP"
    echo "This will execute: codex-teams task stop --all --apply"
    echo "Reason: $reason"
    printf "Continue? type 'yes' to proceed: "
    local answer=""
    read -r answer
    if [[ "$answer" != "yes" ]]; then
      echo "Canceled emergency stop."
      return 0
    fi
  fi

  cmd_task_stop --all --apply --reason "$reason"
}

pid_meta_path_for_task() {
  local task_id="${1:-}"
  [[ -n "$task_id" ]] || return 1

  local task_slug
  task_slug="$(sanitize "$task_id")"
  [[ -n "$task_slug" ]] || task_slug="$task_id"
  echo "$ORCH_DIR/${task_slug}.pid"
}

remove_pid_metadata_for_task() {
  local task_id="${1:-}"
  [[ -n "$task_id" ]] || return 0

  local pid_meta
  pid_meta="$(pid_meta_path_for_task "$task_id" || true)"
  [[ -n "$pid_meta" ]] || return 0

  if [[ -f "$pid_meta" ]]; then
    rm -f "$pid_meta" >/dev/null 2>&1 || true
    echo "Removed pid metadata for task=$task_id"
    return 0
  fi

  return 0
}

split_shell_words() {
  local raw="${1:-}"
  "$PYTHON_BIN" - "$raw" <<'PY'
import shlex
import sys

raw = sys.argv[1]
if not raw.strip():
    raise SystemExit(0)

for token in shlex.split(raw):
    print(token)
PY
}

resolve_worker_codex_teams_bin() {
  local worktree_path="${1:-}"
  local primary_repo primary_team_bin

  primary_repo="$(primary_repo_root_for "$worktree_path" || true)"
  if [[ -n "$primary_repo" ]]; then
    primary_team_bin="$primary_repo/scripts/codex-teams"
    if [[ -x "$primary_team_bin" ]]; then
      echo "$primary_team_bin"
      return 0
    fi
  fi

  if [[ -x "$TEAM_BIN" ]]; then
    echo "$TEAM_BIN"
    return 0
  fi

  if command -v codex-teams >/dev/null 2>&1; then
    command -v codex-teams
    return 0
  fi

  return 1
}

spawn_detached_process() {
  local log_file="${1:-}"
  shift || true
  [[ -n "$log_file" ]] || return 1
  [[ $# -gt 0 ]] || return 1

  "$PYTHON_BIN" - "$log_file" "$@" <<'PY'
import os
import subprocess
import sys

log_file = sys.argv[1]
cmd = sys.argv[2:]
if not cmd:
    raise SystemExit(2)

log_dir = os.path.dirname(log_file)
if log_dir:
    os.makedirs(log_dir, exist_ok=True)

with open(log_file, "ab", buffering=0) as stream:
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=stream,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

print(proc.pid)
PY
}

build_codex_worker_prompt() {
  local task_id="${1:-}"
  local task_title="${2:-}"
  local owner="${3:-}"
  local scope="${4:-}"
  local agent="${5:-}"
  local trigger="${6:-manual}"
  local worktree_path="${7:-}"
  local spec_rel_path="${8:-}"
  local goal_summary="${9:-}"
  local in_scope_summary="${10:-}"
  local acceptance_summary="${11:-}"
  local rules_file rendered_rules worker_cli_bin worker_cli_cmd
  local spec_path_display

  if [[ -n "${SCRIPT_DIR:-}" ]]; then
    rules_file="$SCRIPT_DIR/prompts/codex-worker-rules.md"
  else
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    rules_file="$(cd "$lib_dir/.." && pwd)/prompts/codex-worker-rules.md"
  fi
  [[ -f "$rules_file" ]] || die "Missing codex worker rules file: $rules_file"

  worker_cli_bin="$(resolve_worker_codex_teams_bin "$worktree_path" || true)"
  if [[ -z "$worker_cli_bin" ]]; then
    worker_cli_bin="codex-teams"
  fi
  worker_cli_cmd="$(printf '%q' "$worker_cli_bin")"

  rendered_rules="$(cat "$rules_file")"
  rendered_rules="${rendered_rules//__CODEX_TEAMS_CMD__/$worker_cli_cmd}"
  rendered_rules="${rendered_rules//__WORKTREE_PATH__/$worktree_path}"
  rendered_rules="${rendered_rules//__STATE_DIR__/$STATE_DIR}"
  rendered_rules="${rendered_rules//__AGENT__/$agent}"
  rendered_rules="${rendered_rules//__TASK_ID__/$task_id}"
  rendered_rules="${rendered_rules//__SCOPE__/$scope}"

  if [[ -n "$spec_rel_path" ]]; then
    spec_path_display="${worktree_path}/${spec_rel_path}"
  else
    spec_path_display="N/A"
  fi

  cat <<PROMPT
Task assignment: ${task_id} (${task_title})
Owner: ${owner}
Scope: ${scope}
Trigger: ${trigger}

Task spec file:
${spec_path_display}

Task brief:
- Goal: ${goal_summary}
- In Scope: ${in_scope_summary}
- Acceptance Criteria: ${acceptance_summary}

The task spec file is the source of truth for implementation details.

Work only on this task in this worktree:
${worktree_path}

${rendered_rules}
PROMPT
}

launch_codex_exec_worker() {
  local task_id="${1:-}"
  local task_title="${2:-}"
  local owner="${3:-}"
  local scope="${4:-}"
  local agent="${5:-}"
  local trigger="${6:-manual}"
  local worktree_path="${7:-}"
  local spec_rel_path="${8:-}"
  local goal_summary="${9:-}"
  local in_scope_summary="${10:-}"
  local acceptance_summary="${11:-}"

  [[ -n "$task_id" && -n "$owner" && -n "$scope" && -n "$agent" && -n "$worktree_path" ]] || return 1
  command -v codex >/dev/null 2>&1 || die "codex command not found. Install Codex CLI or use --no-launch."

  local pid_meta logs_dir log_file pid started_at prompt primary_repo
  pid_meta="$(pid_meta_path_for_task "$task_id" || true)"
  [[ -n "$pid_meta" ]] || {
    echo "[ERROR] Failed to resolve pid metadata path for task=$task_id"
    return 1
  }

  logs_dir="$ORCH_DIR/logs"
  mkdir -p "$logs_dir"
  log_file="$logs_dir/$(basename "${pid_meta%.pid}")-$(date -u +%Y%m%dT%H%M%SZ).log"

  if [[ -f "$pid_meta" ]]; then
    local existing_pid
    existing_pid="$(read_field "$pid_meta" "pid")"
    if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" >/dev/null 2>&1; then
      echo "[ERROR] Active pid metadata already exists for task=$task_id pid=$existing_pid file=$pid_meta"
      return 1
    fi
    rm -f "$pid_meta"
  fi

  local -a codex_flags=()
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    codex_flags+=("$token")
  done < <(split_shell_words "$CODEX_FLAGS")

  local sandbox_configured=0
  local full_auto_configured=0
  local flag
  for flag in "${codex_flags[@]}"; do
    case "$flag" in
      --sandbox|-s|--dangerously-bypass-approvals-and-sandbox)
        sandbox_configured=1
        ;;
      --full-auto)
        full_auto_configured=1
        ;;
    esac
  done
  # Worker completion flow needs writes under primary .git/worktrees for index locks.
  # --full-auto enforces workspace-write sandbox, so when sandbox is not explicit,
  # replace it with bypass mode for detached worker automation.
  if [[ "$sandbox_configured" -eq 0 ]]; then
    if [[ "$full_auto_configured" -eq 1 ]]; then
      local -a filtered_flags=()
      for flag in "${codex_flags[@]}"; do
        if [[ "$flag" == "--full-auto" ]]; then
          continue
        fi
        filtered_flags+=("$flag")
      done
      codex_flags=("${filtered_flags[@]}")
    fi
    codex_flags+=(--dangerously-bypass-approvals-and-sandbox)
  fi

  prompt="$(build_codex_worker_prompt "$task_id" "$task_title" "$owner" "$scope" "$agent" "$trigger" "$worktree_path" "$spec_rel_path" "$goal_summary" "$in_scope_summary" "$acceptance_summary")"
  primary_repo="$(primary_repo_root_for "$worktree_path" || true)"

  local -a codex_cmd=(codex exec)
  if [[ "${#codex_flags[@]}" -gt 0 ]]; then
    codex_cmd+=("${codex_flags[@]}")
  fi
  codex_cmd+=(--cd "$worktree_path")
  # Allow worker-driven task update/complete to write shared state and finalize on primary repo.
  codex_cmd+=(--add-dir "$STATE_DIR")
  if [[ -n "$primary_repo" && "$primary_repo" != "$STATE_DIR" ]]; then
    codex_cmd+=(--add-dir "$primary_repo")
  fi
  codex_cmd+=("$prompt")

  pid="$(spawn_detached_process "$log_file" "${codex_cmd[@]}" || true)"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Failed to launch detached codex process: task=$task_id owner=$owner"
    return 1
  fi

  sleep 0.5
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    echo "[ERROR] codex exec exited immediately: task=$task_id owner=$owner log=$log_file"
    return 1
  fi

  if [[ -d "$pid_meta" ]]; then
    echo "[ERROR] Invalid pid metadata path (directory): $pid_meta"
    terminate_pid "$pid" >/dev/null 2>&1 || true
    return 1
  fi

  started_at="$(timestamp_utc)"
  if ! cat > "$pid_meta" <<PID_META
pid=$pid
task_id=$task_id
owner=$owner
scope=$scope
worktree=$worktree_path
started_at=$started_at
launch_backend=codex_exec
launch_label=N/A
tmux_session=N/A
log_file=$log_file
trigger=$trigger
PID_META
  then
    echo "[ERROR] Failed to write pid metadata: $pid_meta"
    terminate_pid "$pid" >/dev/null 2>&1 || true
    return 1
  fi

  echo "Launched codex worker: task=$task_id owner=$owner pid=$pid log=$log_file"
}

rollback_start_attempt() {
  local task_id="${1:-}"
  local owner="${2:-}"
  local scope="${3:-}"
  local branch_name="${4:-}"
  local branch_existed_before="${5:-0}"
  local worktree_existed_before="${6:-0}"
  local preferred_worktree_path="${7:-}"
  local reason="${8:-start failed}"

  local pid_meta pid tmux_session launch_label
  pid_meta="$(pid_meta_path_for_task "$task_id" || true)"

  if [[ -n "$pid_meta" && -f "$pid_meta" ]]; then
    pid="$(read_field "$pid_meta" "pid")"
    tmux_session="$(read_field "$pid_meta" "tmux_session")"
    launch_label="$(read_field "$pid_meta" "launch_label")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
      if terminate_pid "$pid"; then
        echo "[ROLLBACK] terminated codex pid: $pid"
      else
        echo "[ROLLBACK][WARN] failed to terminate codex pid: $pid"
      fi
    fi
    kill_tmux_session_if_any "$tmux_session" >/dev/null 2>&1 || true
    kill_launch_label_if_any "$launch_label" >/dev/null 2>&1 || true
    rm -f "$pid_meta" >/dev/null 2>&1 || true
  fi

  local lock_file lock_owner lock_task
  lock_file="$LOCK_DIR/$(normalize_scope "$scope").lock"
  if [[ -f "$lock_file" ]]; then
    lock_owner="$(read_field "$lock_file" "owner")"
    lock_task="$(read_field "$lock_file" "task_id")"
    if [[ "$lock_owner" == "$owner" && "$lock_task" == "$task_id" ]]; then
      rm -f "$lock_file" >/dev/null 2>&1 || true
    fi
  fi

  rollback_task_to_todo "$task_id" "$owner" "$reason" >/dev/null 2>&1 || true

  local current_worktree=""
  if [[ -n "$branch_name" ]]; then
    current_worktree="$(find_worktree_for_branch "$REPO_ROOT" "$branch_name" || true)"
  fi
  local worktree_path="$current_worktree"
  if [[ -z "$worktree_path" ]]; then
    worktree_path="$preferred_worktree_path"
  fi

  if [[ "$worktree_existed_before" -eq 0 ]]; then
    if [[ -n "$worktree_path" && -d "$worktree_path" && "$worktree_path" != "$REPO_ROOT" ]]; then
      git -C "$REPO_ROOT" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
    fi
  fi

  if [[ "$branch_existed_before" -eq 0 && -n "$branch_name" ]]; then
    if [[ -z "$(find_worktree_for_branch "$REPO_ROOT" "$branch_name" || true)" ]]; then
      if git -C "$REPO_ROOT" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
        git -C "$REPO_ROOT" branch -D "$branch_name" >/dev/null 2>&1 || true
      fi
    fi
  fi
}

print_scheduler_snapshot() {
  local json="${1:-}"
  "$PYTHON_BIN" - "$json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
running = payload.get("running_locks", [])
ready = payload.get("ready_tasks", [])
excluded = payload.get("excluded_tasks", [])

print(f"Trigger: {payload.get('trigger', 'manual')}")
print(f"State dir: {payload.get('state_dir', '')}")
print(f"Running locks: {len(running)}")
for item in running:
    print(f"  - scope={item.get('scope', '')} owner={item.get('owner', '')} task={item.get('task_id', '')}")

print(f"Ready tasks: {len(ready)}")
for item in ready:
    print(f"  - {item.get('task_id', '')} | {item.get('owner', '')} | deps={item.get('deps', '')} | {item.get('title', '')}")

print(f"Excluded tasks: {len(excluded)}")
for item in excluded:
    print(
        f"  - {item.get('task_id', '')} | {item.get('owner', '')} "
        f"| reason={item.get('reason', '')} source={item.get('source', '')}"
    )
PY
}

acquire_scheduler_lock() {
  local run_lock_dir="${1:-}"
  local pid_file="${run_lock_dir}/pid"
  local lock_pid=""

  mkdir -p "$(dirname "$run_lock_dir")"

  if mkdir "$run_lock_dir" 2>/dev/null; then
    echo "$$" > "$pid_file"
    return 0
  fi

  if [[ -f "$pid_file" ]]; then
    lock_pid="$(tr -d '[:space:]' < "$pid_file")"
  fi

  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" >/dev/null 2>&1; then
    echo "Scheduler is already running: $run_lock_dir (pid=$lock_pid)"
    return 1
  fi

  echo "Found stale scheduler lock: $run_lock_dir"
  rm -f "$pid_file" >/dev/null 2>&1 || true
  rmdir "$run_lock_dir" >/dev/null 2>&1 || true

  if ! mkdir "$run_lock_dir" 2>/dev/null; then
    echo "Scheduler is already running: $run_lock_dir"
    return 1
  fi

  echo "$$" > "$pid_file"
  return 0
}

cmd_run_start() {
  local dry_run=0
  local no_launch=""
  local trigger="manual"
  local max_start_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        ;;
      --no-launch)
        no_launch=1
        ;;
      --trigger)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --trigger"
        trigger="$1"
        ;;
      --max-start)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --max-start"
        max_start_arg="$1"
        ;;
      *)
        die "Unknown run start option: $1"
        ;;
    esac
    shift || true
  done

  load_runtime_context

  if [[ -z "$no_launch" ]]; then
    if [[ "${AUTO_NO_LAUNCH:-0}" == "1" ]]; then
      no_launch=1
    else
      no_launch=0
    fi
  fi

  if ! is_primary_worktree "$REPO_ROOT"; then
    if [[ "${AI_ORCH_ALLOW_WORKTREE_RUN:-0}" != "1" ]]; then
      die "run start disabled from worktree. Run from primary repo or set AI_ORCH_ALLOW_WORKTREE_RUN=1"
    fi
  fi

  if [[ "$dry_run" -eq 0 && "$no_launch" -eq 0 ]]; then
    command -v codex >/dev/null 2>&1 || die "codex command not found. Use --no-launch or install Codex CLI."
  fi

  local -a ready_cmd=(ready --repo "$REPO_ROOT" --state-dir "$STATE_DIR" --trigger "$trigger")
  if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
    ready_cmd+=(--config "$TEAM_CONFIG_ARG")
  fi
  if [[ -n "$max_start_arg" ]]; then
    ready_cmd+=(--max-start "$max_start_arg")
  fi

  local ready_json
  ready_json="$("$PYTHON_BIN" "$PY_ENGINE" "${ready_cmd[@]}")"
  print_scheduler_snapshot "$ready_json"

  local ready_tsv
  ready_tsv="$("$PYTHON_BIN" "$PY_ENGINE" "${ready_cmd[@]}" --format tsv)"

  local run_lock_dir="$ORCH_DIR/run.lock"
  if ! acquire_scheduler_lock "$run_lock_dir"; then
    return
  fi

  trap "rm -f '$run_lock_dir/pid' >/dev/null 2>&1 || true; rmdir '$run_lock_dir' >/dev/null 2>&1 || true" EXIT

  local started_count=0
  while IFS=$'\t' read -r task_id task_title owner scope deps status spec_rel_path goal_summary in_scope_summary acceptance_summary; do
    [[ -n "${task_id:-}" ]] || continue

    local agent summary start_output worktree_path
    local branch_name expected_worktree_path
    local branch_existed_before=0
    local worktree_existed_before=0
    local -a start_cmd

    agent="$(normalize_agent_name "$owner")"
    summary="Auto-start by scheduler (${trigger})"
    branch_name="$(branch_name_for "$agent" "$task_id" || true)"
    expected_worktree_path="$(default_worktree_path_for "$REPO_NAME" "$agent" "$task_id" "$WORKTREE_PARENT_DIR")"

    if [[ -n "$branch_name" ]] && git -C "$REPO_ROOT" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
      branch_existed_before=1
    fi
    if [[ -n "$branch_name" && -n "$(find_worktree_for_branch "$REPO_ROOT" "$branch_name" || true)" ]]; then
      worktree_existed_before=1
    fi

    if [[ "$dry_run" -eq 1 ]]; then
      echo "[DRY-RUN] $TEAM_BIN --repo $REPO_ROOT --state-dir $STATE_DIR worktree start $agent $scope $task_id $BASE_BRANCH $WORKTREE_PARENT_DIR '$summary'"
      started_count=$((started_count + 1))
      continue
    fi

    start_cmd=("$TEAM_BIN" --repo "$REPO_ROOT" --state-dir "$STATE_DIR")
    if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
      start_cmd+=(--config "$TEAM_CONFIG_ARG")
    fi
    start_cmd+=(worktree start "$agent" "$scope" "$task_id" "$BASE_BRANCH" "$WORKTREE_PARENT_DIR" "$summary")

    if ! start_output="$(AI_STATE_DIR="$STATE_DIR" "${start_cmd[@]}" 2>&1)"; then
      echo "$start_output"
      echo "[ERROR] Failed to start task=$task_id owner=$owner"
      rollback_start_attempt "$task_id" "$owner" "$scope" "$branch_name" "$branch_existed_before" "$worktree_existed_before" "$expected_worktree_path" "worktree start failed"
      continue
    fi

    echo "$start_output"

    worktree_path="$(printf '%s\n' "$start_output" | awk -F'=' '/^worktree=/{print substr($0,10)}' | tail -n1)"
    if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
      echo "[ERROR] Missing worktree path after start: task=$task_id owner=$owner"
      rollback_start_attempt "$task_id" "$owner" "$scope" "$branch_name" "$branch_existed_before" "$worktree_existed_before" "$expected_worktree_path" "worktree path missing"
      continue
    fi

    if [[ "$no_launch" -eq 0 ]]; then
      if ! launch_codex_exec_worker "$task_id" "$task_title" "$owner" "$scope" "$agent" "$trigger" "$worktree_path" "$spec_rel_path" "$goal_summary" "$in_scope_summary" "$acceptance_summary"; then
        echo "[ERROR] Failed to launch codex worker: task=$task_id owner=$owner"
        rollback_start_attempt "$task_id" "$owner" "$scope" "$branch_name" "$branch_existed_before" "$worktree_existed_before" "$worktree_path" "codex launch failed"
        continue
      fi
    fi

    started_count=$((started_count + 1))
  done <<< "$ready_tsv"

  echo "Started tasks: $started_count"

  rm -f "$run_lock_dir/pid" >/dev/null 2>&1 || true
  rmdir "$run_lock_dir" >/dev/null 2>&1 || true
  trap - EXIT

  if [[ "$dry_run" -eq 0 && "$started_count" -gt 0 ]]; then
    echo "Post-start unified status:"
    if [[ -n "$max_start_arg" ]]; then
      cmd_unified_status --trigger "$trigger" --max-start "$max_start_arg"
    else
      cmd_unified_status --trigger "$trigger"
    fi
  fi
}

cmd_unified_status() {
  load_runtime_context

  local json_output=0
  local tui_output=0
  local trigger="manual"
  local max_start_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_output=1
        ;;
      --tui)
        tui_output=1
        ;;
      --trigger)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --trigger"
        trigger="$1"
        ;;
      --max-start)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --max-start"
        max_start_arg="$1"
        ;;
      *)
        die "Unknown status option: $1"
        ;;
    esac
    shift || true
  done

  local -a cmd=(status --repo "$REPO_ROOT" --state-dir "$STATE_DIR" --trigger "$trigger")
  if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
    cmd+=(--config "$TEAM_CONFIG_ARG")
  fi
  if [[ -n "$max_start_arg" ]]; then
    cmd+=(--max-start "$max_start_arg")
  fi

  if [[ "$json_output" -eq 1 && "$tui_output" -eq 1 ]]; then
    die "status options --json and --tui are mutually exclusive"
  fi

  if [[ "$json_output" -eq 1 ]]; then
    cmd+=(--format json)
  elif [[ "$tui_output" -eq 1 ]]; then
    cmd+=(--format tui)
  else
    cmd+=(--format text)
  fi

  "$PYTHON_BIN" "$PY_ENGINE" "${cmd[@]}"
}
