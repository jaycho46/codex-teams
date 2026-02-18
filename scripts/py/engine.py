#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from config import ConfigError, load_config, owner_key, resolve_context
from state_model import (
    classify_records,
    is_active_state,
    load_lock_inventory,
    load_pid_inventory,
    summarize,
)
from task_spec import evaluate_task_spec, task_spec_rel_path
from todo_parser import TodoError, build_indexes, deps_ready, parse_todo


def die(msg: str, code: int = 1) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def resolve_repo_root(repo_arg: str | None) -> Path:
    cmd = ["git"]
    if repo_arg:
        cmd.extend(["-C", repo_arg])
    cmd.extend(["rev-parse", "--show-toplevel"])

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        if repo_arg:
            die(f"--repo is not a git repository: {repo_arg}")
        die("Unable to detect git repository. Run inside a repo or provide --repo.")

    return Path(proc.stdout.strip()).resolve()


def load_ctx(args: argparse.Namespace) -> tuple[dict[str, Any], dict[str, Any], Path]:
    repo_root = resolve_repo_root(args.repo)
    config, config_path = load_config(repo_root, args.config)
    ctx = resolve_context(
        repo_root, config, args.state_dir, config_path=config_path)
    ctx["config_path"] = str(config_path)
    return config, ctx, repo_root


def to_env(ctx: dict[str, Any]) -> str:
    state_dir = ctx["state_dir"]
    plain = {
        "REPO_ROOT": ctx["repo_root"],
        "REPO_NAME": ctx["repo_name"],
        "BASE_BRANCH": ctx["base_branch"],
        "TODO_FILE": ctx["todo_file"],
        "STATE_DIR": state_dir,
        "LOCK_DIR": ctx["lock_dir"],
        "ORCH_DIR": ctx["orch_dir"],
        "UPDATES_FILE": ctx["updates_file"],
        "WORKTREE_PARENT_DIR": ctx["worktree_parent"],
        "MAX_START": str(ctx["runtime"]["max_start"]),
        "LAUNCH_BACKEND": ctx["runtime"]["launch_backend"],
        "AUTO_NO_LAUNCH": "1" if ctx["runtime"]["auto_no_launch"] else "0",
        "CODEX_FLAGS": ctx["runtime"]["codex_flags"],
        "CONFIG_PATH": ctx["config_path"],
        "OWNERS_JSON": json.dumps(ctx["owners"], ensure_ascii=False),
        "OWNERS_BY_KEY_JSON": json.dumps(ctx["owners_by_key"], ensure_ascii=False),
        "TODO_SCHEMA_JSON": json.dumps(ctx["todo"], ensure_ascii=False),
    }
    return "\n".join(f"{k}={shlex.quote(v)}" for k, v in plain.items())


def ensure_todo_file(todo_path: str | Path) -> Path:
    path = Path(todo_path)
    if path.exists():
        return path

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        """# TODO Board

| Area | ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|---|
""",
        encoding="utf-8",
    )
    return path


def cmd_paths(args: argparse.Namespace) -> None:
    _, ctx, _ = load_ctx(args)
    if args.format == "env":
        print(to_env(ctx))
        return

    print(json.dumps(ctx, ensure_ascii=False, indent=2))


def _active_maps(records: list[dict[str, Any]]) -> tuple[dict[str, dict[str, str]], set[str], dict[str, str]]:
    active_by_task: dict[str, dict[str, str]] = {}
    active_owner_keys: set[str] = set()
    conflict_by_task: dict[str, str] = {}

    task_active_records: dict[str, list[dict[str, Any]]] = {}

    for row in records:
        task_id = str(row.get("task_id") or "")
        if not task_id or not is_active_state(str(row.get("state") or "")):
            continue

        task_active_records.setdefault(task_id, []).append(row)

        owner = str(row.get("owner") or "")
        if owner:
            active_owner_keys.add(owner_key(owner))

        has_alive_pid = bool(row.get("pid_alive"))
        has_lock = bool(row.get("lock_file"))
        if has_alive_pid:
            active_by_task[task_id] = {
                "reason": "active_worker", "source": "pid"}
        elif has_lock and task_id not in active_by_task:
            active_by_task[task_id] = {
                "reason": "active_lock", "source": "lock"}

    for task_id, rows in task_active_records.items():
        if len(rows) <= 1:
            continue

        owner_keys = {owner_key(str(r.get("owner") or ""))
                      for r in rows if str(r.get("owner") or "")}
        has_lock = any(bool(r.get("lock_file")) for r in rows)
        has_pid = any(bool(r.get("pid_alive")) for r in rows)
        if has_lock and has_pid:
            if len(owner_keys) > 1 or len(rows) > 1:
                conflict_by_task[task_id] = "active_signal_conflict"

    return active_by_task, active_owner_keys, conflict_by_task


def _ready_payload(args: argparse.Namespace) -> dict[str, Any]:
    _, ctx, _ = load_ctx(args)

    ensure_todo_file(ctx["todo_file"])
    tasks, gates = parse_todo(ctx["todo_file"], ctx["todo"])
    task_status = build_indexes(tasks)

    lock_rows = load_lock_inventory(ctx["lock_dir"])
    pid_rows = load_pid_inventory(ctx["orch_dir"])
    records = classify_records(pid_rows, lock_rows)

    active_by_task, active_owner_keys, conflict_by_task = _active_maps(records)

    running_locks: list[dict[str, str]] = []
    for lock in lock_rows:
        running_locks.append(
            {
                "task_id": lock.get("task_id", ""),
                "owner": lock.get("owner", ""),
                "scope": lock.get("scope", ""),
            }
        )

    max_start = args.max_start if args.max_start is not None else int(
        ctx["runtime"]["max_start"])

    ready_tasks: list[dict[str, str]] = []
    excluded_tasks: list[dict[str, str]] = []
    scheduled_owner_keys: set[str] = set()

    for task in tasks:
        if task["status"] != "TODO":
            continue

        task_id = task["id"]
        owner = task["owner"]
        task_owner_key = owner_key(owner)
        scope = ctx["owners_by_key"].get(task_owner_key)

        if not scope:
            # unmapped owner is intentionally skipped from scheduling
            continue

        if task_id in conflict_by_task:
            excluded_tasks.append(
                {
                    "task_id": task_id,
                    "title": task["title"],
                    "owner": owner,
                    "scope": scope,
                    "deps": task["deps"],
                    "status": task["status"],
                    "reason": "active_signal_conflict",
                    "source": "scheduler",
                }
            )
            continue

        active_signal = active_by_task.get(task_id)
        if active_signal is not None:
            excluded_tasks.append(
                {
                    "task_id": task_id,
                    "title": task["title"],
                    "owner": owner,
                    "scope": scope,
                    "deps": task["deps"],
                    "status": task["status"],
                    "reason": active_signal["reason"],
                    "source": active_signal["source"],
                }
            )
            continue

        if task_owner_key in active_owner_keys or task_owner_key in scheduled_owner_keys:
            excluded_tasks.append(
                {
                    "task_id": task_id,
                    "title": task["title"],
                    "owner": owner,
                    "scope": scope,
                    "deps": task["deps"],
                    "status": task["status"],
                    "reason": "owner_busy",
                    "source": "scheduler",
                }
            )
            continue

        spec = evaluate_task_spec(ctx["repo_root"], task_id)
        if not spec["exists"]:
            excluded_tasks.append(
                {
                    "task_id": task_id,
                    "title": task["title"],
                    "owner": owner,
                    "scope": scope,
                    "deps": task["deps"],
                    "status": task["status"],
                    "reason": "missing_task_spec",
                    "source": "scheduler",
                }
            )
            continue
        if not spec["valid"]:
            excluded_tasks.append(
                {
                    "task_id": task_id,
                    "title": task["title"],
                    "owner": owner,
                    "scope": scope,
                    "deps": task["deps"],
                    "status": task["status"],
                    "reason": "invalid_task_spec",
                    "source": "scheduler",
                }
            )
            continue

        if not deps_ready(task["deps"], task_status, gates):
            excluded_tasks.append(
                {
                    "task_id": task_id,
                    "title": task["title"],
                    "owner": owner,
                    "scope": scope,
                    "deps": task["deps"],
                    "status": task["status"],
                    "reason": "deps_not_ready",
                    "source": "scheduler",
                }
            )
            continue

        ready_tasks.append(
            {
                "task_id": task_id,
                "title": task["title"],
                "owner": owner,
                "owner_key": task_owner_key,
                "scope": scope,
                "deps": task["deps"],
                "status": task["status"],
                "spec_rel_path": str(spec.get("spec_rel_path") or ""),
                "goal_summary": str(spec.get("goal_summary") or ""),
                "in_scope_summary": str(spec.get("in_scope_summary") or ""),
                "acceptance_summary": str(spec.get("acceptance_summary") or ""),
            }
        )
        scheduled_owner_keys.add(task_owner_key)

        if max_start > 0 and len(ready_tasks) >= max_start:
            break

    return {
        "trigger": args.trigger,
        "repo_root": ctx["repo_root"],
        "state_dir": ctx["state_dir"],
        "max_start": max_start,
        "running_locks": running_locks,
        "ready_tasks": ready_tasks,
        "excluded_tasks": excluded_tasks,
    }


