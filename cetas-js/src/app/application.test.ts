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

function command(id: string): CommandDescriptor {
  return {
    id,
    label: id,
    description: id,
    category: "test",
    ctype: "action",
    params: [],
    aliases: [],
    visible: true,
  };
}

function bridgeFor(
  setup: ProviderSetupSnapshot,
  counters: { created: number; runs: number; shutdowns: number },
): CetasAgentBridge<{ id: string }> {
  return {
    describeSetup: async () => setup,
    createAgent: async () => {
      counters.created += 1;
      return { id: "agent" };
    },
    runTurn: async () => {
      counters.runs += 1;
      return "reply";
    },
    shutdown: async () => {
      counters.shutdowns += 1;
    },
    listCommands: () => [command("model"), command("login")],
    invokeCommand: async (_agent, id) => JSON.stringify({ type: "success", id }),
  };
}

describe("CetasApplication", () => {
  test("keeps an empty provider setup usable without composing Agent", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: bridgeFor({ providers: [], oauthProviders: [] }, counters),
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    expect((await app.start()).state).toBe("needs_setup");
    expect(counters.created).toBe(0);
    expect(app.listCommands().map((item) => item.id)).toEqual(["model", "login"]);
    expect(await app.invokeCommand("model")).toContain('"code":"not_ready"');
    await expect(app.runTurn("hello")).rejects.toBeInstanceOf(CetasApplicationError);
  });

  test("composes one Agent after capability discovery and reuses it across turns", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: bridgeFor(
        {
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
        },
        counters,
      ),
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    expect((await app.start()).state).toBe("ready");
    expect(counters.created).toBe(1);
    expect(await app.runTurn("first")).toBe("reply");
    expect(await app.runTurn("second")).toBe("reply");
    expect(counters.runs).toBe(2);
    expect(app.appState).toBe("ready");
    await app.shutdown();
    await app.shutdown();
    expect(counters.shutdowns).toBe(1);
    expect(app.appState).toBe("shutting_down");
  });

  test("refreshes catalogs once at startup, never for /model, and only the logged-in provider", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const refreshes: (readonly string[] | undefined)[] = [];
    const setup: ProviderSetupSnapshot = {
      providers: [
        {
          id: "kimi/chat",
          label: "Kimi Chat",
          provider: "kimi",
          model: "kimi-k2",
          active: true,
          efforts: ["low", "high"],
          oauth: true,
        },
      ],
      oauthProviders: ["kimi"],
      authProviders: [{ id: "kimi", methods: ["oauth"] }],
      activeModelId: "kimi/chat",
    };
    const base = bridgeFor(setup, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        refreshModelCatalogs: async (_config, providers) => {
          refreshes.push(providers);
          return setup;
        },
        describeSetup: async () => setup,
        invokeCommand: async (_agent, id) =>
          id === "model"
            ? JSON.stringify({
                type: "success",
                structured: [],
                ui_hint: "refresh_model_list",
              })
            : JSON.stringify({ type: "success", id }),
        login: async () => JSON.stringify({ type: "success", feedback: "logged in" }),
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    expect(refreshes).toEqual([undefined]);
    await app.invokeCommand("model", "{}");
    expect(refreshes).toHaveLength(1);
    const login = await app.invokeCommand(
      "login",
      JSON.stringify({ provider: "kimi", method: "oauth" }),
    );
    expect(login).toContain("logged in");
    expect(refreshes).toEqual([undefined, ["kimi"]]);
    await app.shutdown();
  });

  test("does not retry a failed startup catalog refresh through start()", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let refreshAttempts = 0;
    const base = bridgeFor({ providers: [], oauthProviders: [] }, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        refreshModelCatalogs: async () => {
          refreshAttempts += 1;
          throw new Error("catalog endpoint unavailable");
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await expect(app.start()).rejects.toThrow("catalog endpoint unavailable");
    expect((await app.start()).state).toBe("needs_setup");
    expect(refreshAttempts).toBe(1);
    expect(app.snapshot().error).toBe("catalog endpoint unavailable");
  });

  test("invokes the startup catalog refresh with the bridge instance as receiver", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const base = bridgeFor({ providers: [], oauthProviders: [] }, counters);
    // Regression: a class-backed bridge relies on its own `this`; calling the
    // optional refresh unbound must not crash setup discovery.
    class ClassBridge implements CetasAgentBridge<{ id: string }> {
      refreshes = 0;
      describeSetup = base.describeSetup;
      createAgent = base.createAgent;
      runTurn = base.runTurn;
      shutdown = base.shutdown;
      listCommands = base.listCommands;
      invokeCommand = base.invokeCommand;
      async refreshModelCatalogs(): Promise<ProviderSetupSnapshot> {
        this.refreshes += 1;
        return { providers: [], oauthProviders: [] };
      }
    }
    const bridge = new ClassBridge();
    const app = new CetasApplication({
      bridge,
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    expect((await app.start()).state).toBe("needs_setup");
    expect(bridge.refreshes).toBe(1);
    await app.shutdown();
  });

  test("rejects commands during a turn and waits for the turn before shutdown", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markTurnStarted!: () => void;
    let releaseTurn!: () => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    const turnReleased = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    const base = bridgeFor(
      {
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
      },
      counters,
    );
    const app = new CetasApplication({
      bridge: {
        ...base,
        runTurn: async () => {
          counters.runs += 1;
          markTurnStarted();
          await turnReleased;
          return "reply";
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const turn = app.runTurn("hello");
    await turnStarted;
    await expect(app.invokeCommand("model")).rejects.toMatchObject({
      code: "already_running",
    });

    const shutdown = app.shutdown();
    expect(counters.shutdowns).toBe(0);
    releaseTurn();
    await expect(turn).resolves.toBe("reply");
    await shutdown;
    expect(counters.shutdowns).toBe(1);
    expect(app.appState).toBe("shutting_down");
  });

  test("serializes commands and blocks turns until the command completes", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markCommandStarted!: () => void;
    let releaseCommand!: () => void;
    const commandStarted = new Promise<void>((resolve) => {
      markCommandStarted = resolve;
    });
    const commandReleased = new Promise<void>((resolve) => {
      releaseCommand = resolve;
    });
    const base = bridgeFor(
      {
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
      },
      counters,
    );
    const app = new CetasApplication({
      bridge: {
        ...base,
        invokeCommand: async (_agent, id) => {
          markCommandStarted();
          await commandReleased;
          return JSON.stringify({ type: "success", id });
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const command = app.invokeCommand("model");
    await commandStarted;
    await expect(app.invokeCommand("login")).rejects.toMatchObject({
      code: "already_running",
    });
    await expect(app.runTurn("hello")).rejects.toMatchObject({
      code: "already_running",
    });
    releaseCommand();
    await expect(command).resolves.toContain('"success"');
    await app.shutdown();
  });

  test("refreshSetup re-discovers settings without restarting the process", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let configured = false;
    let discoveries = 0;
    const readySetup: ProviderSetupSnapshot = {
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
    const base = bridgeFor({ providers: [], oauthProviders: [] }, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        describeSetup: async () => {
          discoveries += 1;
          return configured ? readySetup : { providers: [], oauthProviders: [] };
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    expect((await app.start()).state).toBe("needs_setup");
    configured = true;
    expect((await app.refreshSetup()).state).toBe("ready");
    expect(counters.created).toBe(1);
    configured = false;
    expect((await app.refreshSetup()).state).toBe("needs_setup");
    expect(counters.shutdowns).toBe(1);
    configured = true;
    expect((await app.refreshSetup()).state).toBe("ready");
    expect(counters.created).toBe(2);
    expect(discoveries).toBe(4);
    await app.shutdown();
    expect(counters.shutdowns).toBe(2);
  });

  test("does not hide setup discovery failures", async () => {
    const app = new CetasApplication({
      bridge: {
        ...bridgeFor({ providers: [], oauthProviders: [] }, {
          created: 0,
          runs: 0,
          shutdowns: 0,
        }),
        describeSetup: async () => {
          throw new Error("settings.json is malformed");
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await expect(app.start()).rejects.toMatchObject({
      code: "bridge_failure",
      message: "cetas-js setup failed: settings.json is malformed",
    });
    expect(app.snapshot().state).toBe("needs_setup");
    expect(app.snapshot().error).toBe("settings.json is malformed");
  });

  test("allows setup discovery to be retried after a transient failure", async () => {
    let attempts = 0;
    const app = new CetasApplication({
      bridge: {
        ...bridgeFor({ providers: [], oauthProviders: [] }, {
          created: 0,
          runs: 0,
          shutdowns: 0,
        }),
        describeSetup: async () => {
          attempts += 1;
          if (attempts === 1) throw new Error("settings temporarily unavailable");
          return { providers: [], oauthProviders: [] };
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await expect(app.start()).rejects.toThrow("settings temporarily unavailable");
    expect((await app.start()).state).toBe("needs_setup");
    expect(attempts).toBe(2);
  });

  test("rejects a restart after shutdown", async () => {
    const app = new CetasApplication({
      bridge: bridgeFor({ providers: [], oauthProviders: [] }, {
        created: 0,
        runs: 0,
        shutdowns: 0,
      }),
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();
    await app.shutdown();
    await expect(app.start()).rejects.toMatchObject({ code: "shutting_down" });
  });

  test("delegates agentless login to the provider extension before composing", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let discovered = false;
    const base = bridgeFor({ providers: [], oauthProviders: ["kimi"] }, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        describeSetup: async () =>
          discovered
            ? {
                providers: [
                  {
                    id: "kimi/chat",
                    label: "Kimi Chat",
                    provider: "kimi",
                    model: "kimi-k2",
                    active: true,
                    efforts: ["low", "high"],
                    oauth: true,
                  },
                ],
                oauthProviders: ["kimi"],
              }
            : { providers: [], oauthProviders: ["kimi"] },
        login: async (_config, provider, _callbacks, _cancellation, method) => {
          expect(provider).toBe("kimi");
          expect(method).toBe("oauth");
          discovered = true;
          return JSON.stringify({ type: "success", feedback: "Logged in to kimi" });
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();
    const result = await app.invokeCommand("login", JSON.stringify({ provider: "kimi", method: "oauth" }));
    expect(result).toContain("Logged in");
    expect(app.appState).toBe("ready");
    expect(counters.created).toBe(1);
  });

  test("uses direct provider login for an unconfigured provider and recomposes a live Agent", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let discoveryCount = 0;
    const openaiSetup: ProviderSetupSnapshot = {
      providers: [
        {
          id: "openai/chat",
          label: "OpenAI Chat",
          provider: "openai",
          model: "gpt-4o",
          active: true,
          efforts: [],
          oauth: true,
        },
      ],
      oauthProviders: ["openai", "kimi"],
      authProviders: [
        { id: "openai", methods: ["api_key", "oauth"] },
        { id: "kimi", methods: ["oauth"] },
      ],
      activeModelId: "openai/chat",
    };
    const configuredSetup: ProviderSetupSnapshot = {
      ...openaiSetup,
      providers: [
        ...openaiSetup.providers,
        {
          id: "kimi/chat",
          label: "Kimi Chat",
          provider: "kimi",
          model: "kimi-k2",
          active: false,
          efforts: [],
          oauth: true,
        },
      ],
    };
    let loginProvider = "";
    let loginMethod = "";
    const base = bridgeFor(openaiSetup, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        describeSetup: async () => {
          discoveryCount += 1;
          return discoveryCount === 1 ? openaiSetup : configuredSetup;
        },
        login: async (_config, provider, _callbacks, _cancellation, method) => {
          loginProvider = provider;
          loginMethod = method ?? "";
          return JSON.stringify({
            type: "success",
            feedback: "Logged in to kimi",
          });
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    expect(counters.created).toBe(1);
    const result = await app.invokeCommand(
      "login",
      JSON.stringify({ provider: "kimi", method: "oauth" }),
    );
    expect(result).toContain("Logged in to kimi");
    expect(loginProvider).toBe("kimi");
    expect(loginMethod).toBe("oauth");
    expect(discoveryCount).toBe(2);
    expect(counters.shutdowns).toBe(1);
    expect(counters.created).toBe(2);
    expect(app.appState).toBe("ready");
    await app.shutdown();
    expect(counters.shutdowns).toBe(2);
  });

  test("cancels an active OAuth command and clears the operation lock", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markLoginStarted!: () => void;
    let releaseLogin!: () => void;
    const loginStarted = new Promise<void>((resolve) => {
      markLoginStarted = resolve;
    });
    const loginReleased = new Promise<void>((resolve) => {
      releaseLogin = resolve;
    });
    const base = bridgeFor({ providers: [], oauthProviders: ["kimi"] }, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        login: async (
          _config,
          _provider,
          _callbacks,
          cancellation?: CancellationToken,
        ) => {
          markLoginStarted();
          await loginReleased;
          if (cancellation?.isCancelled()) throw new Error("oauth cancelled");
          return JSON.stringify({ type: "success" });
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const login = app.invokeCommand("login", JSON.stringify({ provider: "kimi" }));
    await loginStarted;
    expect(app.cancelCurrentOperation()).toBe(true);
    releaseLogin();
    await expect(login).rejects.toThrow("oauth cancelled");
    expect(app.cancelCurrentOperation()).toBe(false);
  });

  test("interrupts an active turn through the bridge abort seam", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markTurnStarted!: () => void;
    let releaseTurn!: (text: string) => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    const turnReleased = new Promise<string>((resolve) => {
      releaseTurn = resolve;
    });
    let abortedAgent: unknown;
    const base = bridgeFor(
      {
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
      },
      counters,
    );
    const app = new CetasApplication({
      bridge: {
        ...base,
        runTurn: () => {
          markTurnStarted();
          return turnReleased;
        },
        abortTurn: (agent) => {
          abortedAgent = agent;
          return "Accepted(abort_1)";
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const turn = app.runTurn("hello");
    await turnStarted;
    expect(app.interruptActiveTurn()).toBe(true);
    expect(abortedAgent).toEqual({ id: "agent" });
    // An aborted turn still settles normally, with the partial transcript.
    releaseTurn("partial reply");
    await expect(turn).resolves.toBe("partial reply");
    expect(app.interruptActiveTurn()).toBe(false);
    expect(app.appState).toBe("ready");
  });

  test("interruptActiveTurn reports false when no turn is active", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: bridgeFor({ providers: [], oauthProviders: [] }, counters),
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    expect(app.interruptActiveTurn()).toBe(false);
    await app.start();
    expect(app.interruptActiveTurn()).toBe(false);
  });

  test("runTurn passes a live signal and interruptActiveTurn aborts it", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markTurnStarted!: () => void;
    let releaseTurn!: () => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    const turnReleased = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    let seenSignal: AbortSignal | undefined;
    const base = bridgeFor(
      {
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
      },
      counters,
    );
    const app = new CetasApplication({
      bridge: {
        ...base,
        runTurn: (_agent, _prompt, _sessionId, signal) => {
          seenSignal = signal;
          markTurnStarted();
          return turnReleased.then(() => "partial reply");
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const turn = app.runTurn("hello");
    await turnStarted;
    expect(seenSignal).toBeDefined();
    expect(seenSignal!.aborted).toBe(false);
    expect(app.interruptActiveTurn()).toBe(true);
    expect(seenSignal!.aborted).toBe(true);
    releaseTurn();
    await expect(turn).resolves.toBe("partial reply");
  });

  test("queueFollowUp maps bridge outcomes and requires an active turn", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markTurnStarted!: () => void;
    let releaseTurn!: () => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    const turnReleased = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    const enqueued: string[] = [];
    let outcome = "Accepted(follow_up_1)";
    const base = bridgeFor(
      {
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
      },
      counters,
    );
    const app = new CetasApplication({
      bridge: {
        ...base,
        runTurn: async () => {
          markTurnStarted();
          await turnReleased;
          return "reply";
        },
        enqueueFollowUp: (_agent, prompt) => {
          enqueued.push(prompt);
          return outcome;
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    expect(() => app.queueFollowUp("orphan")).toThrow(CetasApplicationError);

    const turn = app.runTurn("hello");
    await turnStarted;
    expect(app.queueFollowUp("first")).toBe("accepted");
    outcome = "RejectedStale(reason=...)";
    expect(app.queueFollowUp("second")).toBe("stale");
    outcome = "RejectedQueueFull(depth=64)";
    expect(app.queueFollowUp("third")).toBe("full");
    expect(enqueued).toEqual(["first", "second", "third"]);

    releaseTurn();
    await turn;
  });

  test("invokeCommand allows /permission mid-turn and still rejects others", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markTurnStarted!: () => void;
    let releaseTurn!: () => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    const turnReleased = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    const invoked: string[] = [];
    const base = bridgeFor(
      {
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
      },
      counters,
    );
    const app = new CetasApplication({
      bridge: {
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
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const turn = app.runTurn("hello");
    await turnStarted;
    await expect(app.invokeCommand("permission", JSON.stringify({ action: "yolo" })))
      .resolves.toContain("permission ok");
    await expect(app.invokeCommand("model")).rejects.toMatchObject({
      code: "already_running",
    });
    expect(invoked).toEqual(["permission"]);

    releaseTurn();
    await turn;
  });

  test("direct shutdown cancels pending OAuth and cleans up the Agent", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markLoginStarted!: () => void;
    let releaseLogin!: () => void;
    let cancellationSeen = false;
    const loginStarted = new Promise<void>((resolve) => {
      markLoginStarted = resolve;
    });
    const loginReleased = new Promise<void>((resolve) => {
      releaseLogin = resolve;
    });
    const base = bridgeFor(
      {
        providers: [
          {
            id: "kimi/chat",
            label: "Kimi Chat",
            provider: "kimi",
            model: "kimi-k2",
            active: true,
            efforts: ["low", "high"],
            oauth: true,
          },
        ],
        oauthProviders: ["kimi"],
      },
      counters,
    );
    let agentCancellation: CancellationToken | undefined;
    const app = new CetasApplication({
      bridge: {
        ...base,
        createAgent: async (_config, _callbacks, cancellation) => {
          counters.created += 1;
          agentCancellation = cancellation;
          return { id: "agent" };
        },
        invokeCommand: async () => {
          markLoginStarted();
          await loginReleased;
          cancellationSeen = agentCancellation?.isCancelled() ?? false;
          return JSON.stringify({
            type: "failure",
            reason: "oauth cancelled",
          });
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const login = app.invokeCommand("login", JSON.stringify({ provider: "kimi" }));
    await loginStarted;
    const shutdown = app.shutdown();
    // Let the fake provider's pending poll settle after shutdown has requested
    // cancellation. A real provider observes the same token in its polling
    // loop and does not need the terminal overlay to be closed first.
    releaseLogin();
    await expect(login).resolves.toContain("oauth cancelled");
    await expect(shutdown).resolves.toBeUndefined();
    expect(cancellationSeen).toBe(true);
    expect(counters.created).toBe(1);
    expect(counters.shutdowns).toBe(1);
    expect(app.appState).toBe("shutting_down");
    expect(app.cancelCurrentOperation()).toBe(false);
  });

  test("shutdown does not swallow an ordinary pending command error", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markCommandStarted!: () => void;
    let releaseCommand!: () => void;
    const commandStarted = new Promise<void>((resolve) => {
      markCommandStarted = resolve;
    });
    const commandReleased = new Promise<void>((resolve) => {
      releaseCommand = resolve;
    });
    const base = bridgeFor(
      {
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
      },
      counters,
    );
    const app = new CetasApplication({
      bridge: {
        ...base,
        invokeCommand: async () => {
          markCommandStarted();
          await commandReleased;
          throw new Error("ordinary command failed");
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const commandPromise = app.invokeCommand("model");
    await commandStarted;
    const shutdown = app.shutdown();
    const commandResult = commandPromise.catch((error: unknown) => error);
    const shutdownResult = shutdown.catch((error: unknown) => error);
    releaseCommand();
    const commandError = await commandResult;
    const shutdownError = await shutdownResult;
    expect(commandError).toBeInstanceOf(Error);
    expect((commandError as Error).message).toBe("ordinary command failed");
    expect(shutdownError).toBeInstanceOf(Error);
    expect((shutdownError as Error).message).toBe("ordinary command failed");
    expect(counters.shutdowns).toBe(1);
    expect(app.appState).toBe("shutting_down");
  });

  test("workspace file index is bridge-delegated, Agent-free, and shutdown-gated", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const base = bridgeFor({ providers: [], oauthProviders: [] }, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        listWorkspaceFiles: async () => JSON.stringify(["src/", "src/agent.mbt", 7]),
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    // Needs-setup state: no Agent exists, the index still answers.
    expect(counters.created).toBe(0);
    expect(await app.listWorkspaceFiles()).toEqual(["src/", "src/agent.mbt"]);
    await app.shutdown();
    await expect(app.listWorkspaceFiles()).rejects.toThrow("after shutdown");
  });

  test("workspace file index degrades to empty without bridge support", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: bridgeFor({ providers: [], oauthProviders: [] }, counters),
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    expect(await app.listWorkspaceFiles()).toEqual([]);
  });

  test("workspace file index rejects a malformed bridge payload", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const base = bridgeFor({ providers: [], oauthProviders: [] }, counters);
    const app = new CetasApplication({
      bridge: { ...base, listWorkspaceFiles: async () => "{\"files\":[]}" },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await expect(app.listWorkspaceFiles()).rejects.toThrow("must be a JSON array");
  });
});
