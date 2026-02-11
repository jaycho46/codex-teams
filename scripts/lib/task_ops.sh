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

cmd_task_init() {
  load_runtime_context
  initialize_task_state
  echo "Initialized state store: $STATE_DIR"
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

commit_completion_marker_if_needed() {
  local task_id="${1:-}"
  local summary="${2:-task complete}"
  local commit_msg
  commit_msg="task(${task_id}): complete - ${summary}"

  git -C "$REPO_ROOT" add -- "$TODO_FILE"
  if git -C "$REPO_ROOT" diff --cached --quiet --exit-code; then
    echo "No completion marker changes to commit."
    return 0
  fi

  git -C "$REPO_ROOT" commit -q -m "$commit_msg"
  echo "Committed completion marker on branch: $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
}

merge_task_branch_into_primary() {
  local primary_repo="${1:-}"
  local branch_name="${2:-}"
  local base_branch="${3:-main}"

  [[ -n "$primary_repo" && -n "$branch_name" ]] || return 1

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

  if ! git -C "$primary_repo" merge --ff-only "$branch_name" >/dev/null 2>&1; then
    die "Fast-forward merge failed: $branch_name -> $base_branch (manual merge required)"
  fi
  echo "Merged branch into primary: $branch_name -> $base_branch"
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
  local summary="task complete"
  local trigger_label="task_done"
  local auto_run_start=1

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
      *)
        die "Unknown task complete option: $1"
        ;;
    esac
    shift || true
  done

  [[ -n "$agent" && -n "$scope" && -n "$task_id" ]] || die "Usage: codex-teams task complete <agent> <scope> <task_id> [--summary <text>] [--trigger <label>] [--no-run-start]"

  require_agent_worktree_context
  initialize_task_state

  local lock_file="$LOCK_DIR/$scope.lock"
  [[ -f "$lock_file" ]] || die "No lock: scope=$scope"

  local owner lock_task
  owner="$(read_field "$lock_file" "owner")"
  lock_task="$(read_field "$lock_file" "task_id")"
  [[ "$owner" == "$agent" ]] || die "Complete denied: scope=$scope owner=$owner requested_by=$agent"
  [[ "$lock_task" == "$task_id" ]] || die "Complete denied: scope=$scope lock_task=$lock_task requested_task=$task_id"

  local todo_rel tracked_changes line changed_path
  todo_rel="$TODO_FILE"
  if [[ "$TODO_FILE" == "$REPO_ROOT/"* ]]; then
    todo_rel="${TODO_FILE#"$REPO_ROOT/"}"
  else
    todo_rel="$(basename "$TODO_FILE")"
  fi

  tracked_changes="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)"
  if [[ -n "$tracked_changes" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      changed_path="${line:3}"
      if [[ "$changed_path" == *" -> "* ]]; then
        changed_path="${changed_path##* -> }"
      fi
      if [[ "$changed_path" != "$todo_rel" ]]; then
        die "agent worktree has tracked uncommitted changes outside TODO file: $changed_path (commit first)"
      fi
    done <<< "$tracked_changes"
  fi

  update_todo_status "$task_id" "DONE"
  append_update_log "$agent" "$task_id" "DONE" "$summary"
  echo "Marked task DONE in worktree: task=$task_id owner=$agent"

  commit_completion_marker_if_needed "$task_id" "$summary"

  local branch_name primary_repo
  branch_name="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  primary_repo="$(primary_repo_root_for "$REPO_ROOT" || true)"
  [[ -n "$primary_repo" ]] || die "Unable to resolve primary repo from worktree: $REPO_ROOT"

  merge_task_branch_into_primary "$primary_repo" "$branch_name" "$BASE_BRANCH"

  rm -f "$lock_file"
  echo "Unlocked: scope=$scope by=$agent"

  remove_completed_worktree_and_branch "$primary_repo" "$REPO_ROOT" "$branch_name"

  if [[ "$auto_run_start" -eq 1 ]]; then
    local -a run_cmd=("$TEAM_BIN" --repo "$primary_repo" --state-dir "$STATE_DIR")
    if [[ -n "${TEAM_CONFIG_ARG:-}" ]]; then
      run_cmd+=(--config "$TEAM_CONFIG_ARG")
    fi
    run_cmd+=(run start --trigger "$trigger_label")

    echo "Triggering scheduler after completion: trigger=$trigger_label"
    "${run_cmd[@]}"
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
  load_runtime_context

  local apply=0
  local reason="emergency stop requested"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)
        apply=1
        ;;
      --reason)
        shift || true
        [[ $# -gt 0 ]] || die "Missing value for --reason"
        reason="$1"
        ;;
      *)
        die "Unknown task emergency-stop option: $1"
        ;;
    esac
    shift || true
  done

  refresh_active_pid_registry

  local total alive
  total="$(awk 'NF > 0 {count++} END {print count+0}' "$ACTIVE_PID_FILE")"
  alive="$(awk -F'\t' 'NF > 0 && $2 == "1" {count++} END {print count+0}' "$ACTIVE_PID_FILE")"

  echo "Action: task emergency-stop"
  echo "Reason: $reason"
  echo "Registry: $ACTIVE_PID_FILE"
  echo "Targets: total=$total alive=$alive"

  local killed=0 failed=0
  while IFS=$'\t' read -r pid alive_flag task_id owner scope started backend label session worktree; do
    [[ -n "${pid:-}" ]] || continue

    if [[ "$apply" -eq 0 ]]; then
      if [[ "$alive_flag" == "1" ]]; then
        echo "- pid=$pid task=${task_id:-N/A} owner=${owner:-N/A} [PLAN] terminate pid"
      else
        echo "- pid=$pid task=${task_id:-N/A} owner=${owner:-N/A} [PLAN] verify already exited"
      fi
      continue
    fi

    if [[ "$alive_flag" == "1" ]]; then
      if terminate_pid "$pid"; then
        echo "- pid=$pid task=${task_id:-N/A} owner=${owner:-N/A} [OK] terminated"
        killed=$((killed + 1))
      else
        echo "- pid=$pid task=${task_id:-N/A} owner=${owner:-N/A} [ERROR] terminate failed"
        failed=$((failed + 1))
      fi
    else
      echo "- pid=$pid task=${task_id:-N/A} owner=${owner:-N/A} [SKIP] already not alive"
    fi
  done < "$ACTIVE_PID_FILE"

  if [[ "$apply" -eq 0 ]]; then
    echo "Mode: DRY-RUN (no mutations)"
    return
  fi

  append_update_log "CodexTeams" "N/A" "BLOCKED" "Emergency stop executed: $reason (killed=$killed failed=$failed)"
  refresh_active_pid_registry
  echo "Summary: killed=$killed failed=$failed"

  if [[ "$failed" -gt 0 ]]; then
    return 1
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
  local no_launch=1
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

  if ! is_primary_worktree "$REPO_ROOT"; then
    if [[ "${AI_ORCH_ALLOW_WORKTREE_RUN:-0}" != "1" ]]; then
      die "run start disabled from worktree. Run from primary repo or set AI_ORCH_ALLOW_WORKTREE_RUN=1"
    fi
  fi

  if [[ "$no_launch" -ne 1 ]]; then
    echo "Launch mode is not available in this build. Using no-launch behavior."
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
  while IFS=$'\t' read -r task_id task_title owner scope deps status; do
    [[ -n "${task_id:-}" ]] || continue

    local agent summary
    local -a start_cmd

    agent="$(normalize_agent_name "$owner")"
    summary="Auto-start by scheduler (${trigger})"

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

    if ! AI_STATE_DIR="$STATE_DIR" "${start_cmd[@]}"; then
      echo "[ERROR] Failed to start task=$task_id owner=$owner"
      continue
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