def cmd_ready(args: argparse.Namespace) -> None:
    payload = _ready_payload(args)

    if args.format == "tsv":
        for task in payload["ready_tasks"]:
            print(
                "\t".join(
                    [
                        task["task_id"],
                        task["title"],
                        task["owner"],
                        task["scope"],
                        task["deps"],
                        task["status"],
                        str(task.get("spec_rel_path") or ""),
                        str(task.get("goal_summary") or ""),
                        str(task.get("in_scope_summary") or ""),
                        str(task.get("acceptance_summary") or ""),
                    ]
                )
            )
        return

    print(json.dumps(payload, ensure_ascii=False, indent=2))


def _inventory_payload(args: argparse.Namespace) -> dict[str, Any]:
    _, ctx, repo_root = load_ctx(args)

    pid_rows = load_pid_inventory(ctx["orch_dir"])
    lock_rows = load_lock_inventory(ctx["lock_dir"])
    records = classify_records(pid_rows, lock_rows)

    return {
        "repo_root": str(repo_root),
        "state_dir": ctx["state_dir"],
        "scripts": {
            "codex_teams": str(Path(__file__).resolve().parents[1] / "codex-teams"),
        },
        "workers": records,
        "summary": summarize(records),
    }


def cmd_inventory(args: argparse.Namespace) -> None:
    payload = _inventory_payload(args)
    if args.format == "tsv":
        for row in payload["workers"]:
            print(
                "\t".join(
                    [
                        row["key"],
                        row["task_id"],
                        row["owner"],
                        row["scope"],
                        row["state"],
                        str(row["pid"] or ""),
                        "1" if row["pid_alive"] else "0",
                        str(row["pid_file"] or ""),
                        str(row["lock_file"] or ""),
                        str(row["worktree"] or ""),
                        str(row["tmux_session"] or ""),
                        "1" if row["worktree_exists"] else "0",
                        "1" if row["stale"] else "0",
                    ]
                )
            )
        return

    print(json.dumps(payload, ensure_ascii=False, indent=2))


def _task_board_payload(args: argparse.Namespace) -> dict[str, Any]:
    _, ctx, _ = load_ctx(args)

    ensure_todo_file(ctx["todo_file"])
    tasks, _ = parse_todo(ctx["todo_file"], ctx["todo"])

    rows: list[dict[str, str]] = []
    status_counts: dict[str, int] = {}

    for task in tasks:
        status = str(task.get("status") or "")
        owner = str(task.get("owner") or "")
        rows.append(
            {
                "task_id": str(task.get("id") or ""),
                "title": str(task.get("title") or ""),
                "owner": owner,
                "scope": str(ctx["owners_by_key"].get(owner_key(owner), "")),
                "deps": str(task.get("deps") or ""),
                "status": status,
            }
        )
        status_counts[status] = status_counts.get(status, 0) + 1

    return {
        "tasks": rows,
        "summary": {
            "total": len(rows),
            "status_counts": status_counts,
        },
    }


def _parse_markdown_row(line: str) -> list[str] | None:
    text = line.strip()
    if not (text.startswith("|") and text.endswith("|")):
        return None

    cells: list[str] = []
    buf: list[str] = []
    escaped = False
    for ch in text[1:-1]:
        if escaped:
            if ch == "|":
                buf.append("|")
            else:
                buf.append("\\")
                buf.append(ch)
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if ch == "|":
            cells.append("".join(buf).strip())
            buf = []
            continue
        buf.append(ch)
    if escaped:
        buf.append("\\")
    cells.append("".join(buf).strip())
    return cells


def _updates_payload(args: argparse.Namespace, limit: int = 200) -> dict[str, Any]:
    _, ctx, _ = load_ctx(args)
    updates_file = Path(ctx["updates_file"])
    entries: list[dict[str, str]] = []

    if updates_file.exists():
        try:
            lines = updates_file.read_text(encoding="utf-8").splitlines()
        except OSError:
            lines = []
        for line in lines:
            cells = _parse_markdown_row(line)
            if not cells or len(cells) < 5:
                continue
            if cells[0].lower().startswith("timestamp"):
                continue
            if all(not cell or set(cell) <= {"-"} for cell in cells):
                continue
            entries.append(
                {
                    "timestamp": cells[0],
                    "agent": cells[1],
                    "task_id": cells[2],
                    "status": cells[3],
                    "summary": cells[4],
                }
            )

    if limit > 0:
        entries = entries[-limit:]

    ordered_entries = list(reversed(entries))
    return {
        "updates_file": str(updates_file),
        "entries": ordered_entries,
        "summary": {
            "total": len(ordered_entries),
        },
    }


