import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  CetasJsConfig,
  CetasJsRuntime,
  cetas_js_abort_turn,
  cetas_js_runtime_create_agent,
  cetas_js_invoke_command,
  cetas_js_run_turn,
  cetas_js_shutdown,
} from "../../../_build/js/release/build/colmugx/cetas-js/lib/lib.js";

const cleanup: string[] = [];

// async 0.21+ hands fetch a fully materialized MoonBit `Bytes` request body
// (an Uint8Array on the JS backend — the standard BodyInit), so the stub can
// decode it directly. The old pipe-backed ReadableStream body (async ≤0.20,
// whose chunks were views onto a reused buffer and had to be copied
// synchronously) is gone.
async function readRequestBody(body: unknown): Promise<string> {
  return new TextDecoder().decode(body as Uint8Array);
}

afterEach(async () => {
  for (const path of cleanup.splice(0)) {
    await rm(path, { recursive: true });
  }
});

describe("long-lived cetas-js bridge", () => {
  test("surfaces settings IO errors instead of treating them as missing", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-settings-error-"));
    const home = await mkdtemp(join(tmpdir(), "cetas-js-settings-home-"));
    cleanup.push(cwd, home);
    // A directory at the settings path makes readFileSync fail with EISDIR.
    // The bridge must preserve that failure; existsSync-based probing would
    // incorrectly turn it into an empty/unconfigured provider catalog.
    // Durable state (settings, credentials, sessions) lives under HOME.
    await mkdir(join(home, ".cetas/settings.json"), { recursive: true });
    const config = new (CetasJsConfig as unknown as new (
      cwd: string,
      maxToolRounds: number,
      home: string,
    ) => unknown)(cwd, 4, home);
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
    const home = await mkdtemp(join(tmpdir(), "cetas-js-bridge-home-"));
    cleanup.push(cwd, home);
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
    const config = new (CetasJsConfig as unknown as new (
      cwd: string,
      maxToolRounds: number,
      home: string,
    ) => unknown)(cwd, 4, home);
    const runtime = new (CetasJsRuntime as unknown as new (config: unknown) => unknown)(config);
    const events: unknown[] = [];
    const renders: Array<{ type?: string; render?: { key?: string } }> = [];
    const agent = await cetas_js_runtime_create_agent(
      runtime,
      (json: string) => events.push(JSON.parse(json)),
      (json: string) => renders.push(JSON.parse(json)),
      async () => {
        throw new Error("unexpected UI request in bridge test");
      },
      () => false,
    );

    try {
      // create_agent pushes the initial status bar facts through the UI port.
      expect(
        renders.some((event) => event.type === "ui_render" && event.render?.key === "statusbar"),
      ).toBe(true);

      await expect(
        cetas_js_invoke_command(agent, "model", "{malformed"),
      ).rejects.toThrow(/valid JSON|InvalidArgs/);

      const saved = await cetas_js_invoke_command(
        agent,
        "profile",
        JSON.stringify({ action: "save", name: "coding" }),
      );
      expect(JSON.parse(saved)).toMatchObject({ type: "success" });
      expect(await Bun.file(join(home, ".cetas/profiles/coding.json")).exists()).toBe(true);

      await Bun.write(
        join(home, ".cetas/settings.json"),
        JSON.stringify({ providers: {} }),
      );
      const loaded = await cetas_js_invoke_command(
        agent,
        "profile",
        JSON.stringify({ action: "load", name: "coding" }),
      );
      expect(JSON.parse(loaded)).toMatchObject({ type: "success" });
      expect(await Bun.file(join(home, ".cetas/settings.json")).text()).toContain("test-key");

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
      expect(await Bun.file(join(home, ".cetas/profiles/coding.json")).exists()).toBe(false);

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
          join(home, ".cetas/sessions/integration-session.jsonl"),
        ).exists(),
      ).toBe(true);
      expect(events.length).toBeGreaterThan(0);
    } finally {
      await cetas_js_shutdown(agent);
      globalThis.fetch = originalFetch;
    }
  });

  test("abort_turn settles the active run and the agent stays usable", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-abort-"));
    const home = await mkdtemp(join(tmpdir(), "cetas-js-abort-home-"));
    cleanup.push(cwd, home);
    const requests: string[] = [];
    const replies = ["interrupted reply", "after abort reply"];
    // The default runtime reports NotPropagated for cancel_effects, so the
    // in-flight model call must complete before the loop observes the abort.
    // This gate stands in for that in-flight request.
    let releaseModel!: () => void;
    const modelGate = new Promise<void>((resolve) => {
      releaseModel = resolve;
    });
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (_input, init) => {
      if (init?.body === undefined || init.body === null) {
        throw new Error("model request body is required");
      }
      requests.push(await readRequestBody(init.body));
      await modelGate;
      const reply = replies[requests.length - 1];
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
    const config = new (CetasJsConfig as unknown as new (
      cwd: string,
      maxToolRounds: number,
      home: string,
    ) => unknown)(cwd, 4, home);
    const runtime = new (CetasJsRuntime as unknown as new (config: unknown) => unknown)(config);
    const agent = await cetas_js_runtime_create_agent(
      runtime,
      () => undefined,
      () => undefined,
      async () => {
        throw new Error("unexpected UI request in bridge test");
      },
      () => false,
    );

    try {
      const turn = cetas_js_run_turn(agent, "question", "abort-session");
      // Wait until the model request is actually in flight; aborting before
      // the run registers would be a stale rejection, not an interrupt.
      while (requests.length === 0) {
        await new Promise((resolve) => setTimeout(resolve, 1));
      }
      const outcome = cetas_js_abort_turn(agent);
      expect(outcome.startsWith("Accepted(")).toBe(true);
      releaseModel();
      // The aborted turn resolves normally with whatever transcript exists;
      // it never rejects.
      await expect(turn).resolves.toBeString();
      // With no run active, a further abort is rejected as stale.
      expect(cetas_js_abort_turn(agent).startsWith("RejectedStale(")).toBe(true);
      // The long-lived agent still serves the next turn.
      const reply = await cetas_js_run_turn(agent, "again", "abort-session");
      expect(reply).toContain("after abort reply");
      expect(requests).toHaveLength(2);
    } finally {
      await cetas_js_shutdown(agent);
      globalThis.fetch = originalFetch;
    }
  });
});
