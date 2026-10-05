import { describe, expect, test } from "bun:test";
import { CetasApplication, CetasApplicationError } from "./index.ts";
import type {
  AgentCallbacks,
  AppSnapshot,
  CetasAgentBridge,
  CetasHostConfig,
  CancellationToken,
  CommandDescriptor,
  ProviderSetupSnapshot,
} from "./index.ts";
import type { CatalogRefreshSummary } from "./types.ts";

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

function bridgeFor(
  setup: ProviderSetupSnapshot,
  counters: { created: number; runs: number; shutdowns: number },
): CetasAgentBridge<{ id: string }> {  return {
    describeSetup: async () => setup,
    createAgent: async () => {
      counters.created += 1;
      return { id: "agent" };
    },
    runTurn: async () => {
      counters.runs += 1;
      return "reply";
    },
    cancelPendingRateLimit: () => undefined,
    shutdown: async () => {
      counters.shutdowns += 1;
    },
    listCommands: () => [command("model"), command("login")],
    invokeCommand: async (_agent, id) => JSON.stringify({ type: "success", id }),
    rewind: async () => undefined,
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

  test("composes startup from local catalogs and refreshes only the logged-in provider", async () => {
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

    // Compose-first startup: discovery reads the local catalogs; the network
    // refresh moved to the bridge's live-refresh background task.
    await app.start();
    expect(refreshes).toEqual([]);
    await app.invokeCommand("model", "{}");
    expect(refreshes).toEqual([]);
    const login = await app.invokeCommand(
      "login",
      JSON.stringify({ provider: "kimi", method: "oauth" }),
    );
    expect(login).toContain("logged in");
    expect(refreshes).toEqual([["kimi"]]);
    await app.shutdown();
  });

  test("start composes from local catalogs and launches the live refresh exactly once", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const setup: ProviderSetupSnapshot = {
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
    let catalogRefreshes = 0;
    const liveSelectors: string[] = [];
    let releaseLive!: (raw: string) => void;
    const liveReleased = new Promise<string>((resolve) => {
      releaseLive = resolve;
    });
    const summaries: CatalogRefreshSummary[] = [];
    const base = bridgeFor(setup, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        refreshModelCatalogs: async () => {
          catalogRefreshes += 1;
          return setup;
        },
        refreshModelListsLive: async (_config, providerIdsJson) => {
          liveSelectors.push(providerIdsJson);
          return liveReleased;
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
      onCatalogRefresh: (summary) => {
        summaries.push(summary);
      },
    });

    expect((await app.start()).state).toBe("ready");
    // Let the settle-hook microtasks launch the background task.
    await Bun.sleep(1);
    // Compose-first: startup never invoked the network catalog refresh.
    expect(catalogRefreshes).toBe(0);
    // The configured provider ids from the settled snapshot are the selector.
    expect(liveSelectors).toEqual(['["deepseek"]']);
    // A repeated start() is idempotent and never relaunches the task.
    expect((await app.start()).state).toBe("ready");
    await Bun.sleep(1);
    expect(liveSelectors).toEqual(['["deepseek"]']);
    // The summary rides the bridge string and reaches the callback parsed.
    releaseLive(
      JSON.stringify({
        results: [{ provider: "deepseek", status: "refreshed", slots: 42 }],
      }),
    );
    await Bun.sleep(1);
    expect(summaries).toEqual([
      { results: [{ provider: "deepseek", status: "refreshed", slots: 42 }] },
    ]);
    await app.shutdown();
  });

  test("a zero-configured snapshot never launches the live refresh", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const liveSelectors: string[] = [];
    const app = new CetasApplication({
      bridge: {
        ...bridgeFor({ providers: [], oauthProviders: [] }, counters),
        refreshModelListsLive: async (_config, providerIdsJson) => {
          liveSelectors.push(providerIdsJson);
          return JSON.stringify({ results: [] });
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    expect((await app.start()).state).toBe("needs_setup");
    await Bun.sleep(1);
    expect(liveSelectors).toEqual([]);
    // A retried start() on the same empty snapshot stays unlaunched.
    expect((await app.start()).state).toBe("needs_setup");
    await Bun.sleep(1);
    expect(liveSelectors).toEqual([]);
    await app.shutdown();
  });

  test("a refreshed summary recomposes needs_setup once the catalog is fresh", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const setup: ProviderSetupSnapshot = {
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
    const liveSelectors: string[] = [];
    let releaseLive!: (raw: string) => void;
    const liveReleased = new Promise<string>((resolve) => {
      releaseLive = resolve;
    });
    let compositions = 0;
    const base = bridgeFor(setup, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        createAgent: async () => {
          compositions += 1;
          if (compositions === 1) throw new Error("transient composition failure");
          return { id: "agent" };
        },
        refreshModelListsLive: async (_config, providerIdsJson) => {
          liveSelectors.push(providerIdsJson);
          return liveReleased;
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    // A failed first composition leaves needs_setup while the configured
    // snapshot survives — the refreshable state the guard still launches for.
    await expect(app.start()).rejects.toBeInstanceOf(CetasApplicationError);
    expect(app.appState).toBe("needs_setup");
    expect(compositions).toBe(1);
    await Bun.sleep(1);
    expect(liveSelectors).toEqual(['["deepseek"]']);
    // The refreshed summary triggers the guarded refreshSetup recomposition.
    releaseLive(
      JSON.stringify({
        results: [{ provider: "deepseek", status: "refreshed", slots: 7 }],
      }),
    );
    await Bun.sleep(1);
    expect(app.appState).toBe("ready");
    expect(compositions).toBe(2);
    await app.shutdown();
  });

  test("an all-failed summary leaves needs_setup alone but still reports", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const summaries: CatalogRefreshSummary[] = [];
    const setup: ProviderSetupSnapshot = {
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
    const base = bridgeFor(setup, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        createAgent: async () => {
          throw new Error("composition unavailable");
        },
        refreshModelListsLive: async () =>
          JSON.stringify({
            results: [
              {
                provider: "deepseek",
                status: "failed",
                reason: "catalog endpoint unavailable",
              },
            ],
          }),
      },
      config,
      callbacks,
      initialSessionId: "session-1",
      onCatalogRefresh: (summary) => {
        summaries.push(summary);
      },
    });

    await expect(app.start()).rejects.toBeInstanceOf(CetasApplicationError);
    await Bun.sleep(1);
    // No refreshed entry: needs_setup is left alone, nothing recomposes, and
    // the configured snapshot survives the all-failed summary.
    expect(app.appState).toBe("needs_setup");
    expect(app.snapshot().setup.providers).toHaveLength(1);
    expect(summaries).toEqual([
      {
        results: [
          {
            provider: "deepseek",
            status: "failed",
            reason: "catalog endpoint unavailable",
          },
        ],
      },
    ]);
    await app.shutdown();
  });

  test("a mid-turn refreshed summary is surfaced but skips recomposition", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let discoveries = 0;
    let markTurnStarted!: () => void;
    let releaseTurn!: () => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    const turnReleased = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    const setup: ProviderSetupSnapshot = {
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
    const summaries: CatalogRefreshSummary[] = [];
    const base = bridgeFor(setup, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        describeSetup: async () => {
          discoveries += 1;
          return setup;
        },
        runTurn: async () => {
          markTurnStarted();
          await turnReleased;
          return "reply";
        },
        refreshModelListsLive: async () =>
          JSON.stringify({
            results: [{ provider: "deepseek", status: "refreshed", slots: 8 }],
          }),
      },
      config,
      callbacks,
      initialSessionId: "session-1",
      onCatalogRefresh: (summary) => {
        summaries.push(summary);
      },
    });

    await app.start();
    expect(discoveries).toBe(1);
    const turn = app.runTurn("hello");
    await turnStarted;
    await Bun.sleep(1);
    // The summary still reaches the host; the busy guards keep the idle-only
    // recomposition out of the running turn.
    expect(summaries).toHaveLength(1);
    expect(discoveries).toBe(1);
    expect(counters.created).toBe(1);
    releaseTurn();
    await expect(turn).resolves.toBe("reply");
    await app.shutdown();
  });

  test("shutdown cancels the live refresh and awaits its settle barrier", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let releaseLive!: (raw: string) => void;
    const liveReleased = new Promise<string>((resolve) => {
      releaseLive = resolve;
    });
    const summaries: CatalogRefreshSummary[] = [];
    const app = new CetasApplication({
      bridge: {
        ...bridgeFor(
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
        ),
        refreshModelListsLive: async () => liveReleased,
      },
      config,
      callbacks,
      initialSessionId: "session-1",
      onCatalogRefresh: (summary) => {
        summaries.push(summary);
      },
    });

    await app.start();
    await Bun.sleep(1);
    let shutdownSettled = false;
    const shutdown = app.shutdown().then(() => {
      shutdownSettled = true;
    });
    await Bun.sleep(1);
    // The live refresh is a shutdown serialization barrier: still pending.
    expect(shutdownSettled).toBe(false);
    // A late summary after cancellation is discarded, never dispatched.
    releaseLive(
      JSON.stringify({
        results: [{ provider: "deepseek", status: "refreshed", slots: 9 }],
      }),
    );
    await shutdown;
    expect(summaries).toEqual([]);
    expect(app.appState).toBe("shutting_down");
  });

  test("a rejecting live refresh surfaces an error and never rejects shutdown", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: {
        ...bridgeFor(
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
        ),
        refreshModelListsLive: async () => {
          throw new Error("ffi defect");
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    await Bun.sleep(1);
    expect(app.snapshot().error).toBe("live model catalog refresh failed: ffi defect");
    await expect(app.shutdown()).resolves.toBeUndefined();
  });

  test("a malformed live-refresh summary surfaces an error instead of crashing", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: {
        ...bridgeFor(
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
        ),
        refreshModelListsLive: async () => "{\"results\":[{\"provider\":\"deepseek\"}]}",
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    await Bun.sleep(1);
    expect(app.snapshot().error).toContain("invalid summary");
    // The app stays composed and usable after the bridge defect.
    expect(app.appState).toBe("ready");
    await app.shutdown();
  });

  test("invokes the live catalog refresh with the bridge instance as receiver", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
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
    class ClassBridge implements CetasAgentBridge<{ id: string }> {
      refreshes = 0;
      describeSetup = base.describeSetup;
      createAgent = base.createAgent;
      runTurn = base.runTurn;
      cancelPendingRateLimit = base.cancelPendingRateLimit;
      shutdown = base.shutdown;
      listCommands = base.listCommands;
      invokeCommand = base.invokeCommand;
      rewind = base.rewind;
      refreshModelListsLive(
        _config: CetasHostConfig,
        _providerIdsJson: string,
      ): Promise<string> {
        // Call through the bridge object so method receiver binding is
        // preserved.
        this.refreshes += 1;
        return Promise.resolve(JSON.stringify({ results: [] }));
      }
    }
    const bridge = new ClassBridge();
    const app = new CetasApplication({
      bridge,
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    expect((await app.start()).state).toBe("ready");
    await Bun.sleep(1);
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
    // Graceful-first: the mailbox abort is the primary interrupt and the
    // hard signal only follows after the watchdog window when the turn has
    // not settled.
    expect(seenSignal!.aborted).toBe(false);
    await Bun.sleep(1700);
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

  test("rejects malformed /login arguments with a typed invalid_state error", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const base = bridgeFor({ providers: [], oauthProviders: [] }, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        login: async () => JSON.stringify({ type: "success" }),
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    const error: unknown = await app.invokeCommand("login", "not json").then(
      () => undefined,
      (caught: unknown) => caught,
    );
    expect(error).toBeInstanceOf(CetasApplicationError);
    expect((error as CetasApplicationError).code).toBe("invalid_state");
  });

  test("rejects a malformed login outcome as a typed bridge_failure error", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const base = bridgeFor({ providers: [], oauthProviders: [] }, counters);
    const app = new CetasApplication({
      bridge: {
        ...base,
        login: async () => "not json",
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    await expect(
      app.invokeCommand("login", JSON.stringify({ provider: "kimi" })),
    ).rejects.toMatchObject({ code: "bridge_failure" });
  });

  test("rejects a malformed command outcome as a typed bridge_failure error", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
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
        invokeCommand: async () => "not json",
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    await expect(app.invokeCommand("model")).rejects.toMatchObject({
      code: "bridge_failure",
    });
  });

  test("adoptSessionRedirect updates the session id while a turn is active", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markTurnStarted!: () => void;
    let releaseTurn!: () => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    const turnReleased = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    let lastSnapshot: AppSnapshot | undefined;
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
      onStateChange: (snapshot) => {
        lastSnapshot = snapshot;
      },
    });

    await app.start();
    const turn = app.runTurn("hello");
    await turnStarted;
    // A redirect is an observed runtime fact: it adopts mid-turn where
    // setSession would reject with already_running.
    app.adoptSessionRedirect("s_new");
    expect(app.sessionId).toBe("s_new");
    expect(lastSnapshot?.sessionId).toBe("s_new");
    releaseTurn();
    await expect(turn).resolves.toBe("reply");
  });

  test("adoptSessionRedirect rejects an empty target", () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: bridgeFor({ providers: [], oauthProviders: [] }, counters),
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    let caught: unknown;
    try {
      app.adoptSessionRedirect("");
    } catch (error: unknown) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(CetasApplicationError);
    expect((caught as CetasApplicationError).code).toBe("invalid_state");
  });

  test("adoptSessionRedirect rejects after shutdown has begun", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: bridgeFor({ providers: [], oauthProviders: [] }, counters),
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();
    await app.shutdown();
    let caught: unknown;
    try {
      app.adoptSessionRedirect("s_new");
    } catch (error: unknown) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(CetasApplicationError);
    expect((caught as CetasApplicationError).code).toBe("shutting_down");
  });

  test("rewind passes through when idle and is rejected while a turn runs", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markTurnStarted!: () => void;
    let releaseTurn!: () => void;
    const turnStarted = new Promise<void>((resolve) => {
      markTurnStarted = resolve;
    });
    const turnReleased = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    const rewound: Array<{ agent: unknown; sessionId: string; fromIndex: number }> = [];
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
        rewind: async (agent, sessionId, fromIndex) => {
          rewound.push({ agent, sessionId, fromIndex });
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    await app.rewind("session-1", 2);
    expect(rewound).toEqual([{ agent: { id: "agent" }, sessionId: "session-1", fromIndex: 2 }]);

    const turn = app.runTurn("hello");
    await turnStarted;
    await expect(app.rewind("session-1", 1)).rejects.toMatchObject({
      code: "already_running",
    });
    expect(rewound).toHaveLength(1);
    releaseTurn();
    await expect(turn).resolves.toBe("reply");
    // Idle again once the turn settles.
    await app.rewind("session-1", 0);
    expect(rewound).toHaveLength(2);
  });

  test("submitUserInput waits through a stale lower-layer lease before starting the fresh turn", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let releaseFirst!: () => void;
    let markFirstStarted!: () => void;
    const firstReleased = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    const firstStarted = new Promise<void>((resolve) => {
      markFirstStarted = resolve;
    });
    const prompts: string[] = [];
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
        runTurn: async (_agent, prompt) => {
          prompts.push(prompt);
          if (prompt === "first") {
            markFirstStarted();
            await firstReleased;
          }
          return `reply:${prompt}`;
        },
        enqueueFollowUp: () => "RejectedStale(reason=run_closed)",
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const first = app.runTurn("first");
    await firstStarted;

    let submissionSettled = false;
    const submissionPromise = app.submitUserInput("second").then((value) => {
      submissionSettled = true;
      return value;
    });
    await Bun.sleep(1);
    expect(submissionSettled).toBe(false);
    expect(prompts).toEqual(["first"]);

    releaseFirst();
    await expect(first).resolves.toBe("reply:first");
    const submission = await submissionPromise;
    expect(submission.kind).toBe("started");
    if (submission.kind !== "started") throw new Error("expected fresh turn");
    await expect(submission.completion).resolves.toBe("reply:second");
    expect(prompts).toEqual(["first", "second"]);
    expect(app.appState).toBe("ready");
  });

  test("shutdown cancels the active Agent operation before draining and then closes the Agent", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markStarted!: () => void;
    let releaseRun!: () => void;
    const started = new Promise<void>((resolve) => {
      markStarted = resolve;
    });
    const released = new Promise<void>((resolve) => {
      releaseRun = resolve;
    });
    let aborts = 0;
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
          markStarted();
          await released;
          return "partial";
        },
        abortTurn: () => {
          aborts += 1;
          releaseRun();
          return "Accepted(operation=turn)";
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const turn = app.runTurn("hello");
    await started;
    await app.shutdown();
    await expect(turn).resolves.toBe("partial");
    expect(aborts).toBe(1);
    expect(counters.shutdowns).toBe(1);
    expect(app.appState).toBe("shutting_down");
  });

  test("repeated interrupts do not resend abort or postpone cancellation", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let markStarted!: () => void;
    let releaseRun!: () => void;
    const started = new Promise<void>((resolve) => {
      markStarted = resolve;
    });
    const released = new Promise<void>((resolve) => {
      releaseRun = resolve;
    });
    let aborts = 0;
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
          markStarted();
          await released;
          return "partial";
        },
        abortTurn: () => {
          aborts += 1;
          return "Accepted(operation=turn)";
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
    });

    await app.start();
    const turn = app.runTurn("hello");
    await started;
    expect(app.interruptActiveTurn()).toBe(true);
    expect(app.interruptActiveTurn()).toBe(true);
    expect(aborts).toBe(1);
    expect(app.operationSnapshot.phase).toBe("cancelling");

    releaseRun();
    await expect(turn).resolves.toBe("partial");
    expect(app.operationSnapshot.phase).toBe("idle");
  });

  test("shutdown stays bounded when the Agent shutdown never settles", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    const app = new CetasApplication({
      bridge: {
        ...bridgeFor(agentComposingSetup(), counters),
        shutdown: () => new Promise<void>(() => {}),
      },
      config,
      callbacks,
      initialSessionId: "session-1",
      shutdownSettleTimeoutMs: 40,
    });
    await app.start();
    expect(counters.created).toBe(1);
    await expect(app.shutdown()).rejects.toThrow(/agent shutdown/);
  });

  test("shutdown aborts and bounds a stalled live catalog refresh", async () => {
    const counters = { created: 0, runs: 0, shutdowns: 0 };
    let refreshSignal: AbortSignal | undefined;
    const app = new CetasApplication({
      bridge: {
        ...bridgeFor(agentComposingSetup(), counters),
        refreshModelListsLive: (_config, _providerIdsJson, signal?: AbortSignal) => {
          refreshSignal = signal;
          // A refresh whose network work ignores the abort entirely.
          return new Promise<string>(() => {});
        },
      },
      config,
      callbacks,
      initialSessionId: "session-1",
      shutdownSettleTimeoutMs: 40,
    });
    await app.start();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(refreshSignal).toBeInstanceOf(AbortSignal);
    await expect(app.shutdown()).rejects.toThrow(/live model catalog refresh/);
    expect(refreshSignal?.aborted).toBe(true);
    expect(counters.shutdowns).toBe(1);
  });

});

