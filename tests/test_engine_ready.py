import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "scripts" / "py" / "engine.py"


def _run_engine_raw(repo_root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(ENGINE), *args, "--repo", str(repo_root)],
        check=True,
        capture_output=True,
        text=True,
    )


def _run_engine(repo_root: Path, *args: str) -> dict:
    proc = _run_engine_raw(repo_root, *args)
    return json.loads(proc.stdout)


def _init_git_repo(repo_root: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=repo_root, check=True)


def _write_todo(repo_root: Path, rows: list[tuple[str, str, str, str, str, str]]) -> None:
    table = [
        "# TODO Board",
        "",
        "| ID | Title | Owner | Deps | Notes | Status |",
        "|---|---|---|---|---|---|",
    ]
    for row in rows:
        table.append(f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} | {row[4]} | {row[5]} |")
    (repo_root / "TODO.md").write_text("\n".join(table) + "\n", encoding="utf-8")


def _write_specs(repo_root: Path, task_ids: list[str]) -> None:
    spec_dir = repo_root / "tasks" / "specs"
    spec_dir.mkdir(parents=True, exist_ok=True)
    for task_id in task_ids:
        (spec_dir / f"{task_id}.md").write_text(
            "\n".join(
                [
                    f"# Task Spec: {task_id}",
                    "",
                    "## Goal",
                    f"Deliver {task_id}.",
                    "",
                    "## In Scope",
                    "- implement task behavior",
                    "",
                    "## Acceptance Criteria",
                    "- [ ] criteria one",
                    "- [ ] criteria two",
                ]
            )
            + "\n",
            encoding="utf-8",
        )


