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
        self.assertEqual(call_block.body, "rg --files")
        self.assertEqual(call_block.item_status, "completed")

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
