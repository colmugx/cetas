import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { CetasApplication } from "./app/application.ts";
import { MoonbitCetasAgentBridge } from "./app/moonbit-bridge.ts";

const {
  CetasJsConfig,
  CetasJsRuntime,
  cetas_js_abort_turn,
  cetas_js_cancel_pending_ratelimit,
  cetas_js_compact_session,
  cetas_js_runtime_create_agent,
  cetas_js_invoke_command,
  cetas_js_run_turn,
  cetas_js_sessions_dir,
  cetas_js_start_ratelimit_monitor,
  cetas_js_shutdown,
} = await import("mbt:colmugx/cetas-js/lib") as unknown as typeof import("mbt:colmugx/cetas-js/lib") & {
  cetas_js_start_ratelimit_monitor(agent: unknown, signal: AbortSignal): Promise<void>;
  cetas_js_cancel_pending_ratelimit(agent: unknown): void;
};

const cleanup: string[] = [];

// async 0.21+ hands fetch a fully materialized MoonBit `Bytes` request body
// (an Uint8Array on the JS backend — the standard BodyInit), so the stub can
// decode it directly. The old pipe-backed ReadableStream body (async ≤0.20,
// whose chunks were views onto a reused buffer and had to be copied
// synchronously) is gone.
async function readRequestBody(body: unknown): Promise<string> {
  return new TextDecoder().decode(body as Uint8Array);
}

async function waitFor(predicate: () => boolean, message: string): Promise<void> {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(message);
    await Bun.sleep(10);
  }
}