def _status_payload(args: argparse.Namespace) -> dict[str, Any]:
    ready_payload = _ready_payload(args)
    inventory_payload = _inventory_payload(args)
    task_board_payload = _task_board_payload(args)
    updates_payload = _updates_payload(args)

    counts = inventory_payload.get("summary", {}).get("state_counts", {})
    stale_total = sum(
        counts.get(k, 0)
        for k in ["LOCK_STALE", "FINALIZING_EXITED", "ORPHAN_LOCK", "ORPHAN_PID", "MISSING_WORKTREE"]
    )
    active_total = sum(counts.get(k, 0)
                       for k in ["RUNNING", "LOCKED", "FINALIZING"])

    return {
        "repo_root": ready_payload["repo_root"],
        "state_dir": ready_payload["state_dir"],
        "scheduler": {
            "trigger": ready_payload["trigger"],
            "max_start": ready_payload["max_start"],
            "ready_tasks": ready_payload["ready_tasks"],
            "excluded_tasks": ready_payload["excluded_tasks"],
            "summary": {
                "ready": len(ready_payload["ready_tasks"]),
                "excluded": len(ready_payload["excluded_tasks"]),
            },
        },
        "runtime": {
            "summary": {
                "total": inventory_payload.get("summary", {}).get("total", 0),
                "active": active_total,
                "stale": stale_total,
                "state_counts": counts,
            },
            "workers": inventory_payload.get("workers", []),
        },
        "coordination": {
            "active_locks": ready_payload["running_locks"],
            "summary": {
                "locks": len(ready_payload["running_locks"]),
            },
        },
        "task_board": task_board_payload,
        "updates": updates_payload,
    }


def _render_status_text(payload: dict[str, Any]) -> str:
    scheduler = payload.get("scheduler", {})
    runtime = payload.get("runtime", {})
    coordination = payload.get("coordination", {})
    ready_tasks = scheduler.get("ready_tasks", [])
    excluded_tasks = scheduler.get("excluded_tasks", [])
    active_locks = coordination.get("active_locks", [])
    state_counts = runtime.get("summary", {}).get("state_counts", {})

    lines: list[str] = []
    lines.append(f"Repo: {payload.get('repo_root', '')}")
    lines.append(f"State dir: {payload.get('state_dir', '')}")
    lines.append(f"Trigger: {scheduler.get('trigger', 'manual')}")
    lines.append(f"Max start: {scheduler.get('max_start', 0)}")
    lines.append("")

    lines.append(
        "Scheduler: "
        f"ready={scheduler.get('summary', {}).get('ready', 0)} "
        f"excluded={scheduler.get('summary', {}).get('excluded', 0)}"
    )
    for item in ready_tasks:
        lines.append(
            f"  [READY] {item.get('task_id', '')} owner={item.get('owner', '')} deps={item.get('deps', '')}")
    for item in excluded_tasks:
        lines.append(
            f"  [EXCLUDED] {item.get('task_id', '')} owner={item.get('owner', '')} "
            f"reason={item.get('reason', '')} source={item.get('source', '')}"
        )

    lines.append("")
    lines.append(
        "Runtime: "
        f"total={runtime.get('summary', {}).get('total', 0)} "
        f"active={runtime.get('summary', {}).get('active', 0)} "
        f"stale={runtime.get('summary', {}).get('stale', 0)}"
    )
    if state_counts:
        ordered = sorted(state_counts.items(), key=lambda x: x[0])
        lines.append("  states=" + ", ".join(f"{k}:{v}" for k, v in ordered))

    lines.append("")
    lines.append(
        f"Coordination: locks={coordination.get('summary', {}).get('locks', 0)}")
    for lock in active_locks:
        lines.append(
            f"  [LOCK] scope={lock.get('scope', '')} owner={lock.get('owner', '')} task={lock.get('task_id', '')}")

    return "\n".join(lines)


