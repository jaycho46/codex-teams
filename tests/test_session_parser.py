import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "py"))

from session_parser import parse_session_structured, read_tail_text, strip_ansi


class SessionParserTests(unittest.TestCase):
    def test_strip_ansi_removes_terminal_escape_sequences(self) -> None:
        raw = "\x1b[31merror\x1b[0m line"
        self.assertEqual(strip_ansi(raw), "error line")

    def test_parse_jsonl_prefers_assistant_output(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"response.output_text.delta","delta":"Hello"}',
                '{"type":"response.output_text.delta","delta":" world"}',
                '{"type":"response.completed","response":{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"# Done\\n\\n- item"}]}]}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail)

        self.assertEqual(parsed.source, "jsonl")
        self.assertGreaterEqual(parsed.parsed_events, 3)
        self.assertGreaterEqual(len(parsed.blocks), 1)
        joined = "\n".join(block.body for block in parsed.blocks)
        self.assertIn("# Done", joined)
        self.assertIn("- item", joined)

    def test_parse_jsonl_builds_chat_code_and_think_blocks(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"response.reasoning.delta","delta":"plan first"}',
                '{"type":"response.output_item.added","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I will do this.\\n```python\\nprint(123)\\n```"}]}}',
                '{"type":"response.output_item.added","item":{"type":"message","role":"user","content":[{"type":"input_text","text":"please continue"}]}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail)

        kinds = [block.kind for block in parsed.blocks]
        self.assertIn("think", kinds)
        self.assertIn("chat_codex", kinds)
        self.assertIn("code", kinds)
        self.assertIn("chat_agent", kinds)
        item_types = {block.item_type for block in parsed.blocks}
        self.assertIn("reasoning", item_types)
        self.assertIn("output_text", item_types)
        self.assertIn("input_text", item_types)
        self.assertIn("code", item_types)

    def test_parse_jsonl_merges_consecutive_chat_blocks_and_hides_event_noise(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"response.output_text.delta","delta":"Hello"}',
                '{"type":"response.output_text.delta","delta":" world"}',
                '{"type":"response.status","status":"running"}',
                '{"type":"response.output_text.delta","delta":"\\nMore"}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=8)
        self.assertEqual(parsed.source, "jsonl")
        # Should be one merged codex chat block, not separate event/status rows.
        self.assertEqual([b.kind for b in parsed.blocks], ["chat_codex"])
        self.assertIn("Hello world", parsed.blocks[0].body)
        self.assertIn("More", parsed.blocks[0].body)
        self.assertEqual(parsed.blocks[0].item_type, "output_text")

    def test_parse_jsonl_maps_item_type_for_tool_call_and_result(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","name":"shell","arguments":{"command":"ls -la"}}}',
                '{"type":"response.output_item.added","item":{"id":"fc_1_out","type":"function_call_output","name":"shell","output":{"stdout":"ok"}}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=8)
        self.assertEqual(parsed.source, "jsonl")
        self.assertEqual([b.kind for b in parsed.blocks], ["tool_call", "tool_result"])
        self.assertEqual(parsed.blocks[0].item_type, "function_call")
        self.assertEqual(parsed.blocks[1].item_type, "function_call_output")
        self.assertEqual(parsed.blocks[0].item_id, "fc_1")
        self.assertEqual(parsed.blocks[1].item_id, "fc_1_out")

    def test_parse_jsonl_does_not_merge_chat_blocks_when_item_id_differs(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"first"}]}}',
                '{"type":"response.output_item.added","item":{"id":"msg_2","type":"message","role":"assistant","content":[{"type":"output_text","text":"second"}]}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=8)
        self.assertEqual(parsed.source, "jsonl")
        self.assertEqual([b.kind for b in parsed.blocks], ["chat_codex", "chat_codex"])
        self.assertEqual(parsed.blocks[0].item_id, "msg_1")
        self.assertEqual(parsed.blocks[1].item_id, "msg_2")
        self.assertIn("first", parsed.blocks[0].body)
        self.assertIn("second", parsed.blocks[1].body)

    def test_parse_jsonl_maps_agent_message_and_command_execution_items(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"작업 시작합니다."}}',
                '{"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \'rg --files\'","aggregated_output":"","exit_code":null,"status":"in_progress"}}',
                '{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \'rg --files\'","aggregated_output":"rg --files\\na.txt\\nb.txt\\n","exit_code":0,"status":"completed"}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=12)
        self.assertEqual(parsed.source, "jsonl")
        kinds = [block.kind for block in parsed.blocks]
        self.assertIn("chat_agent", kinds)
        self.assertIn("tool_call", kinds)
        self.assertNotIn("tool_result", kinds)
        self.assertEqual(parsed.blocks[0].item_type, "agent_message")
        command_blocks = [block for block in parsed.blocks if block.kind == "tool_call"]
        self.assertEqual(len(command_blocks), 1)
        call_block = command_blocks[0]
        self.assertEqual(call_block.body, "Searching files")
        self.assertEqual(call_block.item_status, "completed")

    def test_parse_jsonl_summarizes_rg_search_command_with_pattern(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"item.started","item":{"id":"item_rg","type":"command_execution","command":"rg -n \'parse_session_structured\' -S scripts/py","status":"in_progress"}}',
                '{"type":"item.completed","item":{"id":"item_rg","type":"command_execution","command":"rg -n \'parse_session_structured\' -S scripts/py","status":"completed"}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=12)
        self.assertEqual(parsed.source, "jsonl")
        command_blocks = [block for block in parsed.blocks if block.kind == "tool_call"]
        self.assertEqual(len(command_blocks), 1)
        self.assertEqual(command_blocks[0].body, "Searching parse_session_structured in scripts/py")
        self.assertEqual(command_blocks[0].item_status, "completed")

    def test_parse_jsonl_summarizes_direct_sed_read_command(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"sed -n \'1,120p\' README.md","status":"in_progress"}}',
                '{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"sed -n \'1,120p\' README.md","status":"completed"}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=12)
        self.assertEqual(parsed.source, "jsonl")
        command_blocks = [block for block in parsed.blocks if block.kind == "tool_call"]
        self.assertEqual(len(command_blocks), 1)
        self.assertEqual(command_blocks[0].body, "Reading README.md")
        self.assertEqual(command_blocks[0].item_status, "completed")

    def test_parse_jsonl_summarizes_nl_pipe_sed_read_command(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"item.started","item":{"id":"item_4","type":"command_execution","command":"nl -ba scripts/py/session_parser.py | sed -n \'1,260p\'","status":"in_progress"}}',
                '{"type":"item.completed","item":{"id":"item_4","type":"command_execution","command":"nl -ba scripts/py/session_parser.py | sed -n \'1,260p\'","status":"completed"}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=12)
        self.assertEqual(parsed.source, "jsonl")
        command_blocks = [block for block in parsed.blocks if block.kind == "tool_call"]
        self.assertEqual(len(command_blocks), 1)
        self.assertEqual(command_blocks[0].body, "Reading scripts/py/session_parser.py")
        self.assertEqual(command_blocks[0].item_status, "completed")

    def test_parse_jsonl_summarizes_sed_in_place_as_editing(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"item.started","item":{"id":"item_edit_1","type":"command_execution","command":"sed -i \'s/old/new/g\' README.md","status":"in_progress"}}',
                '{"type":"item.completed","item":{"id":"item_edit_1","type":"command_execution","command":"sed -i \'s/old/new/g\' README.md","status":"completed"}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=12)
        self.assertEqual(parsed.source, "jsonl")
        command_blocks = [block for block in parsed.blocks if block.kind == "tool_call"]
        self.assertEqual(len(command_blocks), 1)
        self.assertEqual(command_blocks[0].body, "Editing README.md")
        self.assertEqual(command_blocks[0].item_status, "completed")

    def test_parse_jsonl_summarizes_redirect_write_as_editing(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"item.started","item":{"id":"item_edit_2","type":"command_execution","command":"printf \'hello\\n\' > notes.txt","status":"in_progress"}}',
                '{"type":"item.completed","item":{"id":"item_edit_2","type":"command_execution","command":"printf \'hello\\n\' > notes.txt","status":"completed"}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=12)
        self.assertEqual(parsed.source, "jsonl")
        command_blocks = [block for block in parsed.blocks if block.kind == "tool_call"]
        self.assertEqual(len(command_blocks), 1)
        self.assertEqual(command_blocks[0].body, "Editing notes.txt")
        self.assertEqual(command_blocks[0].item_status, "completed")

    def test_parse_jsonl_maps_file_change_items_as_add_and_modify(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"item.completed","item":{"id":"fc_1","type":"file_change","status":"completed","changes":[{"path":"/tmp/project/new_file.ts","kind":"add"},{"path":"apps/admin/src/components/ProgramBulkUpdateContent.tsx","kind":"update"}]}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=8)
        self.assertEqual(parsed.source, "jsonl")
        file_blocks = [block for block in parsed.blocks if block.item_type == "file_change"]
        self.assertEqual(len(file_blocks), 2)
        self.assertTrue(all(block.kind == "tool_call" for block in file_blocks))
        self.assertEqual(file_blocks[0].body, "Add new_file.ts")
        self.assertEqual(file_blocks[1].body, "Modify ProgramBulkUpdateContent.tsx")
        self.assertTrue(all(block.item_status == "completed" for block in file_blocks))

    def test_parse_jsonl_think_strips_surrounding_bold_markers(self) -> None:
        log_tail = "\n".join(
            [
                '{"type":"item.completed","item":{"id":"r1","type":"reasoning","text":"**Planning next steps**"}}',
            ]
        )

        parsed = parse_session_structured("", log_tail=log_tail, max_blocks=4)
        self.assertEqual(parsed.source, "jsonl")
        think_block = next(block for block in parsed.blocks if block.kind == "think")
        self.assertEqual(think_block.body, "Planning next steps")

    def test_parse_transcript_fallback_wraps_clean_text(self) -> None:
        raw_capture = "\x1b[32mRunning step\x1b[0m\r\nNext line\r\n"

        parsed = parse_session_structured(raw_capture)

        self.assertEqual(parsed.source, "transcript")
        self.assertEqual(parsed.parsed_events, 0)
        self.assertEqual(len(parsed.blocks), 1)
        self.assertEqual(parsed.blocks[0].kind, "terminal")
        self.assertIn("Running step", parsed.blocks[0].body)
        self.assertIn("Next line", parsed.blocks[0].body)

    def test_read_tail_text_returns_file_tail(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "sample.log"
            path.write_text("line1\nline2\nline3\n", encoding="utf-8")

            tail = read_tail_text(str(path), max_bytes=10)

            self.assertIn("line3", tail)


if __name__ == "__main__":
    unittest.main()
