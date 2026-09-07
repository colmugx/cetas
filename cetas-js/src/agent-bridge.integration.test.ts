import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  CetasJsConfig,
  CetasJsRuntime,
  cetas_js_abort_turn,
  cetas_js_cancel_pending_ratelimit,
  cetas_js_runtime_create_agent,
  cetas_js_invoke_command,
  cetas_js_run_turn,
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
