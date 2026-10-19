/**
 * board-controls.test.ts — the narrow Board workflow sync-control lane.
 *
 * The posoco-ext-board CommandPort implements exactly five prompt-free ids
 * (status, preview, pause, stop, cancel) that must stay reachable while a
 * long Board proposal/command or a wave occupies the exclusive lanes. Every
 * test here uses the same fake-bridge shape as application.test.ts: the gate
 * is proven at the application boundary, not against the real MoonBit bundle.
 */

import { describe, expect, test } from "bun:test";
import { CetasApplication, CetasApplicationError } from "./index.ts";
import type {
  AgentCallbacks,
  CetasAgentBridge,
  CetasHostConfig,
  CancellationToken,
  CommandDescriptor,
  ProviderSetupSnapshot,
} from "./index.ts";

const config: CetasHostConfig = { cwd: "/tmp/cetas-js-test", maxToolRounds: 4, home: "/tmp/cetas-js-home" };
const callbacks: AgentCallbacks = {
  observerCallback: () => undefined,
  renderCallback: () => undefined,
  requestCallback: async () => "",
};

/** A setup snapshot with one configured provider, so start() composes an Agent. */
function agentComposingSetup(): ProviderSetupSnapshot {
  return {
    providers: [
      {
        id: "deepseek/chat",
        label: "DeepSeek Chat",
        provider: "deepseek",
        model: "deepseek-chat",
        active: true,
        efforts: [],
        oauth: false,
      },
    ],
    oauthProviders: [],
    activeModelId: "deepseek/chat",
  };
}

function command(id: string): CommandDescriptor {
  return {
    id,
    label: id,
    description: id,
    category: "board",
    ctype: "action",
    params: [],
    aliases: [],
    visible: true,
  };
}

/**
 * Fake bridge whose invokeCommand records ids and delegates to a caller hook,
 * mirroring the Board extension's port (success outcomes, no UI requests).
 */
function boardBridge(overrides: {
  invokeCommand?: (id: string) => Promise<string> | string;
  login?: CetasAgentBridge<{ id: string }>["login"];
}): CetasAgentBridge<{ id: string }> {
  return {
    describeSetup: async () => agentComposingSetup(),
    createAgent: async () => ({ id: "agent" }),
    runTurn: async () => "reply",
    cancelPendingRateLimit: () => undefined,
    shutdown: async () => undefined,
    rewind: async () => undefined,
    listCommands: () => [
      command("board.workflow.propose"),
      command("board.workflow.start"),
      command("model"),
    ],
    invokeCommand: async (_agent, id) =>
      overrides.invokeCommand?.(id) ?? JSON.stringify({ type: "success", feedback: `${id} ok` }),
    ...(overrides.login === undefined ? {} : { login: overrides.login }),
  };
}

/** Park one bridge invokeCommand id on a caller-released promise. */
function parkedId(id: string): {
  started: Promise<void>;
  release: () => void;
  invoke: (invokedId: string) => Promise<string>;
} {
  let release!: () => void;
  const released = new Promise<void>((resolve) => {
    release = resolve;
  });
  let markStarted!: () => void;
  const started = new Promise<void>((resolve) => {
    markStarted = resolve;
  });
  return {
    started,
    release,
    invoke: async (invokedId: string): Promise<string> => {
      if (invokedId !== id) return JSON.stringify({ type: "success", feedback: `${invokedId} ok` });
      markStarted();
      await released;
      return JSON.stringify({ type: "success", feedback: `${invokedId} ok` });
    },
  };
}

async function startedApp(bridge: CetasAgentBridge<{ id: string }>): Promise<CetasApplication<{ id: string }>> {
  const app = new CetasApplication({
    bridge,
    config,
    callbacks,
    initialSessionId: "session-1",
  });
  await app.start();
  return app;
}