def _run_status_tui(args: argparse.Namespace, initial_payload: dict[str, Any]) -> None:
    try:
        from rich.console import Group
        from rich.text import Text
        from textual.app import App, ComposeResult
        from textual.containers import Grid, Container, Horizontal
        from textual.screen import ModalScreen
        from textual.widgets import Button, DataTable, Static, TabbedContent, TabPane
    except ModuleNotFoundError:
        die("Textual is not installed. Install with: pip install textual")

    try:
        from textual.widgets.markdown import Markdown
    except ImportError:
        Markdown = None  # type: ignore[assignment]

    refresh_seconds = 2.0

    class ActionConfirmModal(ModalScreen[bool]):
        CSS = """
        #confirm_center {
            width: 1fr;
            height: 1fr;
            align: center middle;
        }

        #confirm_dialog {
            width: 68;
            height: auto;
            min-height: 0;
            max-height: 90%;
            border: round $error;
            padding: 1 2;
            layout: vertical;
        }

        #confirm_body {
            height: auto;
        }

        #confirm_actions {
            margin-top: 1;
            align-horizontal: right;
            height: auto;
        }

        #confirm_actions Button {
            margin-left: 1;
        }
        """
        BINDINGS = [("y", "confirm", "Confirm"), ("n", "cancel",
                                                  "Cancel"), ("escape", "cancel", "Cancel")]

        def __init__(self, body_text: str, confirm_text: str, variant: str = "primary") -> None:
            super().__init__()
            self.body_text = body_text
            self.confirm_text = confirm_text
            self.confirm_variant = variant

        def compose(self) -> ComposeResult:
            with Container(id="confirm_center"):
                with Container(id="confirm_dialog"):
                    yield Static(self.body_text, id="confirm_body")
                    with Horizontal(id="confirm_actions"):
                        yield Button("Cancel (N)", id="cancel")
                        yield Button(self.confirm_text, id="confirm", variant=self.confirm_variant)

        def action_confirm(self) -> None:
            self.dismiss(True)

        def action_cancel(self) -> None:
            self.dismiss(False)

        def on_button_pressed(self, event: Button.Pressed) -> None:
            self.dismiss(event.button.id == "confirm")

    class TaskSpecModal(ModalScreen[None]):
        CSS = """
        #spec_center {
            width: 1fr;
            height: 1fr;
            align: center middle;
        }

        #spec_dialog {
            width: 100%;
            max-width: 140;
            height: 100%;
            max-height: 70;
            layout: vertical;
            padding: 1 1;
        }

        #spec_body {
            height: 1fr;
            overflow-y: auto;
            color: #dce9ff;
            border: round #dce9ff;
            padding: 0 1;
        }

        #spec_footer {
            margin-top: 1;
            height: auto;
            width: 100%;
            align-vertical: middle;
        }

        #spec_meta {
            width: 1fr;
            color: #dce9ff;
            content-align: left middle;
        }

        #spec_footer Button {
            margin-left: 1;
        }
        """
        BINDINGS = [
            ("escape", "close_modal", "Close"),
            ("q", "close_modal", "Close"),
            ("enter", "close_modal", "Close"),
        ]

        def __init__(self, task_id: str, spec_path: str, body: str, status: str = "") -> None:
            super().__init__()
            self.task_id = task_id
            self.spec_path = spec_path
            self.body = body
            self.status = status.strip()

        def compose(self) -> ComposeResult:
            meta_text = f"Task: {self.task_id}\nSpec: {self.spec_path}"
            if self.status:
                meta_text = f"{meta_text}\nStatus: {self.status}"
            with Container(id="spec_center"):
                with Container(id="spec_dialog"):
                    if Markdown is not None:
                        yield Markdown(self.body, id="spec_body")
                    else:
                        yield Static(Text(self.body), id="spec_body")
                    with Horizontal(id="spec_footer"):
                        yield Static(
                            Text(
                                meta_text,
                                style="bold #dce9ff",
                            ),
                            id="spec_meta",
                        )
                        yield Button("Close (Enter/Esc)", id="close")

        def action_close_modal(self) -> None:
            self.dismiss(None)

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "close":
                self.dismiss(None)

    class AgentSessionModal(ModalScreen[None]):
        CSS = """
        #agent_session_center {
            width: 1fr;
            height: 1fr;
            align: center middle;
        }

        #agent_session_dialog {
            width: 100%;
            max-width: 160;
            height: 100%;
            max-height: 70;
            layout: vertical;
            padding: 1 1;
        }

        #agent_session_body {
            height: 1fr;
            overflow-y: auto;
            color: #dce9ff;
            border: round #d8bf7c;
            padding: 0 1;
        }

        #agent_session_footer {
            margin-top: 1;
            height: auto;
            width: 100%;
            align-vertical: middle;
        }

        #agent_session_meta {
            width: 1fr;
            color: #dce9ff;
            content-align: left middle;
        }

        #agent_session_footer Button {
            margin-left: 1;
        }
        """

        BINDINGS = [
            ("escape", "close_modal", "Close"),
            ("q", "close_modal", "Close"),
            ("enter", "close_modal", "Close"),
        ]

        def __init__(self, worker: dict[str, Any]) -> None:
            super().__init__()
            self.worker = worker
            self.owner = str(worker.get("owner") or "").strip() or "N/A"
            self.task_id = str(worker.get("task_id") or "").strip() or "N/A"
            self.pid = str(worker.get("pid") or "").strip() or "N/A"
            self.launch_backend = str(worker.get("launch_backend") or "").strip().lower()
            self.tmux_session = str(worker.get("tmux_session") or "").strip()
            self.log_file = str(worker.get("log_file") or "").strip()

        def compose(self) -> ComposeResult:
            backend_display = self.launch_backend or "N/A"
            session_display = self.tmux_session or "N/A"
            log_display = self.log_file or "N/A"
            meta_text = (
                f"Agent: {self.owner}\n"
                f"Task: {self.task_id}\n"
                f"PID: {self.pid}\n"
                f"Backend: {backend_display}\n"
                f"Session: {session_display}\n"
                f"Log: {log_display}"
            )
            with Container(id="agent_session_center"):
                with Container(id="agent_session_dialog"):
                    yield Static(Text("Loading session output..."), id="agent_session_body")
                    with Horizontal(id="agent_session_footer"):
                        yield Static(Text(meta_text, style="bold #dce9ff"), id="agent_session_meta")
                        yield Button("Close (Enter/Esc)", id="close")

        def on_mount(self) -> None:
            self._refresh_body()
            self.set_interval(1.0, self._refresh_body)

        def _refresh_body(self) -> None:
            body_widget = self.query_one("#agent_session_body", Static)

            if self.launch_backend != "tmux" or not self.tmux_session or self.tmux_session == "N/A":
                body_widget.update(
                    Text(
                        "Legacy session is not supported in overlay.\n"
                        "This worker is not running with tmux backend.",
                        style="yellow",
                    )
                )
                return

            has_session = subprocess.run(
                ["tmux", "has-session", "-t", self.tmux_session],
                capture_output=True,
                text=True,
            )
            if has_session.returncode != 0:
                body_widget.update(
                    Text(
                        f"tmux session is not available: {self.tmux_session}",
                        style="yellow",
                    )
                )
                return

            capture = subprocess.run(
                ["tmux", "capture-pane", "-e", "-p", "-t", self.tmux_session, "-S", "-300"],
                capture_output=True,
                text=True,
            )
            if capture.returncode != 0:
                detail = capture.stderr.strip() or capture.stdout.strip() or "unknown error"
                body_widget.update(
                    Text(
                        f"Failed to capture tmux pane: {detail}",
                        style="red",
                    )
                )
                return

            content = capture.stdout.replace("\r", "").rstrip("\n")
            if not content.strip():
                content = "(No output yet)"
            body_widget.update(Text.from_ansi(content))

        def action_close_modal(self) -> None:
            self.dismiss(None)

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "close":
                self.dismiss(None)

    class StatusTui(App[None]):
        ENABLE_COMMAND_PALETTE = False
        CSS = """
        StatusTui {
            background: ansi_default;
        }

        Screen {
            layout: vertical;
            background: ansi_default;
        }

        #dashboard,
        #meta,
        #meta_left,
        #meta_right,
        #ready_table,
        #agents_table,
        #bottom_tabs,
        #task_table,
        #log_table,
        DataTable,
        TabbedContent,
        TabPane {
            background: ansi_default;
        }

        #dashboard {
            layout: grid;
            grid-size: 2 3;
            grid-columns: 1fr 1fr;
            grid-rows: auto 1fr 1fr;
            height: 1fr;
            margin: 0 1 0 1;
        }

        #meta {
            column-span: 2;
            height: 15;
            min-height: 15;
            layout: horizontal;
            color: #dce9ff;
        }

        #meta_left {
            width: 1fr;
            height: 100%;
            min-height: 0;
            overflow-y: auto;
            padding: 1 2;
            content-align: left top;
        }

        #meta_right {
            width: auto;
            height: 100%;
            min-width: 32;
            max-width: 40;
            min-height: 0;
            overflow-y: auto;
            padding: 1;
            content-align: left bottom;
            color: #d6e7ff;
        }

        #ready_table {
            height: 1fr;
            min-height: 0;
            border: round #5d8761;
        }

        #agents_table {
            height: 1fr;
            min-height: 0;
            border: round #9a7a40;
        }

        #bottom_tabs {
            column-span: 2;
            height: 1fr;
            min-height: 0;
            border: round #4d6f99;
        }

        #task_table {
            height: 1fr;
            min-height: 0;
        }

        #log_table {
            height: 1fr;
            min-height: 0;
        }

        """
        BINDINGS = [
            ("q", "quit", "Quit"),
            ("escape", "quit", "Quit"),
            ("1", "show_tasks", "Task"),
            ("2", "show_logs", "Log"),
            ("ctrl+r", "run_start", "Start"),
            ("ctrl+e", "emergency_stop", "Stop-All"),
        ]

        def __init__(self) -> None:
            super().__init__()
            self.current_payload: dict[str, Any] = initial_payload
            self.last_payload_signature = ""
            self.last_error: str = ""
            self.last_action: str = ""
            self.refresh_in_flight = False
            self.active_bottom_tab = "tasks_tab"
            self.running_worker_index: dict[tuple[str, str, str], dict[str, Any]] = {}
            self.agent_modal_open = False

        def compose(self) -> ComposeResult:
            with Grid(id="dashboard"):
                with Horizontal(id="meta"):
                    yield Static(id="meta_left")
                    yield Static(id="meta_right")
                yield DataTable(id="ready_table")
                yield DataTable(id="agents_table")
                with TabbedContent(initial="tasks_tab", id="bottom_tabs"):
                    with TabPane("Task", id="tasks_tab"):
                        yield DataTable(id="task_table")
                    with TabPane("Log", id="log_tab"):
                        yield DataTable(id="log_table")

        @staticmethod
        def _row_key(row: list[Any] | tuple[Any, ...], key_columns: tuple[int, ...]) -> tuple[str, ...]:
            return tuple(str(row[idx]) if idx < len(row) else "" for idx in key_columns)

        @staticmethod
        def _fill_table(
            table: DataTable,
            rows: list[tuple[Any, ...]],
            fallback: tuple[Any, ...],
            key_columns: tuple[int, ...] = (),
        ) -> None:
            had_focus = table.has_focus
            cursor_row = table.cursor_row
            cursor_column = table.cursor_column
            scroll_x = table.scroll_x
            scroll_y = table.scroll_y
            current_key: tuple[str, ...] | None = None
            if key_columns and table.is_valid_row_index(cursor_row):
                try:
                    current_row = table.get_row_at(cursor_row)
                    current_key = StatusTui._row_key(current_row, key_columns)
                except Exception:
                    current_key = None

            table.clear()
            render_rows = rows if rows else [fallback]
            for row in render_rows:
                table.add_row(*row)

            target_row = 0
            if current_key is not None and rows:
                matched_row = None
                for index, row in enumerate(rows):
                    if StatusTui._row_key(row, key_columns) == current_key:
                        matched_row = index
                        break
                if matched_row is not None:
                    target_row = matched_row
                else:
                    target_row = max(0, min(cursor_row, len(render_rows) - 1))
            elif isinstance(cursor_row, int):
                target_row = max(0, min(cursor_row, len(render_rows) - 1))

            column_count = len(table.ordered_columns)
            target_column = 0
            if column_count > 0:
                target_column = max(0, min(cursor_column, column_count - 1))
            table.move_cursor(
                row=target_row, column=target_column, animate=False, scroll=False)
            table.scroll_to(x=scroll_x, y=scroll_y,
                            animate=False, immediate=True, force=True)
            if had_focus:
                table.focus()

        @staticmethod
        def _compact_path(value: str, keep: int = 100) -> str:
            if len(value) <= keep:
                return value
            return f"...{value[-(keep - 3):]}"

        STATUS_TONES: dict[str, str] = {
            "TODO": "cyan",
            "IN_PROGRESS": "yellow",
            "BLOCKED": "red",
            "DONE": "green",
        }

        @classmethod
        def _status_style(cls, value: str, *, dim: bool = False, bold: bool = False) -> str:
            tone = cls.STATUS_TONES.get(value.strip().upper(), "white")
            tokens: list[str] = []
            if dim:
                tokens.append("dim")
            if bold:
                tokens.append("bold")
            tokens.append(tone)
            return " ".join(tokens)

        @classmethod
        def _status_cell(cls, value: str, *, dim: bool = True, bold: bool = False) -> Text:
            return Text(value, style=cls._status_style(value, dim=dim, bold=bold))

        @staticmethod
        def _normalize_task_id(value: Any) -> str:
            text = str(value or "").strip()
            while len(text) >= 2 and text.startswith("`") and text.endswith("`"):
                text = text[1:-1].strip()
            return text.lower()

        @staticmethod
        def _payload_signature(payload: dict[str, Any]) -> str:
            return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

        @staticmethod
        def _ratio_bar(segments: list[tuple[str, int, str]], width: int = 32) -> Text:
            total = sum(max(0, count) for _, count, _ in segments)
            if total <= 0:
                return Text("-" * width, style="dim")

            remaining_total = total
            remaining_width = width
            bar = Text()
            for idx, (symbol, count, style) in enumerate(segments):
                value = max(0, count)
                if idx == len(segments) - 1:
                    units = remaining_width
                else:
                    units = int((value / remaining_total) *
                                remaining_width) if remaining_total > 0 else 0
                    units = max(0, min(remaining_width, units))
                if units > 0:
                    bar.append(symbol * units, style=style)
                remaining_width -= units
                remaining_total -= value

            if remaining_width > 0:
                bar.append("-" * remaining_width, style="dim")
            return bar

        @staticmethod
        def _compact_text(value: str, keep: int = 200) -> str:
            if len(value) <= keep:
                return value
            return f"{value[:keep - 3]}..."

        def _render_payload(self) -> None:
            payload = self.current_payload
            scheduler = payload.get("scheduler", {})
            runtime = payload.get("runtime", {})
            coordination = payload.get("coordination", {})
            task_board = payload.get("task_board", {})
            updates = payload.get("updates", {})
            task_items = list(task_board.get("tasks", []))
            running_workers = [
                worker for worker in runtime.get("workers", []) if bool(worker.get("pid_alive"))
            ]
            active_label = "Task" if self.active_bottom_tab == "tasks_tab" else "Log"
            running_task_ids = {
                task_id
                for task_id in (
                    self._normalize_task_id(worker.get("task_id", "")) for worker in running_workers
                )
                if task_id
            }
            task_ids_in_board: set[str] = set()
            effective_status_counts: dict[str, int] = {
                "DONE": 0,
                "TODO": 0,
                "BLOCKED": 0,
                "IN_PROGRESS": 0,
            }
            for item in task_items:
                normalized_task_id = self._normalize_task_id(item.get("task_id", ""))
                if normalized_task_id:
                    task_ids_in_board.add(normalized_task_id)
                raw_status = str(item.get("status", "")).strip().upper()
                effective_status = (
                    "IN_PROGRESS" if normalized_task_id and normalized_task_id in running_task_ids else raw_status
                )
                if effective_status in effective_status_counts:
                    effective_status_counts[effective_status] += 1

            orphan_running_task_ids = running_task_ids - task_ids_in_board
            if orphan_running_task_ids:
                effective_status_counts["IN_PROGRESS"] += len(orphan_running_task_ids)

            meta = self.query_one("#meta", Horizontal)
            meta_left = self.query_one("#meta_left", Static)
            meta_right = self.query_one("#meta_right", Static)
            refreshed_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            repo_root = str(payload.get("repo_root", ""))
            state_dir = str(payload.get("state_dir", ""))
            running_agents_count = len(running_workers)
            active_locks = coordination.get("active_locks", [])
            tasks_total = len(task_items) + len(orphan_running_task_ids)
            ready_count = int(scheduler.get("summary", {}).get("ready", 0))
            locks_count = int(coordination.get("summary", {}).get("locks", 0))
            done_count = int(effective_status_counts.get("DONE", 0))
            todo_count = int(effective_status_counts.get("TODO", 0))
            blocked_count = int(effective_status_counts.get("BLOCKED", 0))
            in_progress_count = int(effective_status_counts.get("IN_PROGRESS", 0))
            status_total = tasks_total
            ready_ratio = (ready_count / status_total *
                           100.0) if status_total > 0 else 0.0
            running_ratio = (running_agents_count /
                             status_total * 100.0) if status_total > 0 else 0.0
            status_remaining = max(
                0, status_total - ready_count - running_agents_count)
            done_ratio = (done_count / tasks_total *
                          100.0) if tasks_total > 0 else 0.0
            todo_ratio = (todo_count / tasks_total *
                          100.0) if tasks_total > 0 else 0.0
            blocked_ratio = (blocked_count / tasks_total *
                             100.0) if tasks_total > 0 else 0.0
            in_progress_ratio = (in_progress_count / tasks_total *
                                 100.0) if tasks_total > 0 else 0.0
            status_bar = self._ratio_bar(
                [
                    ("◼", ready_count, "bold #5d8761"),
                    ("◼", running_agents_count, "bold #9a7a40"),
                    ("◼", status_remaining, "bold dim"),
                ]
            )
            tasks_bar = self._ratio_bar(
                [
                    ("◼", done_count, self._status_style(
                        "DONE", bold=True, dim=True)),
                    ("◼", todo_count, self._status_style(
                        "TODO", bold=True, dim=True)),
                    ("◼", in_progress_count, self._status_style(
                        "IN_PROGRESS", bold=True, dim=True)),
                    ("◼", blocked_count, self._status_style(
                        "BLOCKED", bold=True, dim=True)),
                ]
            )
            lock_labels: list[str] = []
            for lock in active_locks:
                task_id = str(lock.get("task_id", "")).strip() or "N/A"
                owner = str(lock.get("owner", "")).strip()
                scope = str(lock.get("scope", "")).strip()
                suffix = ""
                if owner or scope:
                    suffix = f"@{owner}/{scope}".rstrip("/")
                lock_labels.append(f"{task_id}{suffix}")
            locks_joined = self._compact_text(
                ", ".join(lock_labels) if lock_labels else "-")
            logo_lines = [
                "░█▀▀░█▀█░█▀▄░█▀▀░█░█░░▀█▀░█▀▀░█▀█░█▄█░█▀▀",
                "░█░░░█░█░█░█░█▀▀░▄▀▄░░░█░░█▀▀░█▀█░█░█░▀▀█",
                "░▀▀▀░▀▀▀░▀▀░░▀▀▀░▀░▀░░░▀░░▀▀▀░▀░▀░▀░▀░▀▀▀",
            ]
            render_lines: list[Text] = [
                Text(line, style="bold") for line in logo_lines]
            render_lines.append(Text(""))
            render_lines.append(
                Text(f"Repo       {self._compact_path(repo_root)}"))
            render_lines.append(
                Text(f"State Dir  {self._compact_path(state_dir)}"))
            render_lines.append(Text(""))
            render_lines.append(
                Text(
                    f"Configs    trigger={scheduler.get('trigger', 'manual')} "
                    f"max_start={scheduler.get('max_start', 0)}",
                    style="dim",
                )
            )
            render_lines.append(Text(""))

            tasks_line = Text("Tasks      ")
            tasks_line.append("[", style="dim")
            tasks_line.append_text(tasks_bar)
            tasks_line.append("]", style="dim")
            tasks_line.append(" (", style="dim")
            tasks_line.append(
                f"done={done_count}",
                style=self._status_style("DONE", bold=False, dim=True),
            )
            tasks_line.append(", ", style="dim")
            tasks_line.append(
                f"todo={todo_count}",
                style=self._status_style("TODO", bold=False, dim=True),
            )
            tasks_line.append(", ", style="dim")
            tasks_line.append(
                f"in_progress={in_progress_count}",
                style=self._status_style("IN_PROGRESS", bold=False, dim=True),
            )
            tasks_line.append(", ", style="dim")
            tasks_line.append(
                f"blocked={blocked_count}",
                style=self._status_style("BLOCKED", bold=False, dim=True),
            )
            tasks_line.append(")", style="dim")
            render_lines.append(tasks_line)

            status_line = Text("Status     ")
            status_line.append("[", style="dim")
            status_line.append_text(status_bar)
            status_line.append("]", style="dim")
            status_line.append(" (", style="dim")
            status_line.append(f"total={status_total}", style="dim")
            status_line.append(", ", style="dim")
            status_line.append(
                f"ready={ready_count}", style="#5d8761")
            status_line.append(", ", style="dim")
            status_line.append(
                f"running={running_agents_count}", style="#9a7a40")
            status_line.append(")", style="dim")
            render_lines.append(status_line)

            render_lines.append(Text(""))
            render_lines.append(
                Text(f"Locks      {locks_joined}", style="#4d6f99"))

            if self.last_error:
                render_lines.append(
                    Text(f"Last Error  {self.last_error}", style="bold red"))

            meta_left.update(Group(*render_lines))

            palette_lines: list[Text] = [
                Text("COMMANDS", style="bold"),
                Text("  Ctrl+R   Run start"),
                Text("  Ctrl+E   Emergency stop"),
                Text("  Enter/Click on Running Agents: Session overlay"),
            ]
            if self.last_error:
                palette_lines.extend(
                    [
                        Text(""),
                        Text("LAST ERROR", style="bold red"),
                        Text(self.last_error, style="red"),
                    ]
                )
            meta_right.update(Group(*palette_lines))
            meta.border_subtitle = f"{refresh_seconds:.0f}s interval"

            ready_table = self.query_one("#ready_table", DataTable)
            ready_rows = [
                (
                    str(item.get("task_id", "")),
                    str(item.get("owner", "")),
                    str(item.get("scope", "")),
                    str(item.get("deps", "")),
                )
                for item in scheduler.get("ready_tasks", [])
            ]
            self._fill_table(ready_table, ready_rows,
                             ("-", "-", "-", "-"), key_columns=(0,))

            agents_table = self.query_one("#agents_table", DataTable)
            active_agents: list[tuple[Any, ...]] = []
            worker_index: dict[tuple[str, str, str], dict[str, Any]] = {}
            for worker in running_workers:
                owner = str(worker.get("owner", ""))
                task_id = str(worker.get("task_id", ""))
                pid = str(worker.get("pid", "") or "")
                active_agents.append(
                    (
                        owner,
                        task_id,
                        self._status_cell("IN_PROGRESS"),
                        pid,
                    )
                )
                worker_index[(owner, task_id, pid)] = worker
            active_agents.sort(key=lambda row: (
                row[0], row[1], str(row[2]), row[3]))
            self.running_worker_index = worker_index
            self._fill_table(agents_table, active_agents,
                             ("-", "-", "-", "-"), key_columns=(0, 1, 3))

            task_table = self.query_one("#task_table", DataTable)
            task_rows: list[tuple[Any, ...]] = []
            repo_root_path = Path(repo_root) if repo_root else None
            for item in reversed(task_items):
                task_id = str(item.get("task_id", ""))
                normalized_task_id = self._normalize_task_id(task_id)
                task_status = "IN_PROGRESS" if normalized_task_id in running_task_ids else str(
                    item.get("status", ""))
                spec_mark = "-"
                if repo_root_path is not None and task_id:
                    try:
                        spec_exists = bool(evaluate_task_spec(
                            repo_root_path, task_id).get("exists"))
                    except Exception:
                        spec_exists = False
                    spec_mark = "O" if spec_exists else "-"
                task_rows.append(
                    (
                        task_id,
                        str(item.get("title", "")),
                        str(item.get("owner", "")),
                        str(item.get("scope", "")),
                        self._status_cell(task_status),
                        spec_mark,
                        str(item.get("deps", "")),
                    )
                )
            self._fill_table(task_table, task_rows, ("-", "-",
                             "-", "-", "-", "-", "-"), key_columns=(0,))

            log_table = self.query_one("#log_table", DataTable)
            log_rows = [
                (
                    str(entry.get("timestamp", "")),
                    str(entry.get("agent", "")),
                    str(entry.get("task_id", "")),
                    self._status_cell(str(entry.get("status", ""))),
                    str(entry.get("summary", "")),
                )
                for entry in updates.get("entries", [])
            ]
            self._fill_table(log_table, log_rows, ("-", "-",
                             "-", "-", "-"), key_columns=(0, 1, 2, 3))

            subtitle = (
                f"Press q to quit | Panel: {active_label} (1=Task, 2=Log) | "
                f"Auto-refresh: {refresh_seconds:.0f}s"
            )
            if self.active_bottom_tab == "tasks_tab":
                subtitle = f"{subtitle} | Enter: open task spec"
            subtitle = f"{subtitle} | Running Agents Enter/Click: session overlay"
            if self.last_error:
                subtitle = f"{subtitle} | Last refresh failed"
            self.sub_title = subtitle

        def _run_emergency_stop(self) -> None:
            cmd = self._codex_teams_cmd()
            cmd.extend(["task", "emergency-stop", "--yes",
                       "--reason", "requested from status tui"])

            proc = subprocess.run(cmd, capture_output=True, text=True)
            if proc.returncode != 0:
                detail = (proc.stderr.strip() or proc.stdout.strip()
                          or f"exit={proc.returncode}")
                first_line = detail.splitlines(
                )[0] if detail else "unknown error"
                self.last_action = ""
                self.last_error = f"emergency-stop failed: {first_line}"
                self._render_payload()
                return

            first_line = next(
                (line.strip() for line in proc.stdout.splitlines() if line.strip()), "")
            self.last_error = ""
            self.last_action = first_line or "Emergency stop executed"
            self._render_payload()
            self._refresh_payload()

        def _codex_teams_cmd(self) -> list[str]:
            cmd = [str(Path(__file__).resolve().parents[1] / "codex-teams")]
            repo_root = str(self.current_payload.get("repo_root", ""))
            state_dir = str(self.current_payload.get("state_dir", ""))
            if repo_root:
                cmd.extend(["--repo", repo_root])
            if state_dir:
                cmd.extend(["--state-dir", state_dir])
            if getattr(args, "config", None):
                cmd.extend(["--config", str(args.config)])
            return cmd

        def _run_start(self) -> None:
            cmd = self._codex_teams_cmd()
            cmd.extend(["run", "start"])
            proc = subprocess.run(cmd, capture_output=True, text=True)
            if proc.returncode != 0:
                detail = (proc.stderr.strip() or proc.stdout.strip()
                          or f"exit={proc.returncode}")
                first_line = detail.splitlines(
                )[0] if detail else "unknown error"
                self.last_action = ""
                self.last_error = f"run start failed: {first_line}"
                self._render_payload()
                return

            first_line = next(
                (line.strip() for line in proc.stdout.splitlines() if line.strip()), "")
            self.last_error = ""
            self.last_action = first_line or "Run start executed"
            self._render_payload()
            self._refresh_payload()

        def _refresh_payload(self) -> None:
            if self.refresh_in_flight:
                return
            self.refresh_in_flight = True
            previous_error = self.last_error
            try:
                next_payload = _status_payload(args)
                next_signature = self._payload_signature(next_payload)
                data_changed = next_signature != self.last_payload_signature
                had_error = bool(previous_error)
                self.current_payload = next_payload
                self.last_payload_signature = next_signature
                self.last_error = ""
                if data_changed or had_error:
                    self._render_payload()
            except SystemExit as err:
                next_error = str(err) or "status refresh failed"
                if next_error != self.last_error:
                    self.last_error = next_error
                    self._render_payload()
            except Exception as err:
                next_error = str(err)
                if next_error != self.last_error:
                    self.last_error = next_error
                    self._render_payload()
            finally:
                self.refresh_in_flight = False

        def _selected_task_id(self) -> str:
            task_table = self.query_one("#task_table", DataTable)
            if not task_table.is_valid_row_index(task_table.cursor_row):
                return ""
            try:
                row = task_table.get_row_at(task_table.cursor_row)
            except Exception:
                return ""
            task_id = str(row[0] if row else "").strip()
            if not task_id or task_id == "-":
                return ""
            return task_id

        def _selected_agent_worker(self) -> dict[str, Any] | None:
            agents_table = self.query_one("#agents_table", DataTable)
            if not agents_table.is_valid_row_index(agents_table.cursor_row):
                return None
            try:
                row = agents_table.get_row_at(agents_table.cursor_row)
            except Exception:
                return None
            owner = str(row[0] if row else "").strip()
            task_id = str(row[1] if row else "").strip()
            pid = str(row[3] if row else "").strip()
            if not owner or owner == "-" or not task_id or task_id == "-":
                return None
            return self.running_worker_index.get((owner, task_id, pid))

        def _open_agent_session(self, worker: dict[str, Any]) -> None:
            if self.agent_modal_open:
                return

            def on_close(_: None) -> None:
                self.agent_modal_open = False

            self.agent_modal_open = True
            self.push_screen(AgentSessionModal(worker), on_close)

        def _open_task_spec(self, task_id: str) -> None:
            repo_root_raw = str(self.current_payload.get("repo_root", "")).strip()
            if not repo_root_raw:
                self.last_error = "cannot resolve repo root for task spec viewer"
                self._render_payload()
                return
            repo_root = Path(repo_root_raw)

            spec_meta = evaluate_task_spec(repo_root, task_id)
            spec_path_raw = str(spec_meta.get("spec_path") or "").strip()
            if not spec_path_raw:
                spec_path_raw = str((repo_root / task_spec_rel_path(task_id)).resolve())
            spec_path = Path(spec_path_raw)

            if not spec_path.exists():
                message = (
                    "# Spec file not found\n\n"
                    "Expected path:\n"
                    f"- `{spec_path}`\n\n"
                    "Create it with one of:\n"
                    f"- `codex-teams task new {task_id} \"task summary\"`\n"
                    f"- `codex-teams task scaffold-specs --task {task_id}`"
                )
                self.push_screen(TaskSpecModal(task_id, str(spec_path), message, status="Missing"))
                return

            try:
                content = spec_path.read_text(encoding="utf-8")
            except OSError as exc:
                message = (
                    "# Failed to read spec file\n\n"
                    f"- Error: `{type(exc).__name__}: {exc}`"
                )
                self.push_screen(TaskSpecModal(task_id, str(spec_path), message, status="Unreadable"))
                return

            validity = "valid" if bool(spec_meta.get("valid")) else "invalid"
            errors = list(spec_meta.get("errors") or [])
            if errors:
                error_lines = ["## Validation errors", ""]
                for err in errors:
                    error_lines.append(f"- {err}")
                error_lines.append("")
                error_lines.append("---")
                prefixed_content = "\n".join(error_lines) + "\n\n" + content
            else:
                prefixed_content = content
            self.push_screen(
                TaskSpecModal(
                    task_id,
                    str(spec_path),
                    prefixed_content,
                    status=("Valid" if validity == "valid" else "Invalid"),
                )
            )

        def on_mount(self) -> None:
            self.title = "codex-teams status"
            self.sub_title = "Press q to quit | Panel: Task (1=Task, 2=Log)"
            meta = self.query_one("#meta", Horizontal)
            meta.border_title = "Overview"
            meta.border_subtitle = "Auto-refresh"

            ready_table = self.query_one("#ready_table", DataTable)
            ready_table.border_title = "Ready Tasks"
            ready_table.border_subtitle = "dependency-cleared queue"
            ready_table.zebra_stripes = True
            ready_table.cursor_type = "row"
            ready_table.add_columns("Task", "Owner", "Scope", "Deps")

            agents_table = self.query_one("#agents_table", DataTable)
            agents_table.border_title = "Running Agents"
            agents_table.border_subtitle = "active worker processes"
            agents_table.zebra_stripes = True
            agents_table.cursor_type = "row"
            agents_table.add_columns("Agent", "Task", "State", "PID")

            task_table = self.query_one("#task_table", DataTable)
            task_table.zebra_stripes = True
            task_table.cursor_type = "row"
            task_table.add_columns(
                "Task", "Title", "Owner", "Scope", "Status", "Spec", "Deps")

            log_table = self.query_one("#log_table", DataTable)
            log_table.zebra_stripes = True
            log_table.cursor_type = "row"
            log_table.add_columns("Timestamp (UTC)", "Agent",
                                  "Task", "Status", "Summary")

            self.last_payload_signature = self._payload_signature(
                self.current_payload)
            self._render_payload()
            self.set_interval(refresh_seconds, self._refresh_payload)

        def action_show_tasks(self) -> None:
            tabs = self.query_one("#bottom_tabs", TabbedContent)
            tabs.active = "tasks_tab"
            self.active_bottom_tab = "tasks_tab"
            self._render_payload()

        def action_show_logs(self) -> None:
            tabs = self.query_one("#bottom_tabs", TabbedContent)
            tabs.active = "log_tab"
            self.active_bottom_tab = "log_tab"
            self._render_payload()

        def action_emergency_stop(self) -> None:
            def on_close(confirmed: bool | None) -> None:
                if confirmed:
                    self._run_emergency_stop()
                else:
                    self.last_action = "Stop-All canceled"
                    self._render_payload()

            self.push_screen(
                ActionConfirmModal(
                    "This action will run:\n\n"
                    "codex-teams task stop --all --apply\n\n"
                    "Are you sure you want to proceed?",
                    "Yes (Y)",
                    variant="error",
                ),
                on_close,
            )

        def action_run_start(self) -> None:
            def on_close(confirmed: bool | None) -> None:
                if confirmed:
                    self._run_start()
                else:
                    self.last_action = "Start canceled"
                    self._render_payload()

            self.push_screen(
                ActionConfirmModal(
                    "This action will run:\n\n"
                    "codex-teams run start\n\n"
                    "Are you sure you want to proceed?",
                    "Yes (Y)",
                    variant="primary",
                ),
                on_close
            )

        def on_tabbed_content_tab_activated(self, event: TabbedContent.TabActivated) -> None:
            if event.tabbed_content.id != "bottom_tabs":
                return
            pane_id = str(getattr(event.pane, "id", "") or "")
            if pane_id in {"tasks_tab", "log_tab"}:
                self.active_bottom_tab = pane_id
                self._render_payload()

        def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
            table_id = getattr(event.data_table, "id", "")
            if table_id == "task_table":
                task_id = self._selected_task_id()
                if not task_id:
                    return
                self._open_task_spec(task_id)
                return
            if table_id == "agents_table":
                worker = self._selected_agent_worker()
                if worker is None:
                    return
                self._open_agent_session(worker)

        def on_data_table_cell_selected(self, event: DataTable.CellSelected) -> None:
            if getattr(event.data_table, "id", "") != "agents_table":
                return
            worker = self._selected_agent_worker()
            if worker is None:
                return
            self._open_agent_session(worker)

    StatusTui().run()


