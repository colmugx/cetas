import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  CetasJsConfig,
  CetasJsRuntime,
  cetas_js_runtime_create_agent,
  cetas_js_invoke_command,
  cetas_js_run_turn,
  cetas_js_shutdown,
} from "../../../_build/js/release/build/colmugx/cetas-js/lib/lib.js";

const cleanup: string[] = [];

// The bridge hands fetch a MoonBit pipe-backed ReadableStream whose chunks
// are views onto a reused buffer (moonbitlang/async `new_pipe`). Consumers
// must copy each chunk synchronously while reading — `new Response(body)`
// defers consumption and observes rotated data once the body exceeds one
// 1024-byte chunk.
async function readRequestBody(body: unknown): Promise<string> {
  const reader = (body as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let text = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value) text += decoder.decode(value, { stream: true });
  }
  return text + decoder.decode();
}

afterEach(async () => {
  for (const path of cleanup.splice(0)) {
    await rm(path, { recursive: true });
  }
});

describe("long-lived cetas-js bridge", () => {
  test("surfaces settings IO errors instead of treating them as missing", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-settings-error-"));
    cleanup.push(cwd);
    // A directory at the settings path makes readFileSync fail with EISDIR.
    // The bridge must preserve that failure; existsSync-based probing would
    // incorrectly turn it into an empty/unconfigured provider catalog.
    await mkdir(join(cwd, ".cetas/settings.json"), { recursive: true });
    const config = new (CetasJsConfig as unknown as new (
      cwd: string,
      maxToolRounds: number,
    ) => unknown)(cwd, 4);
    const runtime = new (CetasJsRuntime as unknown as new (config: unknown) => unknown)(config);

    await expect(
      cetas_js_runtime_create_agent(
        runtime,
        () => undefined,
        () => undefined,
        async () => "",
        () => false,
      ),
    ).rejects.toThrow(/settings\.json read failed/);
  });

  test("reuses one agent across two turns and persists the transcript", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-bridge-"));
    cleanup.push(cwd);
    const requests: Array<Record<string, unknown>> = [];
    const replies = ["first reply", "second reply"];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (_input, init) => {
      if (init?.body === undefined || init.body === null) {
        throw new Error("model request body is required");
      }
      const requestBody = await readRequestBody(init.body);
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
    }) as typeof fetch;

    await mkdir(join(cwd, ".cetas"), { recursive: true });
    await Bun.write(
      join(cwd, ".cetas/settings.json"),
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
    const config = new (CetasJsConfig as unknown as new (
      cwd: string,
      maxToolRounds: number,
    ) => unknown)(cwd, 4);
    const runtime = new (CetasJsRuntime as unknown as new (config: unknown) => unknown)(config);
    const events: unknown[] = [];
    const agent = await cetas_js_runtime_create_agent(
      runtime,
      (json: string) => events.push(JSON.parse(json)),
      (json: string) => {
        throw new Error(`unexpected UI render in bridge test: ${json.length}`);
      },
      async () => {
        throw new Error("unexpected UI request in bridge test");
      },
      () => false,
    );

    try {
      await expect(
        cetas_js_invoke_command(agent, "model", "{malformed"),
      ).rejects.toThrow(/valid JSON|InvalidArgs/);

      const saved = await cetas_js_invoke_command(
        agent,
        "profile",
        JSON.stringify({ action: "save", name: "coding" }),
      );
      expect(JSON.parse(saved)).toMatchObject({ type: "success" });
      expect(await Bun.file(join(cwd, ".cetas/profiles/coding.json")).exists()).toBe(true);

      await Bun.write(
        join(cwd, ".cetas/settings.json"),
        JSON.stringify({ providers: {} }),
      );
      const loaded = await cetas_js_invoke_command(
        agent,
        "profile",
        JSON.stringify({ action: "load", name: "coding" }),
      );
      expect(JSON.parse(loaded)).toMatchObject({ type: "success" });
      expect(await Bun.file(join(cwd, ".cetas/settings.json")).text()).toContain("test-key");

      await expect(
        cetas_js_invoke_command(
          agent,
          "profile",
          JSON.stringify({ action: "save", name: "../escape" }),
        ),
      ).rejects.toThrow(/invalid profile name/);

      const deleted = await cetas_js_invoke_command(
        agent,
        "profile",
        JSON.stringify({ action: "delete", name: "coding" }),
      );
      expect(JSON.parse(deleted)).toMatchObject({ type: "success" });
      expect(await Bun.file(join(cwd, ".cetas/profiles/coding.json")).exists()).toBe(false);

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
