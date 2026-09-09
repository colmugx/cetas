import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { CetasApplication } from "./application.ts";
import { MoonbitCetasAgentBridge } from "./moonbit-bridge.ts";

const cleanup: string[] = [];

async function readRequestBody(body: unknown): Promise<string> {
  return new TextDecoder().decode(body as Uint8Array);
}

async function waitFor(predicate: () => boolean, message: string): Promise<void> {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(message);
    await Bun.sleep(5);
  }
}

function countOf(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

// Marker line written into the workspace file the scripted turn reads: the
// tool output's only trace on the wire, so its count per request body pins
// "the completed tool is kept once, never replayed".
const TOOL_FACT_MARKER = "CROSSOP-TOOL-FACT-7f3a";

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

function toolCallSse(callId: string, path: string): Response {
  const args = JSON.stringify({ path });
  return new Response(
    [
      `data: ${JSON.stringify({
        type: "response.output_item.added",
        output_index: 0,
        item: { type: "function_call", call_id: callId, name: "read" },
      })}`,
      `data: ${JSON.stringify({ type: "response.function_call_arguments.delta", output_index: 0, delta: args })}`,
      `data: ${JSON.stringify({
        type: "response.completed",
        response: {
          status: "completed",
          output: [{ type: "function_call", call_id: callId, name: "read", arguments: args }],
          usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
        },
      })}`,
      "data: [DONE]",
      "",
    ].join("\n\n"),
    { headers: { "content-type": "text/event-stream" } },
  );
}

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

const compactJson = (text: string) =>
  JSON.stringify({
    output: [
      { type: "message", role: "assistant", content: [{ type: "output_text", text }] },
    ],
  });

interface Harness {
  app: CetasApplication;
  requests: Array<{ path: string; body: string }>;
  events: Array<Record<string, unknown>>;
  restoreFetch(): void;
}

// One agent over a temp workspace; the model endpoint is the OpenAI Responses
// SSE route and manual compaction is /responses/compact. The stub must be
// installed before start(): composition already talks to the provider seam.
async function startHarness(
  fetchImpl: (input: unknown, init: { body?: unknown }) => Promise<Response>,
): Promise<Harness> {
  const cwd = await mkdtemp(join(tmpdir(), "cetas-cross-op-"));
  const home = await mkdtemp(join(tmpdir(), "cetas-cross-op-home-"));
  cleanup.push(cwd, home);
  await writeFile(join(cwd, "crossop-note.txt"), `${TOOL_FACT_MARKER}\n`);
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
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl as unknown as typeof fetch;
  const config = { cwd, home, maxToolRounds: 4 };
  const bridge = new MoonbitCetasAgentBridge(config);
  const requests: Array<{ path: string; body: string }> = [];
  const events: Array<Record<string, unknown>> = [];
  const app = new CetasApplication({
    bridge,
    config,
    callbacks: {
      observerCallback: (raw: string) => events.push(JSON.parse(raw) as Record<string, unknown>),
      renderCallback: () => undefined,
      requestCallback: async () => "",
    },
    initialSessionId: "cross-op-session",
  });
  await app.start();
  return {
    app,
    requests,
    events,
    restoreFetch: () => {
      globalThis.fetch = originalFetch;
    },
  };
}

const turnFailedCount = (events: Array<Record<string, unknown>>): number =>
  events.filter((event) => event.type === "turn_failed").length;

const cancelledFinalizeCount = (events: Array<Record<string, unknown>>): number =>
  events.filter(
    (event) =>
      event.type === "operation_finalized" &&
      event.operation === "compact" &&
      event.outcome === "cancelled",
  ).length;

afterEach(async () => {
  for (const path of cleanup.splice(0)) {
    await rm(path, { recursive: true });
  }
});

describe("cross-operation cancellation over the real bridge", () => {
  test(
    "cancel shows once, a late Esc misses the next operation, and a stale stream drives nothing",
    async () => {
      let releaseStaleStream!: () => void;
      const staleStream = new Promise<void>((resolve) => {
        releaseStaleStream = resolve;
      });
      const harness = await startHarness(async (input, init) => {
        const url = String(input);
        if (!url.startsWith("http://cetas.test")) {
          return new Response("service unavailable", { status: 503 });
        }
        if (init.body === undefined || init.body === null) {
          throw new Error("model request body is required");
        }
        const body = await readRequestBody(init.body);
        if (url.endsWith("/responses/compact")) {
          harness.requests.push({ path: "compact", body });
          return new Response(compactJson("unused checkpoint"), {
            headers: { "content-type": "application/json" },
          });
        }
        harness.requests.push({ path: "responses", body });
        const responsesSeen =
          harness.requests.filter((entry) => entry.path === "responses").length;
        if (responsesSeen === 1) {
          return toolCallSse("call_crossop_a", "crossop-note.txt");
        }
        if (responsesSeen === 2) {
          return gatedSseResponse("interrupted reply", staleStream);
        }
        return sseResponse("second reply");
      });
      const { app, requests, events } = harness;

      try {
        const turnA = app.runTurn("crossop first question");
        turnA.catch(() => undefined);
        await waitFor(
          () => requests.filter((entry) => entry.path === "responses").length >= 2,
          "the tool wave or the follow-up model request never started",
        );
        expect(countOf(requests[1]!.body, TOOL_FACT_MARKER)).toBe(1);

        expect(app.interruptActiveTurn()).toBe(true);
        const rejection = await turnA.then(
          () => {
            throw new Error("expected the interrupted turn to reject");
          },
          (error: unknown) => error,
        );
        const text = rejection instanceof Error ? rejection.message : String(rejection);
        expect(text).toContain("category=cancelled");
        expect(turnFailedCount(events)).toBe(1);

        // Esc after the operation settled must not cancel the next one.
        expect(app.interruptActiveTurn()).toBe(false);

        const turnB = app.runTurn("crossop second question");
        await waitFor(
          () => requests.filter((entry) => entry.path === "responses").length >= 3,
          "the second turn never reached the model",
        );
        // Release the abandoned stream of the cancelled operation while the
        // next turn is in flight: its late continuation must stay dead.
        releaseStaleStream();
        expect(await turnB).toContain("second reply");
        await Bun.sleep(30);
        expect(requests.filter((entry) => entry.path === "responses")).toHaveLength(3);
        const bodyB = requests.at(-1)!.body;
        expect(countOf(bodyB, TOOL_FACT_MARKER)).toBe(1);
        expect(countOf(bodyB, "crossop first question")).toBe(1);
        expect(countOf(bodyB, "crossop second question")).toBe(1);
        expect(turnFailedCount(events)).toBe(1);
        await app.shutdown();
      } finally {
        releaseStaleStream();
        harness.restoreFetch();
      }
    },
    20000,
  );

  test(
    "compact switch is observable while waiting, cancels once, and retries without duplicated facts",
    async () => {
      let releaseStaleStream!: () => void;
      const staleStream = new Promise<void>((resolve) => {
        releaseStaleStream = resolve;
      });
      let compactGated = false;
      const harness = await startHarness(async (input, init) => {
        const url = String(input);
        if (!url.startsWith("http://cetas.test")) {
          return new Response("service unavailable", { status: 503 });
        }
        if (init.body === undefined || init.body === null) {
          throw new Error("model request body is required");
        }
        const body = await readRequestBody(init.body);
        if (url.endsWith("/responses/compact")) {
          harness.requests.push({ path: "compact", body });
          if (!compactGated) {
            compactGated = true;
            return new Promise<Response>(() => {});
          }
          return new Response(compactJson("compact checkpoint"), {
            headers: { "content-type": "application/json" },
          });
        }
        harness.requests.push({ path: "responses", body });
        const responsesSeen =
          harness.requests.filter((entry) => entry.path === "responses").length;
        if (responsesSeen === 1) {
          return toolCallSse("call_crossop_b", "crossop-note.txt");
        }
        if (responsesSeen === 2) {
          return gatedSseResponse("interrupted reply", staleStream);
        }
        return sseResponse("after-compact reply");
      });
      const { app, requests, events } = harness;

      try {
        const turnA = app.runTurn("crossop first question");
        turnA.catch(() => undefined);
        await waitFor(
          () => requests.filter((entry) => entry.path === "responses").length >= 2,
          "the tool wave or the follow-up model request never started",
        );

        // Mid-turn /compact: the switch interrupts the turn and waits for its
        // finalize; the pending state is observable, and a second compact is
        // told it is waiting for cleanup instead of writing concurrently.
        const compactCommand = app.compactSession("cross-op-session");
        await waitFor(() => app.compactPending, "the compact switch never became pending");
        await turnA.then(() => undefined, () => undefined);
        await expect(app.compactSession("cross-op-session")).rejects.toThrow(
          /waiting for the interrupted operation/,
        );
        await waitFor(() => compactGated, "the compact request never reached the endpoint");

        // Esc cancels the compact itself: the typed envelope always carries
        // the cancel; the wire finalize event exists only on the mailbox
        // cancel path (a signal abort unwinds at the fetch, past core's
        // cancellation classifier), so it fires at most once.
        expect(app.interruptActiveTurn()).toBe(true);
        expect(await compactCommand).toMatchObject({ ok: false, errorKind: "cancelled" });
        expect(cancelledFinalizeCount(events)).toBeLessThanOrEqual(1);

        // Retry from the last committed context: the interrupted turn's user
        // message and its completed tool fact ride each compact attempt once.
        const retry = await app.compactSession("cross-op-session");
        expect(retry).toMatchObject({ ok: true, mode: "Replace" });
        const compacts = requests.filter((entry) => entry.path === "compact");
        expect(compacts).toHaveLength(2);
        for (const entry of compacts) {
          expect(countOf(entry.body, "crossop first question")).toBe(1);
          expect(countOf(entry.body, TOOL_FACT_MARKER)).toBe(1);
        }

        expect(app.pendingInputs).toEqual([]);

        // After the compact completed, a late Esc is a no-op again.
        expect(app.interruptActiveTurn()).toBe(false);
        const reply = await app.runTurn("crossop after compact");
        expect(reply).toContain("after-compact reply");
        const lastBody = requests.at(-1)!.body;
        expect(lastBody).toContain("compact checkpoint");
        expect(lastBody).not.toContain("crossop first question");
        expect(turnFailedCount(events)).toBe(1);
        await app.shutdown();
      } finally {
        releaseStaleStream();
        harness.restoreFetch();
      }
    },
    20000,
  );
});
