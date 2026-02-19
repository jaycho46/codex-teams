import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "py"))

from todo_parser import TodoError, build_indexes, deps_ready, parse_todo


SCHEMA = {
    "id_col": 2,
    "title_col": 3,
    "owner_col": 4,
    "deps_col": 5,
    "status_col": 7,
    "gate_regex": r"`(G[0-9]+ \([^)]+\))`",
    "done_keywords": ["DONE", "완료", "Complete", "complete"],
}


class TodoParserTests(unittest.TestCase):
    def test_parse_todo_and_deps(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            todo_path = Path(td) / "TODO.md"
            todo_path.write_text(
                """
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T1-001 | First | AgentA | - | note | DONE |
| T1-002 | Second | AgentB | T1-001,G1 | note | TODO |
| T1-003 | Third | AgentC | G2 | note | TODO |

Gate state: `G1 (DONE)`
Gate state: `G2 (PENDING)`
""".strip()
                + "\n",
                encoding="utf-8",
            )

            tasks, gates = parse_todo(todo_path, SCHEMA)
            task_status = build_indexes(tasks)

            self.assertEqual([t["id"] for t in tasks], ["T1-001", "T1-002", "T1-003"])
            self.assertEqual(gates["G1"], "DONE")
            self.assertEqual(gates["G2"], "PENDING")

            self.assertTrue(deps_ready("T1-001,G1", task_status, gates))
            self.assertFalse(deps_ready("G2", task_status, gates))
            self.assertFalse(deps_ready("UNKNOWN", task_status, gates))
            self.assertTrue(deps_ready("-", task_status, gates))

    def test_missing_todo_file_raises(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            missing = Path(td) / "TODO.md"
            with self.assertRaises(TodoError):
                parse_todo(missing, SCHEMA)

    def test_parse_todo_supports_escaped_pipe_cells(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            todo_path = Path(td) / "TODO.md"
            todo_path.write_text(
                """
# TODO Board

| ID | Title | Owner | Deps | Notes | Status |
|---|---|---|---|---|---|
| T2-001 | Title with \\| pipe | AgentA | - | note with \\| pipe | TODO |
""".strip()
                + "\n",
                encoding="utf-8",
            )

            tasks, _ = parse_todo(todo_path, SCHEMA)
            self.assertEqual(len(tasks), 1)
            self.assertEqual(tasks[0]["id"], "T2-001")
            self.assertEqual(tasks[0]["title"], "Title with | pipe")
            self.assertEqual(tasks[0]["owner"], "AgentA")
            self.assertEqual(tasks[0]["deps"], "-")
            self.assertEqual(tasks[0]["status"], "TODO")


if __name__ == "__main__":
    unittest.main()
