#!/usr/bin/env python3
"""Compare Cetas JSONL transcripts without mistaking transcript size for API usage.

Usage: python3 scripts/compare_ptc_sessions.py session-a.jsonl session-b.jsonl
JSON output is deterministic and never asserts an unobserved token saving.
"""
import collections
import json
import pathlib
import sys


def extract(path):
    data = [json.loads(line) for line in pathlib.Path(path).open(encoding="utf-8") if line.strip()]
    rows = [row for row in data if isinstance(row, dict) and row.get("role") in ("system", "user", "assistant", "tool")]
    counter = collections.Counter()
    nested_calls = collections.Counter()
    run_codes = []
    diagnostics = []
    assistant_chars = 0
    tool_output_chars = 0
    reasoning_chars = 0
    for row in rows:
        role = row.get("role")
        if role == "assistant":
            reasoning_chars += len(row.get("reasoning_content") or "")
            for block in row.get("content", []):
                if block.get("type") == "text":
                    assistant_chars += len(block.get("text", ""))
            for call in row.get("tool_calls", []):
                name = call.get("name", "?")
                counter[name] += 1
                args = call.get("arguments") or {}
                if name == "run_code":
                    code = args.get("code") or args.get("source") or ""
                    run_codes.append(code)
                    import re
                    for tool_name in re.findall(r"""(?:ctx|ears)\.call\(\s*["']([^"']+)""", code):
                        nested_calls[tool_name] += 1
        if role == "tool":
            contents = row.get("content", [])
            if isinstance(contents, str):
                contents = [{"type": "text", "text": contents}]
            for block in contents:
                if block.get("type") == "text":
                    value = block.get("text", "")
                    tool_output_chars += len(value)
                    if "run_code build failed" in value:
                        diagnostics.append(len(value))
    state = (data[0].get("posoco.context_state") or {}) if data else {}
    return {
        "session": pathlib.Path(path).name,
        "message_count": len(rows),
        "last_measured_context_tokens": state.get("last_measured_tokens"),
        "assistant_text_chars": assistant_chars,
        "reasoning_chars": reasoning_chars,
        "tool_output_chars": tool_output_chars,
        "direct_calls": dict(sorted(counter.items())),
        "run_code_count": len(run_codes),
        "nested_call_mentions": dict(sorted(nested_calls.items())),
        "run_code_with_multiple_static_ctx_calls": sum(code.count('ctx.call(') > 1 for code in run_codes),
        "compiler_diagnostic_chars": diagnostics,
        "limitations": "No per-request provider token usage in session transcript; counts are not prompt-token attribution.",
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: compare_ptc_sessions.py SESSION_A.jsonl SESSION_B.jsonl")
    a, b = (extract(name) for name in sys.argv[1:])
    print(json.dumps({"sessions": [a, b],
                      "delta": {
                          "reasoning_chars": b["reasoning_chars"] - a["reasoning_chars"],
                          "tool_output_chars": b["tool_output_chars"] - a["tool_output_chars"],
                          "last_measured_context_tokens": (b["last_measured_context_tokens"] or 0) - (a["last_measured_context_tokens"] or 0),
                      }}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
