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
    ctx = resolve_context(repo_root, config, args.state_dir, config_path=config_path)
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
            active_by_task[task_id] = {"reason": "active_worker", "source": "pid"}
        elif has_lock and task_id not in active_by_task:
            active_by_task[task_id] = {"reason": "active_lock", "source": "lock"}

    for task_id, rows in task_active_records.items():
        if len(rows) <= 1:
            continue

        owner_keys = {owner_key(str(r.get("owner") or "")) for r in rows if str(r.get("owner") or "")}
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

    max_start = args.max_start if args.max_start is not None else int(ctx["runtime"]["max_start"])

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


def _status_payload(args: argparse.Namespace) -> dict[str, Any]:
    ready_payload = _ready_payload(args)
    inventory_payload = _inventory_payload(args)
    task_board_payload = _task_board_payload(args)

    counts = inventory_payload.get("summary", {}).get("state_counts", {})
    stale_total = sum(
        counts.get(k, 0)
        for k in ["LOCK_STALE", "FINALIZING_EXITED", "ORPHAN_LOCK", "ORPHAN_PID", "MISSING_WORKTREE"]
    )
    active_total = sum(counts.get(k, 0) for k in ["RUNNING", "LOCKED", "FINALIZING"])

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
        lines.append(f"  [READY] {item.get('task_id', '')} owner={item.get('owner', '')} deps={item.get('deps', '')}")
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
    lines.append(f"Coordination: locks={coordination.get('summary', {}).get('locks', 0)}")
    for lock in active_locks:
        lines.append(f"  [LOCK] scope={lock.get('scope', '')} owner={lock.get('owner', '')} task={lock.get('task_id', '')}")

    return "\n".join(lines)