function isAbortError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "name" in error &&
    (error as { name?: unknown }).name === "AbortError"
  );
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
      permissionMode: string,
      sessionsDir: string,
    ) => unknown)(cwd, 4, home, "workspace_write", "");
    const runtime = new (CetasJsRuntime as unknown as new (
      config: unknown,
    ) => Parameters<typeof cetas_js_runtime_create_agent>[0])(config);

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
    globalThis.fetch = (async (input, init) => {
      // Only the model endpoint is scripted. Other extensions share
      // globalThis.fetch (nowledge-mem posts to a local service on turn
      // boundaries); answer those with a 503 so they degrade silently
      // instead of consuming scripted model replies.
      if (!String(input).startsWith("http://cetas.test")) {
        return new Response("service unavailable", { status: 503 });
      }
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
      permissionMode: string,
      sessionsDir: string,
    ) => unknown)(cwd, 4, home, "workspace_write", "");
    const runtime = new (CetasJsRuntime as unknown as new (
      config: unknown,
    ) => Parameters<typeof cetas_js_runtime_create_agent>[0])(config);
    const events: unknown[] = [];
    const renders: Array<{
      type?: string;
      render?: {
        key?: string;
        body?: { type?: string; entries?: Array<{ key?: unknown; value?: unknown }> };
      };
    }> = [];
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
      // Resident segments announce their initial state at composition:
      // the model segment renders during create_agent, before any turn —
      // the startup bar is no longer empty (user ruling 2026-09-04).
      expect(
        renders.some(
          (event) =>
            event.type === "ui_render" &&
            event.render?.key === "statusbar" &&
            event.render?.body?.entries?.some(
              (entry) => entry.key === "model",
            ),
        ),
      ).toBe(true);

      await expect(
        cetas_js_invoke_command(agent, "model", "{malformed"),
      ).rejects.toThrow(/valid JSON|InvalidArgs/);

      const firstReply = await cetas_js_run_turn(
        agent,
        "first question",
        "[]",
        "integration-session",
        new AbortController().signal,
      );
      expect(firstReply).toContain("first reply");
      // Status publishes are event-driven beyond the composed initial
      // state: during the first turn the llm observer publishes token
      // facts and the session store publishes the session segment on the
      // shared bus; the statusbar bridge renders each applied change over
      // the UI port, proving the publisher → bus → bridge → render wire
      // end to end.
      expect(
        renders.some((event) => event.type === "ui_render" && event.render?.key === "statusbar"),
      ).toBe(true);
      // The statusbar bridge now always publishes Entries bodies: at least
      // one statusbar render must carry a non-empty entries array whose
      // key/value pairs are strings, ready for the host's line renderer.
      // (Color roles stay unit-tested; no colored segment publishes here.)
      expect(
        renders
          .filter(
            (event) =>
              event.type === "ui_render" && event.render?.key === "statusbar",
          )
          .some(({ render }) => {
            const body = render?.body;
            return (
              body?.type === "entries" &&
              (body.entries?.length ?? 0) > 0 &&
              (body.entries ?? []).every(
                (entry) =>
                  typeof entry.key === "string" &&
                  typeof entry.value === "string",
              )
            );
          }),
      ).toBe(true);
      const secondReply = await cetas_js_run_turn(
        agent,
        "follow-up",
        "[]",
        "integration-session",
        new AbortController().signal,
      );
      expect(secondReply).toContain("second reply");
      expect(requests).toHaveLength(2);
      const secondMessages = requests[1]!.messages;
      expect(JSON.stringify(secondMessages)).toContain("first reply");
      expect(JSON.stringify(secondMessages)).toContain("follow-up");
      // An empty sessionsDir resolves to the per-project bucket; its path
      // comes from the MoonBit export, never re-derived here.
      const persisted = await Bun.file(
        join(cetas_js_sessions_dir(home, cwd), "integration-session.jsonl"),
      ).exists();
      expect(persisted).toBe(true);
      expect(events.length).toBeGreaterThan(0);
    } finally {
      await cetas_js_shutdown(agent);
      globalThis.fetch = originalFetch;
    }
  });

  test("rate-limit monitor retries the interrupted user turn at reset without another host send", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-ratelimit-"));
    const home = await mkdtemp(join(tmpdir(), "cetas-js-ratelimit-home-"));
    cleanup.push(cwd, home);
    const requests: Array<Record<string, unknown>> = [];
    const events: Array<Record<string, unknown>> = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input, init) => {
      if (!String(input).startsWith("http://cetas.test")) {
        return new Response("service unavailable", { status: 503 });
      }
      if (init?.body === undefined || init.body === null) {
        throw new Error("model request body is required");
      }
      requests.push(JSON.parse(await readRequestBody(init.body)) as Record<string, unknown>);
      if (requests.length === 1) {
        return new Response(JSON.stringify({
          error: {
            type: "usage_limit_reached",
            message: "test quota reset",
            resets_in_seconds: 0,
          },
        }), {
          status: 429,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(
        [
          `data: ${JSON.stringify({ choices: [{ delta: { content: "recovered" } }] })}`,
          `data: ${JSON.stringify({
            choices: [{ finish_reason: "stop" }],
            usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
          })}`,
          "data: [DONE]",
          "",
        ].join("\n\n"),
        { headers: { "content-type": "text/event-stream" } },
      );
    }) as typeof fetch;

    await mkdir(join(home, ".cetas"), { recursive: true });
    await Bun.write(join(home, ".cetas/settings.json"), JSON.stringify({
      providers: {
        openrouter: {
          api_key: "test-key",
          base_url: "http://cetas.test/v1",
          model: "scripted-model",
        },
      },
    }));
    const config = new (CetasJsConfig as unknown as new (
      cwd: string,
      maxToolRounds: number,
      home: string,
      permissionMode: string,
      sessionsDir: string,
    ) => unknown)(cwd, 4, home, "workspace_write", "");
    const runtime = new (CetasJsRuntime as unknown as new (
      config: unknown,
    ) => Parameters<typeof cetas_js_runtime_create_agent>[0])(config);
    const agent = await cetas_js_runtime_create_agent(
      runtime as never,
      (raw: string) => events.push(JSON.parse(raw) as Record<string, unknown>),
      () => undefined,
      async () => "",
      () => false,
    );
    const monitorController = new AbortController();
    const monitor = cetas_js_start_ratelimit_monitor(agent, monitorController.signal);

    try {
      await expect(cetas_js_run_turn(
        agent,
        "retry this exact request",
        "[]",
        "ratelimit-session",
        new AbortController().signal,
      )).rejects.toThrow();
      await waitFor(
        () => requests.length >= 2 && events.some((event) => event.type === "turn_completed"),
        "rate-limit reset did not trigger an automatic resumed turn",
      );

      expect(requests).toHaveLength(2);
      const resumedMessages = JSON.stringify(requests[1]!.messages);
      expect(resumedMessages.match(/retry this exact request/g)).toHaveLength(1);
      expect(resumedMessages).not.toContain("previous request was interrupted");
      const recoveryTraces = events.filter(
        (event) =>
          event.type === "custom" &&
          event.source === "posoco_ext_ratelimit" &&
          event.label === "recovery_trace",
      );
      expect(recoveryTraces.length).toBeGreaterThan(0);
      const traceJson = JSON.stringify(recoveryTraces);
      expect(traceJson).toContain("encountered_at_ms=");
      expect(traceJson).not.toContain("retry this exact request");
    } finally {
      try {
        cetas_js_cancel_pending_ratelimit(agent);
        monitorController.abort();
        await monitor.catch((error: unknown) => {
          if (!isAbortError(error)) throw error;
        });
        await cetas_js_shutdown(agent);
      } finally {
        globalThis.fetch = originalFetch;
      }
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
    globalThis.fetch = (async (input, init) => {
      // Only the model endpoint is scripted. Other extensions share
      // globalThis.fetch (nowledge-mem posts to a local service on turn
      // boundaries); answer those with a 503 so they degrade silently
      // instead of consuming scripted model replies.
      if (!String(input).startsWith("http://cetas.test")) {
        return new Response("service unavailable", { status: 503 });
      }
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
      permissionMode: string,
      sessionsDir: string,
    ) => unknown)(cwd, 4, home, "workspace_write", "");
    const runtime = new (CetasJsRuntime as unknown as new (
      config: unknown,
    ) => Parameters<typeof cetas_js_runtime_create_agent>[0])(config);
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
      const turn = cetas_js_run_turn(agent, "question", "[]", "abort-session", new AbortController().signal);
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
      const reply = await cetas_js_run_turn(agent, "again", "[]", "abort-session", new AbortController().signal);
      expect(reply).toContain("after abort reply");
      expect(requests).toHaveLength(2);
    } finally {
      await cetas_js_shutdown(agent);
      globalThis.fetch = originalFetch;
    }
  });

  test("run_turn signal abort interrupts an in-flight model request without the mailbox", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-signal-"));
    const home = await mkdtemp(join(tmpdir(), "cetas-js-signal-home-"));
    cleanup.push(cwd, home);
    const requests: string[] = [];
    // The gate is never released before the abort: if the signal failed to
    // cancel the turn coroutine, the turn promise would hang and this test
    // would time out instead of settling.
    let releaseModel!: () => void;
    const modelGate = new Promise<void>((resolve) => {
      releaseModel = resolve;
    });
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input, init) => {
      // Only the model endpoint is scripted. Other extensions share
      // globalThis.fetch (nowledge-mem posts to a local service on turn
      // boundaries); answer those with a 503 so they degrade silently
      // instead of consuming scripted model replies.
      if (!String(input).startsWith("http://cetas.test")) {
        return new Response("service unavailable", { status: 503 });
      }
      if (init?.body === undefined || init.body === null) {
        throw new Error("model request body is required");
      }
      requests.push(await readRequestBody(init.body));
      await modelGate;
      return new Response(
        [
          `data: ${JSON.stringify({ choices: [{ delta: { content: "late reply" } }] })}`,
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
      permissionMode: string,
      sessionsDir: string,
    ) => unknown)(cwd, 4, home, "workspace_write", "");
    const runtime = new (CetasJsRuntime as unknown as new (
      config: unknown,
    ) => Parameters<typeof cetas_js_runtime_create_agent>[0])(config);
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
      const controller = new AbortController();
      const turn = cetas_js_run_turn(agent, "question", "[]", "signal-session", controller.signal);
      // Wait until the model request is actually in flight; aborting before
      // the run registers would not exercise the in-flight path.
      while (requests.length === 0) {
        await new Promise((resolve) => setTimeout(resolve, 1));
      }
      controller.abort();
      // No mailbox abort and no model reply: the coroutine cancel alone must
      // settle the turn promptly. The provider wraps the cancelled fetch as a
      // transport ModelError, so the rejection is from_async's stringified
      // `AgentError::Model(... Cancelled)` (or a direct AbortError if the
      // cancel surfaces before the provider's catch).
      const rejection = await turn.then(
        () => {
          throw new Error("expected the aborted turn to reject");
        },
        (error: unknown) => error,
      );
      const text =
        rejection instanceof Error
          ? `${rejection.name} ${rejection.message}`
          : String(rejection);
      expect(/Cancelled|AbortError/.test(text)).toBe(true);
      releaseModel();
    } finally {
      releaseModel();
      await cetas_js_shutdown(agent).catch(() => undefined);
      globalThis.fetch = originalFetch;
    }
  });
});