def cmd_status(args: argparse.Namespace) -> None:
    if args.format == "tui":
        # In non-interactive shells (tests/CI), keep deterministic text output.
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            payload = _status_payload(args)
            print(_render_status_text(payload))
            return
        _run_status_tui(args, _status_payload(args))
        return

    payload = _status_payload(args)
    if args.format == "json":
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    print(_render_status_text(payload))


def cmd_select_stop(args: argparse.Namespace) -> None:
    payload = _inventory_payload(args)
    workers = payload["workers"]

    selected: list[dict[str, Any]] = []
    if args.task:
        selected = [w for w in workers if w["task_id"] == args.task]
    elif args.owner:
        want = owner_key(args.owner)
        selected = [w for w in workers if owner_key(w["owner"]) == want]
    elif args.all:
        selected = workers

    if args.format == "tsv":
        for row in selected:
            print(
                "\t".join(
                    [
                        row["key"],
                        row["task_id"],
                        row["owner"],
                        row["scope"],
                        row["state"],
                        str(row["pid"] or ""),
                        "1" if row["pid_alive"] else "0",
                        str(row["pid_file"] or ""),
                        str(row["lock_file"] or ""),
                        str(row["worktree"] or ""),
                        str(row["tmux_session"] or ""),
                        "1" if row["worktree_exists"] else "0",
                    ]
                )
            )
        return

    print(json.dumps({"workers": selected}, ensure_ascii=False, indent=2))