describe("Board workflow sync-control lane", () => {
  test("controls resolve while a long Board command holds the exclusive command lock", async () => {
    const proposal = parkedId("board.workflow.propose");
    const invoked: string[] = [];
    const app = await startedApp(boardBridge({
      invokeCommand: async (id) => {
        invoked.push(id);
        return proposal.invoke(id);
      },
    }));

    const pendingProposal = app.invokeCommand("board.workflow.propose");
    await proposal.started;
    // Reads and admission flags stay reachable during the long proposal…
    await expect(app.invokeCommand("board.workflow.status")).resolves.toContain("board.workflow.status ok");
    await expect(app.invokeCommand("board.workflow.pause")).resolves.toContain("board.workflow.pause ok");
    // …while real Board operations keep the exclusive path.
    await expect(app.invokeCommand("board.workflow.start")).rejects.toMatchObject({ code: "already_running" });
    await expect(app.invokeCommand("board.workflow.graph.approve")).rejects.toMatchObject({ code: "already_running" });
    await expect(app.invokeCommand("model")).rejects.toMatchObject({ code: "already_running" });
    expect(invoked).toEqual(["board.workflow.propose", "board.workflow.status", "board.workflow.pause"]);

    proposal.release();
    await pendingProposal;
    await app.shutdown();
  });

  test("controls never reset the global cancellation and never unlock the lane", async () => {
    let observedCancel = false;
    let markLoginStarted!: () => void;
    const loginStarted = new Promise<void>((resolve) => {
      markLoginStarted = resolve;
    });
    let releaseLogin!: () => void;
    const loginReleased = new Promise<void>((resolve) => {
      releaseLogin = resolve;
    });
    const app = await startedApp(boardBridge({
      invokeCommand: (id) => JSON.stringify({ type: "success", feedback: `${id} ok` }),
      login: async (_config, _provider, _callbacks, cancellation?: CancellationToken) => {
        markLoginStarted();
        await loginReleased;
        // A control ran in between; it must not have re-armed the token.
        observedCancel = cancellation?.isCancelled() === true;
        return JSON.stringify({ type: "success", feedback: "login ok" });
      },
    }));

    const pendingLogin = app.invokeCommand("login", JSON.stringify({ provider: "kimi" }));
    await loginStarted;
    expect(app.cancelCurrentOperation()).toBe(true);
    await expect(app.invokeCommand("board.workflow.status")).resolves.toContain("board.workflow.status ok");

    // The control settled without touching occupancy: the login still owns
    // the lane, so no turn and no second mutation can slip in.
    await expect(app.invokeCommand("board.workflow.start")).rejects.toMatchObject({ code: "already_running" });
    await expect(app.runTurn("hello")).rejects.toMatchObject({ code: "already_running" });

    releaseLogin();
    await pendingLogin;
    expect(observedCancel).toBe(true);
    await app.shutdown();
  });

  test("controls are refused once shutdown has begun", async () => {
    const app = await startedApp(boardBridge({}));
    const shutdown = app.shutdown();
    await expect(app.invokeCommand("board.workflow.status")).rejects.toMatchObject({
      code: "shutting_down",
    });
    await expect(app.invokeCommand("board.workflow.cancel")).rejects.toBeInstanceOf(CetasApplicationError);
    await shutdown;
  });

  test("controls stay reachable while a wave turn executes", async () => {
    let markTurnStarted!: () => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    let releaseTurn!: () => void;
    const turnReleased = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    const invoked: string[] = [];
    const base = boardBridge({});
    const app = await startedApp({
      ...base,
      runTurn: async () => {
        markTurnStarted();
        await turnReleased;
        return "reply";
      },
      invokeCommand: async (_agent, id) => {
        invoked.push(id);
        return JSON.stringify({ type: "success", feedback: `${id} ok` });
      },
    });

    const turn = app.runTurn("run next wave");
    await turnStarted;
    await expect(app.invokeCommand("board.workflow.stop")).resolves.toContain("board.workflow.stop ok");
    await expect(app.invokeCommand("board.workflow.preview")).resolves.toContain("board.workflow.preview ok");
    // Wave-carrying operations themselves are never admitted mid-turn.
    await expect(app.invokeCommand("board.workflow.run")).rejects.toMatchObject({ code: "already_running" });
    await expect(app.invokeCommand("board.workflow.prepare")).rejects.toMatchObject({ code: "already_running" });
    await expect(app.invokeCommand("model")).rejects.toMatchObject({ code: "already_running" });
    expect(invoked).toEqual(["board.workflow.stop", "board.workflow.preview"]);

    releaseTurn();
    await expect(turn).resolves.toBe("reply");
    await app.shutdown();
  });
});
