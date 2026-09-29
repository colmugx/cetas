import { describe, expect, test } from "bun:test";

import { CetasApplication } from "./application.ts";
import type {
  AgentCallbacks,
  CetasAgentBridge,
  CetasHostConfig,
} from "./types.ts";

const config: CetasHostConfig = {
  cwd: "/tmp/project",
  home: "/tmp/home",
  maxToolRounds: 4,
};

function bridgeWithRecovery(overrides: Partial<CetasAgentBridge<object>> = {}): {
  bridge: CetasAgentBridge<object>;
  callbacks: () => AgentCallbacks;
  cancellations: string[];
} {
  let liveCallbacks: AgentCallbacks | undefined;
  const cancellations: string[] = [];
  const bridge: CetasAgentBridge<object> = {
    describeSetup: async () => ({
      providers: [{
        id: "deepseek:test",
        label: "test",
        provider: "deepseek",
        model: "test",
        active: true,
        efforts: [],
        oauth: false,
      }],
      oauthProviders: [],
    }),
    createAgent: async (_config, callbacks) => {
      liveCallbacks = callbacks;
      return { id: "agent" };
    },
    runTurn: async () => "reply",
    abortTurn: () => "Accepted(run_id=test)",
    enqueueFollowUp: () => "Accepted(run_id=test)",
    cancelPendingRateLimit: () => cancellations.push("cancel"),
    shutdown: async () => undefined,
    listCommands: () => [],
    invokeCommand: async () => JSON.stringify({ type: "success" }),
    rewind: async () => undefined,
    ...overrides,
  };
  return {
    bridge,
    callbacks: () => {
      if (liveCallbacks === undefined) throw new Error("Agent was not created");
      return liveCallbacks;
    },
    cancellations,
  };
}

const callbacks: AgentCallbacks = {
  observerCallback: () => undefined,
  renderCallback: () => undefined,
  requestCallback: async () => "",
};

describe("rate-limit recovery host lifecycle", () => {
  test("an idle runtime-owned recovery owns the application busy state", async () => {
    const fixture = bridgeWithRecovery();
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();

    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_started" }));
    expect(app.appState).toBe("running");
    await expect(app.runTurn("must serialize")).rejects.toThrow("already running");
    expect(app.queueFollowUp("after recovery")).toBe("accepted");

    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_completed" }));
    expect(app.appState).toBe("running");
    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_started" }));
    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_completed" }));
    expect(app.appState).toBe("ready");
    await app.shutdown();
  });

  test("session intent invalidates pending recovery before mutation", async () => {
    let app!: CetasApplication<object>;
    const invalidatedSessions: string[] = [];
    const fixture = bridgeWithRecovery({
      cancelPendingRateLimit: () => invalidatedSessions.push(app.sessionId),
    });
    app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();

    app.setSession("session-b");
    expect(invalidatedSessions).toEqual(["session-a"]);
    expect(app.sessionId).toBe("session-b");
    await app.shutdown();
  });

  test("opening the model picker preserves recovery; successful selection invalidates it", async () => {
    const fixture = bridgeWithRecovery();
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();

    await app.invokeCommand("model", "{}");
    expect(fixture.cancellations).toEqual([]);

    await app.invokeCommand("model", JSON.stringify({ slot: "deepseek:other" }));
    expect(fixture.cancellations).toEqual(["cancel"]);
    await app.shutdown();
  });

  test("a manual send invalidates stale recovery without stopping a scheduler", async () => {
    const runs: string[] = [];
    const fixture = bridgeWithRecovery({
      runTurn: async (_agent, prompt) => {
        runs.push(prompt);
        return "reply";
      },
    });
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();

    await expect(app.runTurn("new intent")).resolves.toBe("reply");
    expect(fixture.cancellations).toEqual(["cancel"]);
    expect(runs).toEqual(["new intent"]);
    await app.shutdown();
  });

  test("shutdown invalidates recovery before releasing the Agent", async () => {
    const actions: string[] = [];
    const fixture = bridgeWithRecovery({
      cancelPendingRateLimit: () => actions.push("cancel"),
      shutdown: async () => {
        actions.push("shutdown");
      },
    });
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();

    await app.shutdown();
    expect(actions).toEqual(["cancel", "shutdown"]);
  });

  test("a throwing observer callback during recovery still releases the busy state", async () => {
    const fixture = bridgeWithRecovery();
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks: {
        ...callbacks,
        observerCallback: (raw) => {
          if ((JSON.parse(raw) as { type?: string }).type === "turn_completed") {
            throw new Error("renderer exploded");
          }
        },
      },
      initialSessionId: "session-a",
    });
    await app.start();

    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_started" }));
    expect(app.appState).toBe("running");
    expect(() =>
      fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_completed" }))
    ).toThrow("renderer exploded");
    expect(app.appState).toBe("ready");
    await expect(app.runTurn("after renderer failure")).resolves.toBe("reply");
    await app.shutdown();
  });
});
