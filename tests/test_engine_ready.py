import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "scripts" / "py" / "engine.py"


def _run_engine(repo_root: Path, *args: str) -> dict:
    proc = subprocess.run(
        [sys.executable, str(ENGINE), *args, "--repo", str(repo_root)],
        check=True,
        capture_output=True,
        text=True,
    )
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


def _write_lock(coord_dir: Path, filename: str, owner: str, scope: str, task_id: str, worktree: Path) -> None:
    lock_dir = coord_dir / "locks"
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
    coord_dir: Path,
    filename: str,
    owner: str,
    scope: str,
    task_id: str,
    pid: int,
    worktree: Path,
) -> None:
    orch_dir = coord_dir / "orchestrator"
    orch_dir.mkdir(parents=True, exist_ok=True)
    (orch_dir / filename).write_text(
        "\n".join(
            [
                f"owner={owner}",
                f"scope={scope}",
                f"task_id={task_id}",
                f"pid={pid}",
                f"worktree={worktree}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


class EngineReadyTests(unittest.TestCase):
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

            coord_dir = repo_root / ".coord"
            _write_lock(coord_dir, "app-shell.lock", "AgentA", "app-shell", "T1-001", repo_root)
            _write_pid(coord_dir, "worker-active.pid", "AgentA", "app-shell", "T1-001", os.getpid(), repo_root)

            _write_lock(coord_dir, "ui-popover.lock", "AgentD", "ui-popover", "T1-005", repo_root)
            _write_pid(coord_dir, "worker-stale.pid", "AgentD", "ui-popover", "T1-005", 99999999, repo_root)

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

            payload = _run_engine(repo_root, "status", "--format", "json")

            self.assertIn("scheduler", payload)
            self.assertIn("runtime", payload)
            self.assertIn("coordination", payload)

            self.assertEqual(payload["scheduler"]["summary"]["ready"], 1)
            self.assertEqual(payload["scheduler"]["summary"]["excluded"], 0)
            self.assertEqual(payload["runtime"]["summary"]["active"], 0)
            self.assertEqual(payload["coordination"]["summary"]["locks"], 0)


if __name__ == "__main__":
    unittest.main()
