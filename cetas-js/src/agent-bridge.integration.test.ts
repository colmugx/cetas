import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  CetasJsConfig,
  cetas_js_create_agent,
  cetas_js_run_turn,
  cetas_js_shutdown,
} from "../../../_build/js/release/build/colmugx/cetas-js/lib/lib.js";

const cleanup: string[] = [];

afterEach(async () => {
  for (const path of cleanup.splice(0)) {
    await rm(path, { recursive: true });
  }
});

describe("long-lived cetas-js bridge", () => {
  test("reuses one agent across two turns and persists the transcript", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-bridge-"));
    cleanup.push(cwd);
    const requests: Array<Record<string, unknown>> = [];
    const replies = ["first reply", "second reply"];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async (_input, init) => {
      if (init?.body === undefined || init.body === null) {
        throw new Error("model request body is required");
      }
      const requestBody = await new Response(init.body).text();
      requests.push(JSON.parse(requestBody) as Record<string, unknown>);
      const reply = replies[requests.length - 1];
      if (reply === undefined) {
        throw new Error("model received more requests than scripted");
      }
      return new Response(
        [
          `data: ${JSON.stringify({ choices: [{ delta: { content: reply } }] })}`,
          `data: ${JSON.stringify({
            choices: [{ finish_reason: "stop" }],
            usage: {
              prompt_tokens: 1,
              completion_tokens: 1,
              total_tokens: 2,
            },
          })}`,
          "",
        ].join("\n\n"),
        { headers: { "content-type": "text/event-stream" } },
      );
    };

    const config = new (CetasJsConfig as unknown as new (
      apiKey: string,
      baseUrl: string,
      model: string,
      cwd: string,
      maxToolRounds: number,
    ) => unknown)(
      "test-key",
      "http://cetas.test/v1",
      "scripted-model",
      cwd,
      4,
    );
    const events: unknown[] = [];
    const agent = await cetas_js_create_agent(
      config,
      (json: string) => events.push(JSON.parse(json)),
      (json: string) => {
        throw new Error(`unexpected UI render in bridge test: ${json.length}`);
      },
      async () => {
        throw new Error("unexpected UI request in bridge test");
      },
    );

    try {
      const firstReply = await cetas_js_run_turn(
        agent,
        "first question",
        "integration-session",
      );
      expect(firstReply).toContain("first reply");
      const secondReply = await cetas_js_run_turn(
        agent,
        "follow-up",
        "integration-session",
      );
      expect(secondReply).toContain("second reply");
      expect(requests).toHaveLength(2);
      const secondMessages = requests[1]!.messages;
      expect(JSON.stringify(secondMessages)).toContain("first reply");
      expect(JSON.stringify(secondMessages)).toContain("follow-up");
      expect(
        await Bun.file(
          join(cwd, ".cetas/sessions/integration-session.jsonl"),
        ).exists(),
      ).toBe(true);
      expect(events.length).toBeGreaterThan(0);
    } finally {
      await cetas_js_shutdown(agent);
      globalThis.fetch = originalFetch;
    }
  });
});