describe("resumeTurn", () => {
  function resumeBridge(
    counters: { resumes: number },
    setup: ProviderSetupSnapshot,
  ): CetasAgentBridge<{ id: string }> {
    return {
      ...bridgeFor(setup, { created: 0, runs: 0, shutdowns: 0 }),
      resumeTurn: async () => {
        counters.resumes += 1;
        return "resumed";
      },
    };
  }

  const readySetup: ProviderSetupSnapshot = {
    providers: [
      {
        id: "openai/gpt",
        label: "GPT",
        provider: "openai",
        model: "gpt",
        active: true,
        efforts: [],
        oauth: false,
      },
    ],
    oauthProviders: [],
    activeModelId: "openai/gpt",
  };

  test("resumes through the bridge with a turn lease", async () => {
    const counters = { resumes: 0 };
    const app = new CetasApplication({
      bridge: resumeBridge(counters, readySetup),
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();
    expect(await app.resumeTurn()).toBe("resumed");
    expect(counters.resumes).toBe(1);
    await app.shutdown();
  });

  test("rejects with a typed error when the bridge omits resumeTurn", async () => {
    const app = new CetasApplication({
      bridge: bridgeFor(readySetup, { created: 0, runs: 0, shutdowns: 0 }),
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();
    await expect(app.resumeTurn()).rejects.toThrow("does not expose turn resume");
    await app.shutdown();
  });

  test("stays idle-only: a running operation rejects resume", async () => {
    let releaseTurn: (() => void) | undefined;
    const counters = { resumes: 0 };
    const bridge = resumeBridge(counters, readySetup);
    const originalRun = bridge.runTurn.bind(bridge);
    bridge.runTurn = async () =>
      new Promise((resolve) => {
        releaseTurn = () => resolve("reply");
      });
    const app = new CetasApplication({
      bridge,
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();
    const pending = originalRun !== undefined ? app.runTurn("hello") : undefined;
    await expect(app.resumeTurn()).rejects.toBeInstanceOf(CetasApplicationError);
    releaseTurn?.();
    await pending;
    await app.shutdown();
  });
});

/**
 * Core operation projection (frozen `posoco.operation` customs). These
 * tests use the NEW protocol: the bridge's observer callback emits
 * operation_started/operation_settled and the application must treat them
 * as the authoritative busy truth.
 */
describe("core operation projection", () => {
  function operationEvent(
    label: "operation_started" | "operation_settled",
    data: Record<string, unknown>,
  ): string {
    return JSON.stringify({
      type: "custom",
      source: "posoco.operation",
      label,
      data,
    });
  }

  /** Bridge whose created Agent exposes its observer callback to the test. */
  function observableBridge(overrides: Partial<CetasAgentBridge<{ id: string }>> = {}): {
    bridge: CetasAgentBridge<{ id: string }>;
    observer: () => (eventJson: string) => void;
    followUps: string[];
  } {
    let live: AgentCallbacks | undefined;
    const followUps: string[] = [];
    const bridge: CetasAgentBridge<{ id: string }> = {
      ...bridgeFor(agentComposingSetup(), { created: 0, runs: 0, shutdowns: 0 }),
      createAgent: async (_config, agentCallbacks) => {
        live = agentCallbacks;
        return { id: "agent" };
      },
      abortTurn: () => "Accepted(operation=turn)",
      enqueueFollowUp: (_agent, prompt) => {
        followUps.push(prompt);
        return "Accepted(run_id=w1)";
      },
      ...overrides,
    };
    return {
      bridge,
      observer: () => {
        if (live === undefined) throw new Error("Agent was not created");
        return live.observerCallback;
      },
      followUps,
    };
  }

  test("a core wakeup operation projects busy without the recovery guess and settles only at operation_settled", async () => {
    const fixture = observableBridge();
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();

    fixture.observer()(
      operationEvent("operation_started", {
        operation_id: "agent_wakeup_w1",
        session: "session-1",
        origin: "wakeup",
      }),
    );
    expect(app.appState).toBe("running");
    expect(app.operationSnapshot).toMatchObject({ busy: true, kind: "wakeup" });

    // Same-session input during the wakeup run is a legitimate follow-up.
    const submission = await app.submitUserInput("check the build", "session-1");
    expect(submission.kind).toBe("queued");
    expect(fixture.followUps).toEqual(["check the build"]);

    // An intermediate TurnCompleted must not unlock the operation.
    fixture.observer()(JSON.stringify({ type: "turn_completed" }));
    expect(app.appState).toBe("running");
    expect(app.operationSnapshot.busy).toBe(true);

    fixture.observer()(
      operationEvent("operation_settled", {
        operation_id: "agent_wakeup_w1",
        session: "session-1",
        origin: "wakeup",
        outcome: "completed",
      }),
    );
    expect(app.appState).toBe("ready");
    expect(app.operationSnapshot.busy).toBe(false);
    await app.shutdown();
  });

  test("an operation on another session keeps the agent busy without enqueueing cross-session input", async () => {
    const fixture = observableBridge();
    let releaseRun!: () => void;
    const released = new Promise<void>((resolve) => {
      releaseRun = resolve;
    });
    fixture.bridge.runTurn = async (_agent, prompt) => {
      await released;
      return `reply:${prompt}`;
    };
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();

    fixture.observer()(
      operationEvent("operation_started", {
        operation_id: "agent_wakeup_w9",
        session: "session-9",
        origin: "wakeup",
      }),
    );
    expect(app.appState).toBe("running");

    let settled = false;
    const submission = app.submitUserInput("mine", "session-1").then((value) => {
      settled = true;
      return value;
    });
    await Bun.sleep(1);
    expect(settled).toBe(false);
    expect(fixture.followUps).toEqual([]);

    fixture.observer()(
      operationEvent("operation_settled", {
        operation_id: "agent_wakeup_w9",
        session: "session-9",
        origin: "wakeup",
        outcome: "cancelled",
      }),
    );
    const started = await submission;
    expect(started.kind).toBe("started");
    if (started.kind !== "started") throw new Error("expected a fresh turn");
    releaseRun();
    await expect(started.completion).resolves.toBe("reply:mine");
    expect(fixture.followUps).toEqual([]);
    await app.shutdown();
  });

  test("after operation events the idle turn_started recovery guess is retired", async () => {
    const fixture = observableBridge();
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();

    // One full core operation cycle teaches the app the new protocol.
    fixture.observer()(
      operationEvent("operation_started", {
        operation_id: "agent_wakeup_w1",
        session: "session-1",
        origin: "wakeup",
      }),
    );
    fixture.observer()(
      operationEvent("operation_settled", {
        operation_id: "agent_wakeup_w1",
        session: "session-1",
        origin: "wakeup",
        outcome: "completed",
      }),
    );
    expect(app.appState).toBe("ready");

    // A bare autonomous turn event is no longer guessed as recovery.
    fixture.observer()(JSON.stringify({ type: "turn_started" }));
    expect(app.appState).toBe("ready");
    expect(app.operationSnapshot.busy).toBe(false);
    await app.shutdown();
  });

  test("a host-hosted turn associates its core operation and a late settled is a no-op", async () => {
    const fixture = observableBridge();
    let releaseRun!: () => void;
    const released = new Promise<void>((resolve) => {
      releaseRun = resolve;
    });
    fixture.bridge.runTurn = async () => {
      await released;
      return "reply";
    };
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();

    const turn = app.runTurn("hello", "session-1");
    await Bun.sleep(1);
    const leaseId = app.operationSnapshot.id;
    fixture.observer()(
      operationEvent("operation_started", {
        operation_id: "agent_run_turn_1",
        session: "session-1",
        origin: "turn",
      }),
    );
    // The core operation joins the existing host lease — no second owner.
    expect(app.operationSnapshot.id).toBe(leaseId);
    expect(app.operationSnapshot).toMatchObject({ busy: true, kind: "turn" });

    releaseRun();
    await expect(turn).resolves.toBe("reply");
    expect(app.appState).toBe("ready");

    // The core settles after the host's own finalize; no double release.
    fixture.observer()(
      operationEvent("operation_settled", {
        operation_id: "agent_run_turn_1",
        session: "session-1",
        origin: "turn",
        outcome: "completed",
      }),
    );
    expect(app.appState).toBe("ready");
    expect(app.operationSnapshot.busy).toBe(false);
    await app.shutdown();
  });

  test("the compact reservation never masks a real core operation", async () => {
    const fixture = observableBridge();
    // The compact never reaches the bridge in this scenario; a hanging
    // bridge keeps the test honest if the race outcome ever changes.
    (fixture.bridge as unknown as Record<string, unknown>).compactSession = () =>
      new Promise<string>(() => {});
    const app = new CetasApplication({
      bridge: fixture.bridge,
      config,
      callbacks,
      initialSessionId: "session-1",
    });
    await app.start();

    // A running wakeup turn, then the /compact switch interrupts it.
    fixture.observer()(
      operationEvent("operation_started", {
        operation_id: "agent_wakeup_w1",
        session: "session-1",
        origin: "wakeup",
      }),
    );
    const compactPromise = app.compactSession("session-1");
    await Bun.sleep(1);
    expect(app.operationSnapshot.phase).toBe("cancelling");

    // The interrupted wakeup settles; the compact owns the reservation.
    fixture.observer()(
      operationEvent("operation_settled", {
        operation_id: "agent_wakeup_w1",
        session: "session-1",
        origin: "wakeup",
        outcome: "cancelled",
      }),
    );
    // Synchronously — before the compact's finalize continuation can claim
    // its lease — the core admits the next wakeup inside the reservation
    // window. The projection must not hide it behind an idle snapshot, and
    // the compact loses the race with the already-admitted core operation.
    fixture.observer()(
      operationEvent("operation_started", {
        operation_id: "agent_wakeup_w2",
        session: "session-1",
        origin: "wakeup",
      }),
    );
    expect(app.operationSnapshot).toMatchObject({ busy: true, kind: "wakeup" });
    await expect(compactPromise).rejects.toThrow(
      "another Agent operation is already running",
    );
    expect(app.operationSnapshot).toMatchObject({ busy: true, kind: "wakeup" });

    fixture.observer()(
      operationEvent("operation_settled", {
        operation_id: "agent_wakeup_w2",
        session: "session-1",
        origin: "wakeup",
        outcome: "completed",
      }),
    );
    expect(app.appState).toBe("ready");
    await app.shutdown();
  });
});
