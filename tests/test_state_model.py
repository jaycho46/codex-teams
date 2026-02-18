import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "py"))

import state_model


class StateModelTests(unittest.TestCase):
    def test_state_helper_sets(self) -> None:
        self.assertTrue(state_model.is_active_state("RUNNING"))
        self.assertTrue(state_model.is_active_state("LOCKED"))
        self.assertFalse(state_model.is_active_state("LOCK_STALE"))

        self.assertTrue(state_model.is_stale_state("LOCK_STALE"))
        self.assertTrue(state_model.is_stale_state("ORPHAN_LOCK"))
        self.assertFalse(state_model.is_stale_state("RUNNING"))

    def test_load_inventory_from_metadata_files(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            orch = base / "orchestrator"
            lock = base / "locks"
            orch.mkdir(parents=True, exist_ok=True)
            lock.mkdir(parents=True, exist_ok=True)

            (orch / "worker.pid").write_text(
                """
task_id=T1-001
owner=AgentA
scope=app-shell
pid=123
worktree=/tmp/wt
tmux_session=tmux-1
launch_backend=tmux
log_file=/tmp/wt.log
""".strip()
                + "\n",
                encoding="utf-8",
            )
            (lock / "app-shell.lock").write_text(
                """
owner=AgentA
scope=app-shell
task_id=T1-001
worktree=/tmp/wt
""".strip()
                + "\n",
                encoding="utf-8",
            )

            pid_rows = state_model.load_pid_inventory(orch)
            lock_rows = state_model.load_lock_inventory(lock)

            self.assertEqual(len(pid_rows), 1)
            self.assertEqual(pid_rows[0]["task_id"], "T1-001")
            self.assertEqual(pid_rows[0]["key"], "T1-001")
            self.assertEqual(pid_rows[0]["pid"], "123")
            self.assertEqual(pid_rows[0]["launch_backend"], "tmux")
            self.assertEqual(pid_rows[0]["log_file"], "/tmp/wt.log")

            self.assertEqual(len(lock_rows), 1)
            self.assertEqual(lock_rows[0]["task_id"], "T1-001")
            self.assertEqual(lock_rows[0]["key"], "T1-001")

    def test_classify_records_maps_active_and_stale_states(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            existing = base / "existing"
            existing.mkdir(parents=True, exist_ok=True)
            missing = base / "missing"

            pid_rows = [
                {
                    "key": "T1-001",
                    "task_id": "T1-001",
                    "owner": "AgentA",
                    "scope": "app-shell",
                    "pid": "101",
                    "pid_file": "T1.pid",
                    "worktree": str(existing),
                    "tmux_session": "",
                    "launch_backend": "tmux",
                    "log_file": "/tmp/t1.log",
                },
                {
                    "key": "T3-001",
                    "task_id": "T3-001",
                    "owner": "AgentC",
                    "scope": "provider-openai",
                    "pid": "301",
                    "pid_file": "T3.pid",
                    "worktree": str(existing),
                    "tmux_session": "",
                    "launch_backend": "tmux",
                    "log_file": "/tmp/t3.log",
                },
                {
                    "key": "T4-001",
                    "task_id": "T4-001",
                    "owner": "AgentD",
                    "scope": "ui-popover",
                    "pid": "401",
                    "pid_file": "T4.pid",
                    "worktree": str(existing),
                    "tmux_session": "",
                    "launch_backend": "tmux",
                    "log_file": "/tmp/t4.log",
                },
                {
                    "key": "T6-001",
                    "task_id": "T6-001",
                    "owner": "AgentE",
                    "scope": "ci-release",
                    "pid": "601",
                    "pid_file": "T6.pid",
                    "worktree": str(missing),
                    "tmux_session": "",
                    "launch_backend": "tmux",
                    "log_file": "/tmp/t6.log",
                },
                {
                    "key": "T7-001",
                    "task_id": "T7-001",
                    "owner": "AgentA",
                    "scope": "app-shell",
                    "pid": "701",
                    "pid_file": "T7.pid",
                    "worktree": str(missing),
                    "tmux_session": "",
                    "launch_backend": "tmux",
                    "log_file": "/tmp/t7.log",
                },
                {
                    "key": "T9-001",
                    "task_id": "T9-001",
                    "owner": "AgentB",
                    "scope": "domain-core",
                    "pid": "901",
                    "pid_file": "T9.pid",
                    "worktree": str(existing),
                    "tmux_session": "",
                    "launch_backend": "tmux",
                    "log_file": "/tmp/t9.log",
                },
            ]
            lock_rows = [
                {
                    "key": "T1-001",
                    "task_id": "T1-001",
                    "owner": "AgentA",
                    "scope": "app-shell",
                    "lock_file": "T1.lock",
                    "worktree": str(existing),
                },
                {
                    "key": "T2-001",
                    "task_id": "T2-001",
                    "owner": "AgentB",
                    "scope": "domain-core",
                    "lock_file": "T2.lock",
                    "worktree": str(existing),
                },
                {
                    "key": "T5-001",
                    "task_id": "T5-001",
                    "owner": "AgentD",
                    "scope": "ui-popover",
                    "lock_file": "T5.lock",
                    "worktree": str(missing),
                },
                {
                    "key": "T7-001",
                    "task_id": "T7-001",
                    "owner": "AgentA",
                    "scope": "app-shell",
                    "lock_file": "T7.lock",
                    "worktree": str(missing),
                },
                {
                    "key": "T9-001",
                    "task_id": "T9-001",
                    "owner": "AgentB",
                    "scope": "domain-core",
                    "lock_file": "T9.lock",
                    "worktree": str(existing),
                },
            ]

            alive_pids = {"101", "301", "601", "701"}
            with patch.object(state_model, "is_pid_alive", side_effect=lambda pid: pid in alive_pids):
                records = state_model.classify_records(pid_rows, lock_rows)

            by_task = {row["task_id"]: row for row in records}

            self.assertEqual(by_task["T1-001"]["state"], "RUNNING")
            self.assertEqual(by_task["T2-001"]["state"], "LOCKED")
            self.assertEqual(by_task["T3-001"]["state"], "FINALIZING")
            self.assertEqual(by_task["T4-001"]["state"], "FINALIZING_EXITED")
            self.assertEqual(by_task["T5-001"]["state"], "ORPHAN_LOCK")
            self.assertEqual(by_task["T6-001"]["state"], "ORPHAN_PID")
            self.assertEqual(by_task["T7-001"]["state"], "MISSING_WORKTREE")
            self.assertEqual(by_task["T9-001"]["state"], "LOCK_STALE")
            self.assertEqual(by_task["T1-001"]["launch_backend"], "tmux")
            self.assertEqual(by_task["T1-001"]["log_file"], "/tmp/t1.log")

            summary = state_model.summarize(records)
            self.assertEqual(summary["state_counts"]["RUNNING"], 1)
            self.assertEqual(summary["state_counts"]["LOCK_STALE"], 1)


if __name__ == "__main__":
    unittest.main()
