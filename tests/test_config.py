import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "py"))

from config import ConfigError, load_config, resolve_context


class ConfigTests(unittest.TestCase):
    def test_load_config_bootstraps_and_expands_repo_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "sample-repo"
            repo_root.mkdir(parents=True, exist_ok=True)

            config, config_path = load_config(repo_root)

            self.assertTrue(config_path.exists())
            self.assertIn("[repo]", config_path.read_text(encoding="utf-8"))
            self.assertEqual(config["repo"]["worktree_parent"], "../sample-repo-worktrees")
            self.assertEqual(config["runtime"]["launch_backend"], "tmux")

    def test_resolve_context_state_dir_priority(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "priority-repo"
            repo_root.mkdir(parents=True, exist_ok=True)

            config, config_path = load_config(repo_root)

            with patch.dict(os.environ, {}, clear=False):
                ctx_default = resolve_context(repo_root, config, None, config_path=config_path)
                self.assertEqual(ctx_default["state_dir"], str((repo_root / ".state").resolve()))

            with patch.dict(os.environ, {"AI_STATE_DIR": "shared/state"}, clear=False):
                ctx_env = resolve_context(repo_root, config, None, config_path=config_path)
                self.assertEqual(ctx_env["state_dir"], str((repo_root / "shared/state").resolve()))

            with patch.dict(os.environ, {"AI_STATE_DIR": "shared/state"}, clear=False):
                ctx_arg = resolve_context(repo_root, config, "arg/state", config_path=config_path)
                self.assertEqual(ctx_arg["state_dir"], str((repo_root / "arg/state").resolve()))

    def test_invalid_todo_schema_raises(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "invalid-repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            cfg_path = repo_root / ".state" / "orchestrator.toml"
            cfg_path.parent.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(
                """
[owners]
AgentA = "app-shell"

[todo]
id_col = 0
""".strip()
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaises(ConfigError):
                load_config(repo_root, str(cfg_path))

    def test_invalid_launch_backend_raises(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo_root = Path(td) / "invalid-backend-repo"
            repo_root.mkdir(parents=True, exist_ok=True)
            cfg_path = repo_root / ".state" / "orchestrator.toml"
            cfg_path.parent.mkdir(parents=True, exist_ok=True)
            cfg_path.write_text(
                """
[runtime]
launch_backend = "invalid"
""".strip()
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaises(ConfigError):
                load_config(repo_root, str(cfg_path))


if __name__ == "__main__":
    unittest.main()