def cmd_select_stale(args: argparse.Namespace) -> None:
    payload = _inventory_payload(args)
    selected = [w for w in payload["workers"] if w["stale"]]

    if args.format == "tsv":
        for row in selected:
            print(
                "\t".join(
                    [
                        row["key"],
                        row["task_id"],
                        row["owner"],
                        row["scope"],
                        row["state"],
                        str(row["pid"] or ""),
                        "1" if row["pid_alive"] else "0",
                        str(row["pid_file"] or ""),
                        str(row["lock_file"] or ""),
                        str(row["worktree"] or ""),
                        str(row["tmux_session"] or ""),
                        "1" if row["worktree_exists"] else "0",
                    ]
                )
            )
        return

    print(json.dumps({"workers": selected}, ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="codex-teams python engine")
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--repo", help="Git repository root or child path")
        p.add_argument("--state-dir", dest="state_dir",
                       help="State directory override")
        p.add_argument("--config", help="Config path override")

    p_paths = sub.add_parser("paths")
    add_common(p_paths)
    p_paths.add_argument("--format", choices=["json", "env"], default="json")
    p_paths.set_defaults(fn=cmd_paths)

    p_ready = sub.add_parser("ready")
    add_common(p_ready)
    p_ready.add_argument("--trigger", default="manual")
    p_ready.add_argument("--max-start", type=int)
    p_ready.add_argument("--format", choices=["json", "tsv"], default="json")
    p_ready.set_defaults(fn=cmd_ready)

    p_status = sub.add_parser("status")
    add_common(p_status)
    p_status.add_argument("--trigger", default="manual")
    p_status.add_argument("--max-start", type=int)
    p_status.add_argument(
        "--format", choices=["text", "json", "tui"], default="text")
    p_status.set_defaults(fn=cmd_status)

    p_inventory = sub.add_parser("inventory")
    add_common(p_inventory)
    p_inventory.add_argument(
        "--format", choices=["json", "tsv"], default="json")
    p_inventory.set_defaults(fn=cmd_inventory)

    p_stop = sub.add_parser("select-stop")
    add_common(p_stop)
    p_stop.add_argument("--task")
    p_stop.add_argument("--owner")
    p_stop.add_argument("--all", action="store_true")
    p_stop.add_argument("--format", choices=["json", "tsv"], default="json")
    p_stop.set_defaults(fn=cmd_select_stop)

    p_stale = sub.add_parser("select-stale")
    add_common(p_stale)
    p_stale.add_argument("--format", choices=["json", "tsv"], default="json")
    p_stale.set_defaults(fn=cmd_select_stale)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if getattr(args, "cmd", "") == "select-stop":
        selected = [bool(args.task), bool(args.owner), bool(args.all)]
        if sum(selected) != 1:
            die("select-stop requires exactly one of --task, --owner, --all")

    try:
        args.fn(args)
    except (ConfigError, TodoError) as exc:
        die(str(exc))


if __name__ == "__main__":
    main()
