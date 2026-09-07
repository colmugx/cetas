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

function abortableMonitor(signal: AbortSignal): Promise<void> {
  return new Promise<void>((_resolve, reject) => {
    if (signal.aborted) {
      reject(new DOMException("aborted", "AbortError"));
      return;
    }
    signal.addEventListener("abort", () => {
      reject(new DOMException("aborted", "AbortError"));
    }, { once: true });
  });
}

function bridgeWithMonitor(overrides: Partial<CetasAgentBridge<object>> = {}): {
  bridge: CetasAgentBridge<object>;
  callbacks: () => AgentCallbacks;
  monitorSignals: AbortSignal[];
  cancellations: string[];
} {
  let liveCallbacks: AgentCallbacks | undefined;
  const monitorSignals: AbortSignal[] = [];
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
    startRateLimitMonitor: async (_agent, signal) => {
      monitorSignals.push(signal);
      await abortableMonitor(signal);
    },
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
    monitorSignals,
    cancellations,
  };
}

const callbacks: AgentCallbacks = {
  observerCallback: () => undefined,
  renderCallback: () => undefined,
  requestCallback: async () => "",
};

describe("rate-limit recovery host lifecycle", () => {
  test("monitor recovery owns the application busy state", async () => {
    const fixture = bridgeWithMonitor();
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();
    await Promise.resolve();

    expect(fixture.monitorSignals).toHaveLength(1);
    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_started" }));
    expect(app.appState).toBe("running");
    await expect(app.runTurn("must serialize")).rejects.toThrow("already running");
    expect(app.queueFollowUp("after recovery")).toBe("accepted");

    // The queued follow-up drains as its own turn after TurnCompleted, so the
    // busy state survives the boundary instead of exposing a false idle gap.
    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_completed" }));
    expect(app.appState).toBe("running");
    await expect(app.runTurn("must not interleave")).rejects.toThrow("already running");
    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_started" }));
    expect(app.appState).toBe("running");
    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_completed" }));
    expect(app.appState).toBe("ready");
    await app.shutdown();
  });

  test("session intent cancels before mutation and starts a fresh monitor", async () => {
    let app!: CetasApplication<object>;
    const fixture = bridgeWithMonitor({
      cancelPendingRateLimit: () => fixture.cancellations.push(app.sessionId),
    });
    app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();
    await Promise.resolve();
    const firstSignal = fixture.monitorSignals[0]!;

    app.setSession("session-b");
    expect(fixture.cancellations).toEqual(["session-a"]);
    expect(firstSignal.aborted).toBe(true);
    await Bun.sleep(0);
    expect(fixture.monitorSignals).toHaveLength(2);
    await app.shutdown();
  });

  test("opening the model picker preserves recovery; successful selection cancels it", async () => {
    const fixture = bridgeWithMonitor();
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();
    await Promise.resolve();
    const firstSignal = fixture.monitorSignals[0]!;

    await app.invokeCommand("model", "{}");
    expect(firstSignal.aborted).toBe(false);
    expect(fixture.cancellations).toEqual([]);

    await app.invokeCommand("model", JSON.stringify({ slot: "deepseek:other" }));
    expect(firstSignal.aborted).toBe(true);
    expect(fixture.cancellations).toEqual(["cancel"]);
    await Promise.resolve();
    expect(fixture.monitorSignals).toHaveLength(2);
    await app.shutdown();
  });

  test("a manual send supersedes recovery and monitor restarts after the turn", async () => {
    const fixture = bridgeWithMonitor();
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();
    await Promise.resolve();
    const firstSignal = fixture.monitorSignals[0]!;

    await expect(app.runTurn("new intent")).resolves.toBe("reply");
    expect(firstSignal.aborted).toBe(true);
    expect(fixture.cancellations).toEqual(["cancel"]);
    await Promise.resolve();
    expect(fixture.monitorSignals).toHaveLength(2);
    await app.shutdown();
  });

  test("switching away and back waits for the old monitor and starts one fresh monitor", async () => {
    const signals: AbortSignal[] = [];
    const cancellations: string[] = [];
    let releaseFirst!: () => void;
    const firstReleased = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    let app!: CetasApplication<object>;
    const fixture = bridgeWithMonitor({
      startRateLimitMonitor: async (_agent, signal) => {
        signals.push(signal);
        if (signals.length === 1) {
          await firstReleased;
          return;
        }
        await abortableMonitor(signal);
      },
      cancelPendingRateLimit: () => cancellations.push(app.sessionId),
    });
    app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });

    await app.start();
    await Promise.resolve();
    expect(signals).toHaveLength(1);

    app.setSession("session-b");
    app.setSession("session-a");
    expect(cancellations).toEqual(["session-a", "session-b"]);
    expect(signals[0]?.aborted).toBe(true);
    expect(signals).toHaveLength(1);

    releaseFirst();
    for (let i = 0; i < 8 && signals.length < 2; i += 1) {
      await Promise.resolve();
      await Bun.sleep(0);
    }
    expect(signals).toHaveLength(2);
    await app.shutdown();
  });

  test("a new-session switch blocks stale recovery and does not overlap a manual send", async () => {
    const signals: AbortSignal[] = [];
    const runs: string[] = [];
    let releaseFirst!: () => void;
    const firstReleased = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const fixture = bridgeWithMonitor({
      startRateLimitMonitor: async (_agent, signal) => {
        signals.push(signal);
        if (signals.length === 1) {
          await firstReleased;
          return;
        }
        await abortableMonitor(signal);
      },
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
    await Promise.resolve();
    app.setSession("session-new");
    // A late event from the cancelled monitor must not revive the old turn.
    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_started" }));
    expect(app.appState).toBe("ready");
    const turn = app.runTurn("new intent");
    await Promise.resolve();
    expect(runs).toEqual([]);
    expect(signals).toHaveLength(1);

    releaseFirst();
    await expect(turn).resolves.toBe("reply");
    expect(runs).toEqual(["new intent"]);
    for (let i = 0; i < 8 && signals.length < 2; i += 1) {
      await Promise.resolve();
      await Bun.sleep(0);
    }
    expect(signals).toHaveLength(2);
    await app.shutdown();
  });

  test("shutdown aborts the monitor before releasing the Agent", async () => {
    const actions: string[] = [];
    const fixture = bridgeWithMonitor({
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
    await Promise.resolve();
    const signal = fixture.monitorSignals[0]!;
    signal.addEventListener("abort", () => actions.push("abort"), { once: true });

    await app.shutdown();
    expect(actions).toEqual(["cancel", "abort", "shutdown"]);
  });

  test("an unexpected monitor failure is published as state and observer data", async () => {
    const events: unknown[] = [];
    const fixture = bridgeWithMonitor({
      startRateLimitMonitor: async () => {
        throw new Error("clock broke");
      },
    });
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks: {
        ...callbacks,
        observerCallback: (raw) => events.push(JSON.parse(raw)),
      },
      initialSessionId: "session-a",
    });
    await app.start();
    await Promise.resolve();
    await Promise.resolve();

    expect(app.snapshot().error).toContain("rate-limit monitor failed: clock broke");
    expect(events).toContainEqual(expect.objectContaining({
      type: "custom",
      label: "ratelimit_monitor_failed",
    }));
    await app.shutdown();
  });

  test("a monitor that dies mid-recovery releases the busy state", async () => {
    let releaseMonitor!: () => void;
    const monitorHeld = new Promise<void>((resolve) => {
      releaseMonitor = resolve;
    });
    const fixture = bridgeWithMonitor({
      startRateLimitMonitor: async (_agent, signal) => {
        if (!signal.aborted) {
          await monitorHeld;
        }
        throw new Error("monitor died mid-recovery");
      },
    });
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-a",
    });
    await app.start();
    await Promise.resolve();

    fixture.callbacks().observerCallback(JSON.stringify({ type: "turn_started" }));
    expect(app.appState).toBe("running");
    releaseMonitor();
    for (let i = 0; i < 8; i += 1) {
      await Promise.resolve();
      await Bun.sleep(0);
    }
    // The recovery turn ran inline in the monitor coroutine: its death can
    // never produce a turn boundary, so the settled cleanup must unwind the
    // busy state instead of wedging the application.
    expect(app.appState).toBe("ready");
    expect(app.snapshot().error).toContain(
      "rate-limit monitor failed: monitor died mid-recovery",
    );
    await app.shutdown();
  });

  test("a throwing observer callback during recovery still releases the busy state", async () => {
    const fixture = bridgeWithMonitor();
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
    await Promise.resolve();

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
