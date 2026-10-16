import { describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CetasApplication } from "./application.ts";
import type { CetasAgentBridge, ProviderSetupSnapshot, AgentCallbacks } from "./types.ts";

const callbacks: AgentCallbacks = {
  observerCallback: () => undefined,
  renderCallback: () => undefined,
  requestCallback: async () => "",
};

const available: ProviderSetupSnapshot = {
  providers: [{ id: "test", label: "Test", provider: "test", model: "test", active: true, efforts: [], oauth: false }],
  oauthProviders: [],
  activeModelId: "test",
};

async function harness(failOnMagpie = false) {
  const home = await mkdtemp(join(tmpdir(), "cetas-manager-switch-"));
  await mkdir(join(home, ".cetas"));
  const path = join(home, ".cetas", "settings.json");
  await writeFile(path, '{"model_manager":"providers","model":"ordinary/model"}\n');
  const created: string[] = [];
  const stopped: string[] = [];
  const bridge: CetasAgentBridge<{ manager: string }> = {
    describeSetup: async () => available,
    createAgent: async () => {
      const manager = JSON.parse(await readFile(path, "utf8")).model_manager;
      if (failOnMagpie && manager === "magpie") throw new Error("magpie unavailable");
      created.push(manager);
      return { manager };
    },
    runTurn: async (agent) => agent.manager,
    cancelPendingRateLimit: () => undefined,
    shutdown: async (agent) => { stopped.push(agent.manager); },
    listCommands: () => [],
    invokeCommand: async () => '{"type":"success"}',
    rewind: async () => undefined,
  };
  const app = new CetasApplication({
    bridge,
    config: { home, cwd: home, maxToolRounds: 1 },
    initialSessionId: "session-one",
    callbacks,
  });
  await app.start();
  return { app, home, path, created, stopped };
}

describe("manager switching", () => {
  test("rejects mutations while recomposition is underway", async () => {
    const { app } = await harness();
    const pending = app.switchModelManager("magpie");
    expect(() => app.setSession("other-session")).toThrow();
    expect(() => app.adoptSessionRedirect("other-session")).toThrow();
    await expect(app.submitUserInput("hello")).rejects.toThrow();
    await expect(app.compactSession()).rejects.toThrow();
    await pending;
    expect(app.modelManager).toBe("magpie");
    await app.shutdown();
  });

  test("retired Agent callbacks cannot publish to the active renderer", async () => {
    const home = await mkdtemp(join(tmpdir(), "cetas-manager-callback-"));
    const path = join(home, ".cetas", "settings.json");
    await mkdir(join(home, ".cetas"));
    await writeFile(path, '{"model_manager":"providers"}');
    const observed: string[] = [];
    const agents: AgentCallbacks[] = [];
    const bridge: CetasAgentBridge<number> = {
      describeSetup: async () => available,
      createAgent: async (_config, callbacks) => { agents.push(callbacks); return agents.length; },
      runTurn: async () => "",
      cancelPendingRateLimit: () => undefined,
      shutdown: async () => undefined,
      listCommands: () => [],
      invokeCommand: async () => '{}',
      rewind: async () => undefined,
    };
    const app = new CetasApplication({
      bridge, config: { home, cwd: home, maxToolRounds: 1 },
      initialSessionId: "session-one",
      callbacks: { ...callbacks, renderCallback: (event) => observed.push(event) },
    });
    await app.start();
    const old = agents[0]!;
    await app.switchModelManager("magpie");
    old.renderCallback("stale");
    agents[1]!.renderCallback("current");
    expect(observed).toEqual(["current"]);
    await app.shutdown();
  });

  test("soft-recomposes the Agent while keeping the session", async () => {
    const { app, path, created, stopped } = await harness();
    expect(app.sessionId).toBe("session-one");
    await app.switchModelManager("magpie");
    expect(app.sessionId).toBe("session-one");
    expect(created).toEqual(["providers", "magpie"]);
    expect(stopped).toEqual(["providers"]);
    expect(JSON.parse(await readFile(path, "utf8")).model_manager).toBe("magpie");
    expect(await app.runTurn("hello")).toBe("magpie");
    await app.shutdown();
  });

  test("restores settings and the previous manager after failed composition", async () => {
    const { app, path, created } = await harness(true);
    await expect(app.switchModelManager("magpie")).rejects.toThrow();
    expect(JSON.parse(await readFile(path, "utf8")).model_manager).toBe("providers");
    expect(created).toEqual(["providers", "providers"]);
    expect(await app.runTurn("hello")).toBe("providers");
    await app.shutdown();
  });
});
