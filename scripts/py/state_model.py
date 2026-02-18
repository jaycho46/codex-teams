from __future__ import annotations

import os
from pathlib import Path
from typing import Any


ACTIVE_STATES = {"RUNNING", "LOCKED", "FINALIZING"}
STALE_STATES = {
    "LOCK_STALE",
    "FINALIZING_EXITED",
    "ORPHAN_LOCK",
    "ORPHAN_PID",
    "MISSING_WORKTREE",
}


def is_active_state(state: str) -> bool:
    return state in ACTIVE_STATES


def is_stale_state(state: str) -> bool:
    return state in STALE_STATES


def read_field(file_path: Path, key: str) -> str:
    if not file_path.exists():
        return ""
    for line in file_path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        lhs, rhs = line.split("=", 1)
        if lhs.strip() == key:
            return rhs.strip()
    return ""


def is_pid_alive(pid_value: str) -> bool:
    if not pid_value or not pid_value.isdigit():
        return False
    pid = int(pid_value)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def load_pid_inventory(orch_dir: str | Path) -> list[dict[str, Any]]:
    base = Path(orch_dir)
    rows: list[dict[str, Any]] = []
    if not base.exists():
        return rows

    for pid_meta in sorted(base.glob("*.pid")):
        if not pid_meta.is_file():
            continue
        task_id = read_field(pid_meta, "task_id")
        owner = read_field(pid_meta, "owner")
        scope = read_field(pid_meta, "scope")
        pid = read_field(pid_meta, "pid")
        worktree = read_field(pid_meta, "worktree")
        tmux_session = read_field(pid_meta, "tmux_session")
        launch_backend = read_field(pid_meta, "launch_backend")
        log_file = read_field(pid_meta, "log_file")

        key = task_id if task_id else f"PIDONLY:{pid_meta.stem}"
        rows.append(
            {
                "key": key,
                "task_id": task_id,
                "owner": owner,
                "scope": scope,
                "pid": pid,
                "pid_file": str(pid_meta),
                "worktree": worktree,
                "tmux_session": tmux_session,
                "launch_backend": launch_backend,
                "log_file": log_file,
            }
        )
    return rows


def load_lock_inventory(lock_dir: str | Path) -> list[dict[str, Any]]:
    base = Path(lock_dir)
    rows: list[dict[str, Any]] = []
    if not base.exists():
        return rows

    for lock_meta in sorted(base.glob("*.lock")):
        task_id = read_field(lock_meta, "task_id")
        owner = read_field(lock_meta, "owner")
        scope = read_field(lock_meta, "scope")
        worktree = read_field(lock_meta, "worktree")

        key = task_id if task_id else f"LOCKONLY:{scope}:{owner}:{lock_meta.name}"
        rows.append(
            {
                "key": key,
                "task_id": task_id,
                "owner": owner,
                "scope": scope,
                "lock_file": str(lock_meta),
                "worktree": worktree,
            }
        )
    return rows


def classify_records(pid_rows: list[dict[str, Any]], lock_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_key: dict[str, dict[str, Any]] = {}

    for row in pid_rows:
        by_key.setdefault(row["key"], {})["pid"] = row
    for row in lock_rows:
        by_key.setdefault(row["key"], {})["lock"] = row

    records: list[dict[str, Any]] = []

    for key in sorted(by_key.keys()):
        combined = by_key[key]
        pid_row = combined.get("pid", {})
        lock_row = combined.get("lock", {})

        task_id = pid_row.get("task_id") or lock_row.get("task_id") or key
        owner = pid_row.get("owner") or lock_row.get("owner") or ""
        scope = pid_row.get("scope") or lock_row.get("scope") or ""
        worktree = pid_row.get("worktree") or lock_row.get("worktree") or ""

        pid = pid_row.get("pid", "")
        pid_file = pid_row.get("pid_file", "")
        lock_file = lock_row.get("lock_file", "")
        tmux_session = pid_row.get("tmux_session", "")
        launch_backend = pid_row.get("launch_backend", "")
        log_file = pid_row.get("log_file", "")

        pid_alive = bool(pid_file) and is_pid_alive(pid)
        worktree_exists = bool(worktree) and Path(worktree).exists()

        state = "UNKNOWN"
        if worktree and not worktree_exists:
            if lock_file and not pid_file:
                state = "ORPHAN_LOCK"
            elif pid_file and not lock_file:
                state = "ORPHAN_PID"
            else:
                state = "MISSING_WORKTREE"
        elif pid_file and lock_file and pid_alive:
            state = "RUNNING"
        elif pid_file and lock_file:
            state = "LOCK_STALE"
        elif pid_file and not lock_file and pid_alive:
            state = "FINALIZING"
        elif pid_file and not lock_file:
            state = "FINALIZING_EXITED"
        elif lock_file:
            # Lock-only is valid for manual work in a dedicated worktree.
            state = "LOCKED"

        stale = is_stale_state(state)

        records.append(
            {
                "key": key,
                "task_id": task_id,
                "owner": owner,
                "scope": scope,
                "state": state,
                "pid": int(pid) if pid.isdigit() else None,
                "pid_alive": pid_alive,
                "pid_file": pid_file or None,
                "lock_file": lock_file or None,
                "worktree": worktree or None,
                "tmux_session": tmux_session or None,
                "launch_backend": launch_backend or None,
                "log_file": log_file or None,
                "worktree_exists": worktree_exists,
                "stale": stale,
            }
        )

    return records


def summarize(records: list[dict[str, Any]]) -> dict[str, Any]:
    counts: dict[str, int] = {}
    for item in records:
        state = item["state"]
        counts[state] = counts.get(state, 0) + 1

    return {
        "total": len(records),
        "state_counts": counts,
    }
