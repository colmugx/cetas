import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  CetasJsConfig,
  CetasJsRuntime,
  cetas_js_rewind,
  cetas_js_run_turn,
  cetas_js_runtime_create_agent,
  cetas_js_shutdown,
} from "../../../../_build/js/release/build/colmugx/cetas-js/lib/lib.js";

const cleanup: string[] = [];

async function readRequestBody(body: unknown): Promise<string> {
  return new TextDecoder().decode(body as Uint8Array);
}

// Typed fakes cannot see the wire, so this suite drives the real MoonBit
// bridge against a temp sessionsDir and asserts on the JSONL bytes on disk:
// the metadata line survives, only the first `from_index` message lines
// remain, and the kept lines are byte-identical to the original prefix.
afterEach(async () => {
  for (const path of cleanup.splice(0)) {
    await rm(path, { recursive: true });
  }
});

function jsonlLines(text: string): string[] {
  return text.split("\n").filter((line) => line.length > 0);
}

describe("cetas_js_rewind wire format", () => {
  test("truncates the session JSONL to the kept prefix byte-for-byte", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-rewind-"));
    const home = await mkdtemp(join(tmpdir(), "cetas-js-rewind-home-"));
    const sessionsDir = await mkdtemp(join(tmpdir(), "cetas-js-rewind-sessions-"));
    cleanup.push(cwd, home, sessionsDir);
    const replies = ["first reply", "second reply"];
    let requestCount = 0;
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input, init) => {
      // Only the model endpoint is scripted; other extensions sharing
      // globalThis.fetch degrade silently on a 503.
      if (!String(input).startsWith("http://cetas.test")) {
        return new Response("service unavailable", { status: 503 });
      }
      if (init?.body === undefined || init.body === null) {
        throw new Error("model request body is required");
      }
      await readRequestBody(init.body);
      const reply = replies[requestCount];
      requestCount += 1;
      if (reply === undefined) {
        throw new Error("model received more requests than scripted");
      }
      return new Response(
        [
          `data: ${JSON.stringify({ choices: [{ delta: { content: reply } }] })}`,
          `data: ${JSON.stringify({
            choices: [{ finish_reason: "stop" }],
            usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
          })}`,
          "",
        ].join("\n\n"),
        { headers: { "content-type": "text/event-stream" } },
      );
    }) as typeof fetch;

    try {
      await mkdir(join(home, ".cetas"), { recursive: true });
      await Bun.write(
        join(home, ".cetas/settings.json"),
        JSON.stringify({
          providers: {
            deepseek: {
              api_key: "test-key",
              base_url: "http://cetas.test/v1",
              model: "scripted-model",
            },
          },
        }),
      );
      // sessionsDir is passed explicitly (5th ctor arg) so the transcript
      // lands in the temp root instead of <home>/.cetas/sessions.
      const config = new (CetasJsConfig as unknown as new (
        cwd: string,
        maxToolRounds: number,
        home: string,
        permissionMode: string,
        sessionsDir: string,
      ) => unknown)(cwd, 4, home, "workspace_write", sessionsDir);
      const runtime = new (CetasJsRuntime as unknown as new (config: unknown) => unknown)(config);
      const agent = await cetas_js_runtime_create_agent(
        runtime,
        () => undefined,
        () => undefined,
        async () => {
          throw new Error("unexpected UI request in rewind integration test");
        },
        () => false,
      );

      try {
        const signal = new AbortController().signal;
        await cetas_js_run_turn(agent, "first question", "[]", "rewind-session", signal);
        await cetas_js_run_turn(agent, "follow-up", "[]", "rewind-session", signal);

        const sessionPath = join(sessionsDir, "rewind-session.jsonl");
        const before = jsonlLines(await Bun.file(sessionPath).text());
        // Persisted layout: line 0 metadata, then one line per message — the
        // first turn persists the system prompt (message 0) and injects a
        // permission-context user message (message 2), so lines are:
        // metadata | system | user1 | permission-context | assistant1 |
        // user2 | assistant2.
        expect(before).toHaveLength(7);
        expect(before[0]).toBe("{}");
        expect(before[1]).toContain("\"role\":\"system\"");
        expect(before[2]).toContain("first question");
        expect(before[3]).toContain("permission-context");
        expect(before[4]).toContain("first reply");
        expect(before[5]).toContain("follow-up");
        expect(before[6]).toContain("second reply");

        // Rewind past the second exchange: keep messages [0, 4) =
        // system + first question + permission context + first reply.
        const rewound = await cetas_js_rewind(agent, "rewind-session", 4);
        expect(JSON.parse(rewound)).toMatchObject({ ok: true });

        const afterText = await Bun.file(sessionPath).text();
        const after = jsonlLines(afterText);
        expect(after).toHaveLength(5);
        // Byte-for-byte: kept lines are the original prefix, nothing else.
        expect(afterText).toBe(`${before.slice(0, 5).join("\n")}\n`);

        // An out-of-range index clamps to the message count: a full rewrite
        // that still reproduces every line byte-for-byte.
        const clamped = await cetas_js_rewind(agent, "rewind-session", 999);
        expect(JSON.parse(clamped)).toMatchObject({ ok: true });
        const afterClampText = await Bun.file(sessionPath).text();
        expect(afterClampText).toBe(afterText);
        expect(jsonlLines(afterClampText)).toHaveLength(5);

        // Storage-level failures ride the JSON envelope, not a rejection.
        const invalid = await cetas_js_rewind(agent, "..", 0);
        const invalidParsed = JSON.parse(invalid) as { ok: boolean; error?: string };
        expect(invalidParsed.ok).toBe(false);
        expect(invalidParsed.error).toContain("SessionError::Load");
        expect(invalidParsed.error).toContain("operation='truncate'");
      } finally {
        await cetas_js_shutdown(agent);
      }
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