def _run_status_tui(args: argparse.Namespace, initial_payload: dict[str, Any]) -> None:
    try:
        from textual.app import App, ComposeResult
        from textual.containers import VerticalScroll
        from textual.widgets import DataTable, Footer, Header, Static
    except ModuleNotFoundError:
        die("Textual is not installed. Install with: pip install textual")

    refresh_seconds = 2.0

    class StatusTui(App[None]):
        CSS = """
        Screen {
            layout: vertical;
        }

        #meta {
            padding: 0 1;
            height: auto;
            content-align: left middle;
        }

        VerticalScroll {
            height: 1fr;
        }

        DataTable {
            margin: 0 1 1 1;
            height: auto;
            min-height: 6;
        }

        #task_table {
            margin: 0 1 0 1;
            height: 10;
        }
        """
        BINDINGS = [("q", "quit", "Quit"), ("escape", "quit", "Quit"), ("t", "toggle_tasks", "Tasks")]

        def __init__(self) -> None:
            super().__init__()
            self.current_payload: dict[str, Any] = initial_payload
            self.last_error: str = ""
            self.task_board_visible = False

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            yield Static(id="meta")
            with VerticalScroll(id="main_scroll"):
                yield DataTable(id="ready_table")
                yield DataTable(id="excluded_table")
                yield DataTable(id="runtime_table")
                yield DataTable(id="lock_table")
            yield DataTable(id="task_table")
            yield Footer()

        @staticmethod
        def _fill_table(table: DataTable, rows: list[tuple[str, ...]], fallback: tuple[str, ...]) -> None:
            table.clear()
            if rows:
                for row in rows:
                    table.add_row(*row)
            else:
                table.add_row(*fallback)

        def _render_payload(self) -> None:
            payload = self.current_payload
            scheduler = payload.get("scheduler", {})
            runtime = payload.get("runtime", {})
            coordination = payload.get("coordination", {})
            task_board = payload.get("task_board", {})

            meta = self.query_one("#meta", Static)
            refreshed_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            meta_lines = [
                f"repo={payload.get('repo_root', '')}",
                f"state_dir={payload.get('state_dir', '')}",
                (
                    f"trigger={scheduler.get('trigger', 'manual')} "
                    f"max_start={scheduler.get('max_start', 0)} "
                    f"tasks={task_board.get('summary', {}).get('total', 0)}"
                ),
                f"last_refresh={refreshed_at}",
            ]
            if self.last_error:
                meta_lines.append(f"last_error={self.last_error}")
            meta.update("\n".join(meta_lines))

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
            self._fill_table(ready_table, ready_rows, ("-", "-", "-", "-"))

            excluded_table = self.query_one("#excluded_table", DataTable)
            excluded_rows = [
                (
                    str(item.get("task_id", "")),
                    str(item.get("owner", "")),
                    str(item.get("reason", "")),
                    str(item.get("source", "")),
                )
                for item in scheduler.get("excluded_tasks", [])
            ]
            self._fill_table(excluded_table, excluded_rows, ("-", "-", "-", "-"))

            runtime_table = self.query_one("#runtime_table", DataTable)
            counts = runtime.get("summary", {}).get("state_counts", {})
            runtime_rows = [(str(state), str(count)) for state, count in sorted(counts.items(), key=lambda x: x[0])]
            self._fill_table(runtime_table, runtime_rows, ("NONE", "0"))

            lock_table = self.query_one("#lock_table", DataTable)
            lock_rows = [
                (
                    str(lock.get("scope", "")),
                    str(lock.get("owner", "")),
                    str(lock.get("task_id", "")),
                )
                for lock in coordination.get("active_locks", [])
            ]
            self._fill_table(lock_table, lock_rows, ("-", "-", "-"))

            task_table = self.query_one("#task_table", DataTable)
            task_rows = [
                (
                    str(item.get("task_id", "")),
                    str(item.get("title", "")),
                    str(item.get("owner", "")),
                    str(item.get("scope", "")),
                    str(item.get("status", "")),
                    str(item.get("deps", "")),
                )
                for item in reversed(task_board.get("tasks", []))
            ]
            self._fill_table(task_table, task_rows, ("-", "-", "-", "-", "-", "-"))

            task_state = "shown" if self.task_board_visible else "hidden"
            subtitle = f"Press q to quit | Task board: {task_state} (toggle: t) | Auto-refresh: {refresh_seconds:.0f}s"
            if self.last_error:
                subtitle = f"{subtitle} | Last refresh failed"
            self.sub_title = subtitle

        def _refresh_payload(self) -> None:
            try:
                self.current_payload = _status_payload(args)
                self.last_error = ""
            except SystemExit as err:
                self.last_error = str(err) or "status refresh failed"
            except Exception as err:
                self.last_error = str(err)
            self._render_payload()

        def on_mount(self) -> None:
            self.title = "codex-teams status"
            self.sub_title = "Press q to quit | Task board: hidden (toggle: t)"

            ready_table = self.query_one("#ready_table", DataTable)
            ready_table.zebra_stripes = True
            ready_table.add_columns("READY task", "Owner", "Scope", "Deps")

            excluded_table = self.query_one("#excluded_table", DataTable)
            excluded_table.zebra_stripes = True
            excluded_table.add_columns("EXCLUDED task", "Owner", "Reason", "Source")

            runtime_table = self.query_one("#runtime_table", DataTable)
            runtime_table.zebra_stripes = True
            runtime_table.add_columns("Runtime state", "Count")

            lock_table = self.query_one("#lock_table", DataTable)
            lock_table.zebra_stripes = True
            lock_table.add_columns("Lock scope", "Owner", "Task")

            task_table = self.query_one("#task_table", DataTable)
            task_table.zebra_stripes = True
            task_table.add_columns("Task", "Title", "Owner", "Scope", "Status", "Deps")
            task_table.display = False

            self._render_payload()
            self.set_interval(refresh_seconds, self._refresh_payload)

        def action_toggle_tasks(self) -> None:
            task_table = self.query_one("#task_table", DataTable)
            self.task_board_visible = not self.task_board_visible
            task_table.display = self.task_board_visible
            self._render_payload()

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
        p.add_argument("--state-dir", dest="state_dir", help="State directory override")
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
    p_status.add_argument("--format", choices=["text", "json", "tui"], default="text")
    p_status.set_defaults(fn=cmd_status)

    p_inventory = sub.add_parser("inventory")
    add_common(p_inventory)
    p_inventory.add_argument("--format", choices=["json", "tsv"], default="json")
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
