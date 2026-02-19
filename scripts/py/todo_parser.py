from __future__ import annotations

import re
from pathlib import Path
from typing import Any


class TodoError(RuntimeError):
    pass


def _field(cols: list[str], col_no: int) -> str:
    idx = col_no - 1
    if idx < 0 or idx >= len(cols):
        return ""
    return cols[idx].strip()


def _parse_markdown_row(line: str) -> list[str] | None:
    text = line.strip()
    if not text.startswith("|") or not text.endswith("|"):
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
    # Preserve split("|") indexing used by schema column numbers.
    return ["", *cells, ""]


def parse_todo(todo_file: str | Path, schema: dict[str, Any]) -> tuple[list[dict[str, str]], dict[str, str]]:
    path = Path(todo_file)
    if not path.exists():
        raise TodoError(f"TODO file not found: {path}")

    lines = path.read_text(encoding="utf-8").splitlines()
    tasks: list[dict[str, str]] = []

    id_col = int(schema["id_col"])
    title_col = int(schema["title_col"])
    owner_col = int(schema["owner_col"])
    deps_col = int(schema["deps_col"])
    status_col = int(schema["status_col"])

    for line in lines:
        cols = _parse_markdown_row(line)
        if cols is None:
            continue

        task_id = _field(cols, id_col)
        title = _field(cols, title_col)
        owner = _field(cols, owner_col)
        deps = _field(cols, deps_col)
        status = _field(cols, status_col)

        if not task_id or task_id == "ID" or set(task_id) == {"-"}:
            continue

        tasks.append(
            {
                "id": task_id,
                "title": title,
                "owner": owner,
                "deps": deps,
                "status": status,
            }
        )

    gate_regex = re.compile(str(schema["gate_regex"]))
    done_keywords = {str(x).lower() for x in schema.get("done_keywords", [])}
    gates: dict[str, str] = {}

    for line in lines:
        m = gate_regex.search(line)
        if not m:
            continue

        token = m.group(1)
        gate_id = token.split(" ", 1)[0]

        state_m = re.search(r"\(([^)]*)\)", token)
        state = (state_m.group(1) if state_m else "").strip().lower()
        gates[gate_id] = "DONE" if state in done_keywords else "PENDING"

    return tasks, gates


def build_indexes(tasks: list[dict[str, str]]) -> dict[str, str]:
    return {task["id"]: task["status"] for task in tasks}


def deps_ready(deps: str, task_status: dict[str, str], gate_status: dict[str, str]) -> bool:
    raw = (deps or "").strip()
    if not raw or raw == "-":
        return True

    for dep_raw in raw.split(","):
        dep = dep_raw.strip()
        if not dep:
            continue

        if re.fullmatch(r"G\d+", dep):
            if gate_status.get(dep, "") != "DONE":
                return False
        elif re.fullmatch(r"T\d+-\d+", dep):
            if task_status.get(dep, "") != "DONE":
                return False
        else:
            return False

    return True