/**
 * Esc → /compact acceptance flows over the real bridge with the OpenAI
 * Responses provider: the model endpoint is `/responses` (SSE) and manual
 * compaction is `/responses/compact` (JSON `output` window).
 */
describe("esc mid-stream, compact, and resume over the real bridge", () => {
  const openaiSse = (text: string) =>
    [
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}`,
      `data: ${JSON.stringify({
        type: "response.completed",
        response: {
          status: "completed",
          output: [],
          usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
        },
      })}`,
      "data: [DONE]",
      "",
    ].join("\n\n");

  const sseResponse = (text: string) =>
    new Response(openaiSse(text), { headers: { "content-type": "text/event-stream" } });

  const compactJson = (text: string) =>
    JSON.stringify({
      output: [
        { type: "message", role: "assistant", content: [{ type: "output_text", text }] },
      ],
    });

  function gatedSseResponse(text: string, gate: Promise<void>): Response {
    const encoder = new TextEncoder();
    const body = new ReadableStream<Uint8Array>({
      async start(controller) {
        await gate;
        controller.enqueue(encoder.encode(openaiSse(text)));
        controller.close();
      },
    });
    return new Response(body, { headers: { "content-type": "text/event-stream" } });
  }

  async function writeOpenaiSettings(cwd: string, home: string): Promise<void> {
    await mkdir(join(home, ".cetas"), { recursive: true });
    await Bun.write(
      join(home, ".cetas/settings.json"),
      JSON.stringify({
        providers: {
          openai: {
            api_key: "test-key",
            base_url: "http://cetas.test/v1",
            model: "scripted-model",
          },
        },
      }),
    );
    void cwd;
  }

  async function startOpenaiAgent(cwd: string, home: string) {
    const config = new (CetasJsConfig as unknown as new (
      cwd: string,
      maxToolRounds: number,
      home: string,
      permissionMode: string,
      sessionsDir: string,
    ) => unknown)(cwd, 4, home, "workspace_write", "");
    const runtime = new (CetasJsRuntime as unknown as new (
      config: unknown,
    ) => Parameters<typeof cetas_js_runtime_create_agent>[0])(config);
    return await cetas_js_runtime_create_agent(
      runtime,
      () => undefined,
      () => undefined,
      async () => {
        throw new Error("unexpected UI request in bridge test");
      },
      () => false,
    );
  }

  test("esc mid-stream then compact_session serves the same agent without a rebuild", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-esc-compact-"));
    const home = await mkdtemp(join(tmpdir(), "cetas-js-esc-compact-home-"));
    cleanup.push(cwd, home);
    const requests: Array<{ path: string; body: string }> = [];
    let releaseModel!: () => void;
    const modelGate = new Promise<void>((resolve) => {
      releaseModel = resolve;
    });
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input, init) => {
      const url = String(input);
      if (!url.startsWith("http://cetas.test")) {
        return new Response("service unavailable", { status: 503 });
      }
      if (url.endsWith("/responses/compact")) {
        requests.push({ path: "compact", body: await readRequestBody(init!.body) });
        return new Response(compactJson("compact checkpoint"), {
          headers: { "content-type": "application/json" },
        });
      }
      requests.push({ path: "responses", body: await readRequestBody(init!.body) });
      if (requests.filter((entry) => entry.path === "responses").length === 1) {
        return gatedSseResponse("interrupted reply", modelGate);
      }
      return sseResponse("post compact reply");
    }) as typeof fetch;

    let agent: Awaited<ReturnType<typeof startOpenaiAgent>> | undefined;
    try {
      await writeOpenaiSettings(cwd, home);
      agent = await startOpenaiAgent(cwd, home);

      const controller = new AbortController();
      const turn = cetas_js_run_turn(agent, "first question", "[]", "esc-session", controller.signal);
      while (requests.length === 0) {
        await Bun.sleep(1);
      }
      expect(cetas_js_abort_turn(agent).startsWith("Accepted(")).toBe(true);
      controller.abort();
      const rejection = await turn.then(
        () => {
          throw new Error("expected the aborted turn to reject");
        },
        (error: unknown) => error,
      );
      const text = rejection instanceof Error ? rejection.message : String(rejection);
      expect(text).toContain("category=cancelled");

      // Same handle, same session: no agent rebuild, no new user message.
      const compactRaw = await cetas_js_compact_session(agent, "esc-session", new AbortController().signal);
      expect(JSON.parse(compactRaw)).toMatchObject({
        ok: true,
        mode: "Replace",
        final_session_id: "esc-session",
      });

      const reply = await cetas_js_run_turn(agent, "after compact", "[]", "esc-session", new AbortController().signal);
      expect(reply).toContain("post compact reply");

      expect(requests.map((entry) => entry.path)).toEqual(["responses", "compact", "responses"]);
      // The interrupted user message was persisted once and never duplicated.
      expect(requests[0]!.body.match(/first question/g)).toHaveLength(1);
      expect(requests[1]!.body.match(/first question/g)).toHaveLength(1);
      // The next request runs on the committed compacted window.
      expect(requests[2]!.body).toContain("compact checkpoint");
      expect(requests[2]!.body).not.toContain("first question");
    } finally {
      releaseModel();
      globalThis.fetch = originalFetch;
      if (agent !== undefined) await cetas_js_shutdown(agent).catch(() => undefined);
    }
  });

  test("compact cancel reports a typed cancelled outcome and the compact reruns", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-compact-cancel-"));
    const home = await mkdtemp(join(tmpdir(), "cetas-js-compact-cancel-home-"));
    cleanup.push(cwd, home);
    let compactSeen = 0;
    let responsesSeen = 0;
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input, init) => {
      const url = String(input);
      if (!url.startsWith("http://cetas.test")) {
        return new Response("service unavailable", { status: 503 });
      }
      if (url.endsWith("/responses/compact")) {
        compactSeen += 1;
        if (compactSeen === 1) {
          return new Promise<Response>(() => {});
        }
        return new Response(compactJson("second checkpoint"), {
          headers: { "content-type": "application/json" },
        });
      }
      void init;
      responsesSeen += 1;
      return sseResponse("reply after compacts");
    }) as typeof fetch;

    let agent: Awaited<ReturnType<typeof startOpenaiAgent>> | undefined;
    try {
      await writeOpenaiSettings(cwd, home);
      agent = await startOpenaiAgent(cwd, home);

      const controller = new AbortController();
      const first = cetas_js_compact_session(agent, "cancel-session", controller.signal);
      while (compactSeen === 0) {
        await Bun.sleep(1);
      }
      controller.abort();
      expect(JSON.parse(await first)).toMatchObject({ ok: false, error_kind: "cancelled" });

      const second = JSON.parse(
        await cetas_js_compact_session(agent, "cancel-session", new AbortController().signal),
      );
      expect(second).toMatchObject({ ok: true, mode: "Replace", messages_after: 1 });

      const reply = await cetas_js_run_turn(
        agent,
        "continue after two compacts",
        "[]",
        "cancel-session",
        new AbortController().signal,
      );
      expect(reply).toContain("reply after compacts");
      expect(compactSeen).toBe(2);
      expect(responsesSeen).toBe(1);
    } finally {
      globalThis.fetch = originalFetch;
      if (agent !== undefined) await cetas_js_shutdown(agent).catch(() => undefined);
    }
  });

  test("application /compact switches a running turn and keeps queued input pending", async () => {
    const cwd = await mkdtemp(join(tmpdir(), "cetas-js-app-compact-"));
    const home = await mkdtemp(join(tmpdir(), "cetas-js-app-compact-home-"));
    cleanup.push(cwd, home);
    const requests: Array<{ path: string; body: string }> = [];
    let releaseModel!: () => void;
    const modelGate = new Promise<void>((resolve) => {
      releaseModel = resolve;
    });
    let releaseCompact!: () => void;
    const compactGate = new Promise<void>((resolve) => {
      releaseCompact = resolve;
    });
    let compactGated = false;
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input, init) => {
      const url = String(input);
      if (!url.startsWith("http://cetas.test")) {
        return new Response("service unavailable", { status: 503 });
      }
      if (url.endsWith("/responses/compact")) {
        requests.push({ path: "compact", body: await readRequestBody(init!.body) });
        if (!compactGated) {
          compactGated = true;
          const encoder = new TextEncoder();
          const body = new ReadableStream<Uint8Array>({
            async start(controller) {
              await compactGate;
              controller.enqueue(encoder.encode(compactJson("compact checkpoint")));
              controller.close();
            },
          });
          return new Response(body, { headers: { "content-type": "application/json" } });
        }
        return new Response(compactJson("compact checkpoint"), {
          headers: { "content-type": "application/json" },
        });
      }
      requests.push({ path: "responses", body: await readRequestBody(init!.body) });
      if (requests.filter((entry) => entry.path === "responses").length === 1) {
        return gatedSseResponse("interrupted reply", modelGate);
      }
      return sseResponse("post compact reply");
    }) as typeof fetch;

    try {
      await writeOpenaiSettings(cwd, home);
      const config = { cwd, home, maxToolRounds: 4 };
      const bridge = new MoonbitCetasAgentBridge(config);
      let createCount = 0;
      const created = bridge.createAgent.bind(bridge);
      (bridge as unknown as { createAgent: typeof created }).createAgent = async (...args) => {
        createCount += 1;
        return created(...args);
      };
      const app = new CetasApplication({
        bridge,
        config,
        callbacks: {
          observerCallback: () => undefined,
          renderCallback: () => undefined,
          requestCallback: async () => "",
        },
        initialSessionId: "app-session",
      });
      await app.start();
      expect(app.appState).toBe("ready");

      const turnPromise = app.runTurn("first question");
      turnPromise.catch(() => undefined);
      while (requests.length === 0) {
        await Bun.sleep(1);
      }
      expect(app.queueFollowUp("queued question")).toBe("accepted");
      await Bun.sleep(20);

      // The switch interrupts the turn and waits for its finalize before
      // compacting; the compact request itself gates below.
      const compactCommand = app.invokeCommand("compact", "{}");
      while (!compactGated) {
        await Bun.sleep(1);
      }
      expect(app.compactPending).toBe(true);

      // A second /compact while one owns the session waits for cleanup.
      await expect(app.invokeCommand("compact", "{}")).rejects.toThrow(
        /waiting for the interrupted operation/,
      );

      releaseCompact();
      const commandOutcome = JSON.parse(await compactCommand);
      expect(commandOutcome.type).toBe("success");
      expect(commandOutcome.structured).toMatchObject({ ok: true, mode: "Replace" });

      await turnPromise.then(() => undefined, () => undefined);
      expect(app.appState).toBe("ready");
      // The queued input survived the interrupted run as pending and the
      // Agent was never rebuilt for the compact.
      expect(app.pendingInputs).toEqual(["queued question"]);
      expect(createCount).toBe(1);

      const reply = await app.runTurn("after compact");
      expect(reply).toContain("post compact reply");
      // The queued follow-up drains at the next run's boundary (core
      // semantics), so it runs after the user's explicit turn, never during
      // the interrupt/compact switch itself.
      expect(requests.map((entry) => entry.path)).toEqual([
        "responses",
        "compact",
        "responses",
        "responses",
      ]);
      const queuedTurn = requests[3]!.body;
      expect((queuedTurn.match(/queued question/g) ?? []).length).toBe(1);
      expect(app.pendingInputs).toEqual([]);

      await app.shutdown();
    } finally {
      releaseModel();
      globalThis.fetch = originalFetch;
    }
  });
});