def _write_lock(state_dir: Path, filename: str, owner: str, scope: str, task_id: str, worktree: Path) -> None:
    lock_dir = state_dir / "locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    (lock_dir / filename).write_text(
        "\n".join(
            [
                f"owner={owner}",
                f"scope={scope}",
                f"task_id={task_id}",
                f"worktree={worktree}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


def _write_pid(
    state_dir: Path,
    filename: str,
    owner: str,
    scope: str,
    task_id: str,
    pid: int,
    worktree: Path,
    launch_backend: str = "tmux",
    tmux_session: str = "tmux-session",
    log_file: str = "/tmp/codex-tasks.log",
) -> None:
    orch_dir = state_dir / "orchestrator"
    orch_dir.mkdir(parents=True, exist_ok=True)
    (orch_dir / filename).write_text(
        "\n".join(
            [
                f"owner={owner}",
                f"scope={scope}",
                f"task_id={task_id}",
                f"pid={pid}",
                f"worktree={worktree}",
                f"launch_backend={launch_backend}",
                f"tmux_session={tmux_session}",
                f"log_file={log_file}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


class EngineReadyTests(unittest.TestCase):
    def test_status_bootstrap_creates_canonical_todo_template(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            _init_git_repo(repo_root)

            payload = _run_engine(repo_root, "status", "--format", "json")
            self.assertIn("task_board", payload)

            todo_text = (repo_root / "TODO.md").read_text(encoding="utf-8")
            self.assertIn("| ID | Title | Owner | Deps | Notes | Status |", todo_text)
            self.assertNotIn("| Area | ID | Title | Owner | Deps | Notes | Status |", todo_text)

    def test_status_bootstrap_rewrites_legacy_empty_todo_template(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            _init_git_repo(repo_root)

            (repo_root / "TODO.md").write_text(
                "\n".join(
                    [
                        "# TODO Board",
                        "",
                        "| Area | ID | Title | Owner | Deps | Notes | Status |",
                        "|---|---|---|---|---|---|---|",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            payload = _run_engine(repo_root, "status", "--format", "json")
            self.assertIn("task_board", payload)

            todo_text = (repo_root / "TODO.md").read_text(encoding="utf-8")
            self.assertIn("| ID | Title | Owner | Deps | Notes | Status |", todo_text)
            self.assertNotIn("| Area | ID | Title | Owner | Deps | Notes | Status |", todo_text)

    def test_ready_selection_excludes_active_owner_busy_and_unready_deps(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            _init_git_repo(repo_root)

            _write_todo(
                repo_root,
                [
                    ("T1-001", "active task", "AgentA", "-", "", "TODO"),
                    ("T1-002", "same owner", "AgentA", "-", "", "TODO"),
                    ("T1-003", "deps blocked", "AgentB", "T9-999", "", "TODO"),
                    ("T1-004", "ready task", "AgentC", "-", "", "TODO"),
                    ("T1-005", "stale metadata", "AgentD", "-", "", "TODO"),
                ],
            )
            _write_specs(repo_root, ["T1-001", "T1-002", "T1-003", "T1-004", "T1-005"])

            state_dir = repo_root / ".state"
            _write_lock(state_dir, "app-shell.lock", "AgentA", "app-shell", "T1-001", repo_root)
            _write_pid(state_dir, "worker-active.pid", "AgentA", "app-shell", "T1-001", os.getpid(), repo_root)

            _write_lock(state_dir, "ui-popover.lock", "AgentD", "ui-popover", "T1-005", repo_root)
            _write_pid(state_dir, "worker-stale.pid", "AgentD", "ui-popover", "T1-005", 99999999, repo_root)

            payload = _run_engine(repo_root, "ready")

            ready_ids = {item["task_id"] for item in payload["ready_tasks"]}
            excluded = {item["task_id"]: item for item in payload["excluded_tasks"]}

            self.assertIn("T1-004", ready_ids)
            self.assertIn("T1-005", ready_ids)

            self.assertEqual(excluded["T1-001"]["reason"], "active_worker")
            self.assertEqual(excluded["T1-001"]["source"], "pid")
            self.assertEqual(excluded["T1-002"]["reason"], "owner_busy")
            self.assertEqual(excluded["T1-003"]["reason"], "deps_not_ready")

    def test_status_payload_contains_unified_sections(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            _init_git_repo(repo_root)

            _write_todo(
                repo_root,
                [
                    ("T2-001", "ready", "AgentA", "-", "", "TODO"),
                ],
            )
            _write_specs(repo_root, ["T2-001"])

            payload = _run_engine(repo_root, "status", "--format", "json")

            self.assertIn("state_dir", payload)
            self.assertIn("scheduler", payload)
            self.assertIn("runtime", payload)
            self.assertIn("coordination", payload)
            self.assertIn("task_board", payload)

            self.assertEqual(payload["scheduler"]["summary"]["ready"], 1)
            self.assertEqual(payload["scheduler"]["summary"]["excluded"], 0)
            self.assertEqual(payload["runtime"]["summary"]["active"], 0)
            self.assertEqual(payload["coordination"]["summary"]["locks"], 0)
            self.assertEqual(payload["task_board"]["summary"]["total"], 1)
            self.assertEqual(payload["task_board"]["tasks"][0]["task_id"], "T2-001")
            self.assertEqual(payload["task_board"]["tasks"][0]["status"], "TODO")

    def test_status_tui_falls_back_to_text_in_non_interactive_mode(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            _init_git_repo(repo_root)

            _write_todo(
                repo_root,
                [
                    ("T3-001", "ready", "AgentA", "-", "", "TODO"),
                ],
            )
            _write_specs(repo_root, ["T3-001"])

            proc = _run_engine_raw(repo_root, "status", "--format", "tui")

            self.assertIn("Scheduler: ready=1 excluded=0", proc.stdout)
            self.assertIn("Runtime: total=0 active=0 stale=0", proc.stdout)
            self.assertIn("Coordination: locks=0", proc.stdout)

    def test_status_payload_exposes_worker_backend_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            _init_git_repo(repo_root)

            _write_todo(
                repo_root,
                [
                    ("T6-001", "running", "AgentA", "-", "", "TODO"),
                ],
            )
            _write_specs(repo_root, ["T6-001"])

            state_dir = repo_root / ".state"
            _write_lock(state_dir, "app-shell.lock", "AgentA", "app-shell", "T6-001", repo_root)
            _write_pid(
                state_dir,
                "worker.pid",
                "AgentA",
                "app-shell",
                "T6-001",
                os.getpid(),
                repo_root,
                launch_backend="tmux",
                tmux_session="session-t6",
                log_file="/tmp/t6.log",
            )

            payload = _run_engine(repo_root, "status", "--format", "json")
            worker = payload["runtime"]["workers"][0]
            self.assertEqual(worker["launch_backend"], "tmux")
            self.assertEqual(worker["tmux_session"], "session-t6")
            self.assertEqual(worker["log_file"], "/tmp/t6.log")

    def test_ready_excludes_task_when_spec_missing(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            _init_git_repo(repo_root)

            _write_todo(
                repo_root,
                [
                    ("T4-001", "needs spec", "AgentA", "-", "", "TODO"),
                ],
            )

            payload = _run_engine(repo_root, "ready")

            self.assertEqual(payload["ready_tasks"], [])
            self.assertEqual(payload["excluded_tasks"][0]["task_id"], "T4-001")
            self.assertEqual(payload["excluded_tasks"][0]["reason"], "missing_task_spec")
            self.assertEqual(payload["excluded_tasks"][0]["source"], "scheduler")

    def test_ready_excludes_task_when_spec_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            _init_git_repo(repo_root)

            _write_todo(
                repo_root,
                [
                    ("T5-001", "invalid spec", "AgentA", "-", "", "TODO"),
                ],
            )

            spec_dir = repo_root / "tasks" / "specs"
            spec_dir.mkdir(parents=True, exist_ok=True)
            (spec_dir / "T5-001.md").write_text(
                "\n".join(
                    [
                        "# Task Spec: T5-001",
                        "",
                        "## Goal",
                        "Goal text.",
                        "",
                        "## In Scope",
                        "- in scope",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            payload = _run_engine(repo_root, "ready")

            self.assertEqual(payload["ready_tasks"], [])
            self.assertEqual(payload["excluded_tasks"][0]["task_id"], "T5-001")
            self.assertEqual(payload["excluded_tasks"][0]["reason"], "invalid_task_spec")
            self.assertEqual(payload["excluded_tasks"][0]["source"], "scheduler")


if __name__ == "__main__":
    unittest.main()
