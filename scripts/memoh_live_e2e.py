#!/usr/bin/env python3
"""Real Memoh ACP runtime preflight for cetas-memoh.

This intentionally talks to a live Memoh deployment. It does not use a fake
ACP server and it does not mutate durable bot configuration.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

DEFAULT_TIMEOUT_SECONDS = 120.0
AGENT_ID = "acp"


class PreflightError(RuntimeError):
    pass


def redact(text: str, token: str) -> str:
    if token:
        text = text.replace(token, "<redacted>")
    text = re.sub(
        r"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,}\\\"']+",
        r"\1<redacted>",
        text,
    )
    text = re.sub(
        r'(?i)("?(?:authorization|x-memoh-session-token|access_token|refresh_token)"?\s*:\s*")[^"]*(")',
        r"\1<redacted>\2",
        text,
    )
    return text

def request_json(
    *,
    method: str,
    url: str,
    token: str,
    timeout: float,
    payload: dict[str, Any] | None = None,
    expect_json: bool = True,
) -> dict[str, Any]:
    data = None
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            if not expect_json or not body:
                return {}
            decoded = json.loads(body.decode("utf-8"))
            if not isinstance(decoded, dict):
                raise PreflightError(f"{method} {url}: expected JSON object")
            return decoded
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise PreflightError(
            f"{method} {url}: HTTP {error.code}: {redact(body[:4000], token)}"
        ) from None
    except urllib.error.URLError as error:
        raise PreflightError(f"{method} {url}: {error.reason}") from None
    except json.JSONDecodeError as error:
        raise PreflightError(
            f"{method} {url}: invalid JSON response: {error}"
        ) from None


def require_dict(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PreflightError(f"runtime status is missing object field {name!r}")
    return value


def require_nonempty_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PreflightError(
            f"runtime status is missing non-empty field {name!r}"
        )
    return value.strip()


def assert_capabilities(status: dict[str, Any]) -> None:
    runtime_id = require_nonempty_string(status.get("runtime_id"), "runtime_id")
    agent_id = require_nonempty_string(status.get("agent_id"), "agent_id")
    if agent_id != AGENT_ID:
        raise PreflightError(
            f"runtime {runtime_id}: agent_id={agent_id!r}, expected {AGENT_ID!r}"
        )

    models = require_dict(status.get("models"), "models")
    if models.get("supported") is not True:
        raise PreflightError("cetas-memoh did not expose model selection")
    available_models = models.get("available_models")
    if not isinstance(available_models, list) or not available_models:
        raise PreflightError(
            "cetas-memoh exposed model selection but no models"
        )

    reasoning = require_dict(status.get("reasoning"), "reasoning")
    if reasoning.get("supported") is not True:
        raise PreflightError(
            "cetas-memoh did not expose reasoning-effort selection"
        )
    available_efforts = reasoning.get("available_efforts")
    if not isinstance(available_efforts, list) or not available_efforts:
        raise PreflightError(
            "cetas-memoh exposed reasoning selection but no efforts"
        )


def option_ids(items: Any) -> list[str]:
    if not isinstance(items, list):
        return []
    result: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        value = item.get("id")
        if isinstance(value, str) and value.strip():
            result.append(value.strip())
    return result


def choose_value(current: Any, available: Any) -> str:
    values = option_ids(available)
    if not values:
        raise PreflightError("runtime control has no selectable values")
    current_value = current.strip() if isinstance(current, str) else ""
    for value in values:
        if value != current_value:
            return value
    return values[0]


def summarize(status: dict[str, Any]) -> str:
    models = (
        status.get("models") if isinstance(status.get("models"), dict) else {}
    )
    reasoning = (
        status.get("reasoning")
        if isinstance(status.get("reasoning"), dict)
        else {}
    )
    return json.dumps(
        {
            "runtime_id": status.get("runtime_id"),
            "state": status.get("state"),
            "agent_id": status.get("agent_id"),
            "acp_session_id": status.get("acp_session_id"),
            "model": {
                "current": models.get("current_model_id"),
                "available": option_ids(models.get("available_models")),
            },
            "reasoning": {
                "current": reasoning.get("current_effort"),
                "available": option_ids(reasoning.get("available_efforts")),
            },
        },
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Start a real Memoh generic-ACP runtime backed by cetas-memoh, "
            "verify model/effort controls, then close it."
        )
    )
    parser.add_argument(
        "--api-url",
        default=os.getenv("MEMOH_API_URL", ""),
        help="Memoh API base URL including /api (env: MEMOH_API_URL)",
    )
    parser.add_argument(
        "--token",
        default=os.getenv("MEMOH_TOKEN", ""),
        help="Memoh bearer token (env: MEMOH_TOKEN)",
    )
    parser.add_argument(
        "--bot-id",
        default=os.getenv("MEMOH_BOT_ID", ""),
        help=(
            "Bot ID already configured with the generic ACP agent "
            "(env: MEMOH_BOT_ID)"
        ),
    )
    parser.add_argument(
        "--project-path",
        default=os.getenv("MEMOH_PROJECT_PATH", ""),
        help="Optional ACP project path; omit to use Memoh's default",
    )
    parser.add_argument(
        "--exercise-controls",
        action="store_true",
        help="PATCH one live model selection and one reasoning-effort selection",
    )
    parser.add_argument(
        "--keep-runtime",
        action="store_true",
        help="Do not DELETE the temporary runtime (debugging only)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"HTTP timeout in seconds (default: {DEFAULT_TIMEOUT_SECONDS:g})",
    )
    args = parser.parse_args()

    missing = [
        name
        for name, value in (
            ("MEMOH_API_URL/--api-url", args.api_url),
            ("MEMOH_TOKEN/--token", args.token),
            ("MEMOH_BOT_ID/--bot-id", args.bot_id),
        )
        if not str(value).strip()
    ]
    if missing:
        parser.error("missing required configuration: " + ", ".join(missing))
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    return args


def main() -> int:
    args = parse_args()
    api_url = args.api_url.rstrip("/")
    bot_id = urllib.parse.quote(args.bot_id.strip(), safe="")
    runtimes_url = f"{api_url}/bots/{bot_id}/acp-runtimes"

    payload: dict[str, Any] = {"acp_agent_id": AGENT_ID}
    if args.project_path.strip():
        payload["project_path"] = args.project_path.strip()

    runtime_id = ""
    try:
        print("[run] starting real Memoh ACP runtime")
        status = request_json(
            method="POST",
            url=runtimes_url,
            token=args.token,
            timeout=args.timeout,
            payload=payload,
        )
        assert_capabilities(status)
        runtime_id = require_nonempty_string(
            status.get("runtime_id"), "runtime_id"
        )
        runtime_url = (
            f"{runtimes_url}/{urllib.parse.quote(runtime_id, safe='')}"
        )
        print("[ok] cetas-memoh ACP handshake and runtime capabilities")
        print(summarize(status))

        fetched = request_json(
            method="GET",
            url=runtime_url,
            token=args.token,
            timeout=args.timeout,
        )
        if fetched.get("runtime_id") != runtime_id:
            raise PreflightError(
                "runtime GET returned a different runtime_id"
            )
        assert_capabilities(fetched)
        print("[ok] runtime status round-trip")

        if args.exercise_controls:
            models = require_dict(fetched.get("models"), "models")
            model_id = choose_value(
                models.get("current_model_id"),
                models.get("available_models"),
            )
            updated = request_json(
                method="PATCH",
                url=runtime_url + "/model",
                token=args.token,
                timeout=args.timeout,
                payload={"model_id": model_id},
            )
            current_model = require_dict(
                updated.get("models"), "models"
            ).get("current_model_id")
            if current_model != model_id:
                raise PreflightError(
                    "model update not confirmed: "
                    f"got {current_model!r}, expected {model_id!r}"
                )
            print(f"[ok] model control confirmed: {model_id}")

            reasoning = require_dict(updated.get("reasoning"), "reasoning")
            effort = choose_value(
                reasoning.get("current_effort"),
                reasoning.get("available_efforts"),
            )
            updated = request_json(
                method="PATCH",
                url=runtime_url + "/reasoning",
                token=args.token,
                timeout=args.timeout,
                payload={"reasoning_effort": effort},
            )
            current_effort = require_dict(
                updated.get("reasoning"), "reasoning"
            ).get("current_effort")
            if current_effort != effort:
                raise PreflightError(
                    "reasoning update not confirmed: "
                    f"got {current_effort!r}, expected {effort!r}"
                )
            print(f"[ok] reasoning control confirmed: {effort}")

        print("[pass] real Memoh ACP runtime preflight")
        return 0
    except PreflightError as error:
        print("[fail] " + redact(str(error), args.token), file=sys.stderr)
        return 1
    finally:
        if runtime_id and not args.keep_runtime:
            runtime_url = (
                f"{runtimes_url}/{urllib.parse.quote(runtime_id, safe='')}"
            )
            try:
                request_json(
                    method="DELETE",
                    url=runtime_url,
                    token=args.token,
                    timeout=args.timeout,
                    expect_json=False,
                )
                print("[ok] temporary ACP runtime closed")
            except PreflightError as error:
                print(
                    "[warn] failed to close temporary ACP runtime: "
                    + redact(str(error), args.token),
                    file=sys.stderr,
                )


if __name__ == "__main__":
    raise SystemExit(main())
