import { afterEach, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

const {
  CetasJsConfig,
  CetasJsRuntime,
  cetas_js_runtime_create_agent,
  cetas_js_set_active_session,
  cetas_js_invoke_command,
  cetas_js_list_commands,
  cetas_js_shutdown,
} = await import("mbt:colmugx/cetas-js/lib");

const cleanup: string[] = [];
afterEach(async () => {
  for (const path of cleanup.splice(0)) {
    await rm(path, { recursive: true, force: true });
  }
});

test("Profiles /profiles research activates through the actual JS Agent and discloses its manual", async () => {
  const cwd = await mkdtemp(join(tmpdir(), "cetas-profiles-workspace-"));
  const home = await mkdtemp(join(tmpdir(), "cetas-profiles-home-"));
  cleanup.push(cwd, home);
  await mkdir(join(home, ".cetas/profiles"), { recursive: true });
  await Bun.write(join(home, ".cetas/settings.json"), JSON.stringify({
    providers: {
      deepseek: {
        api_key: "test-key",
        base_url: "http://cetas-profiles.test/v1",
        model: "scripted-model",
      },
    },
  }));
  await Bun.write(join(home, ".cetas/profiles/research.json"), JSON.stringify({
    id: "research",
    name: "Research",
    description: "Research requiring web sources",
    exts: ["posoco_ext_webfetch"],
  }));

  const requests: Array<Record<string, unknown>> = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (input, init) => {
    if (!String(input).startsWith("http://cetas-profiles.test")) {
      return new Response("service unavailable", { status: 503 });
    }
    if (init?.body == null) throw new Error("model request body missing");
    const bytes = new TextDecoder().decode(init.body as Uint8Array);
    requests.push(JSON.parse(bytes) as Record<string, unknown>);
    return new Response(
      [
        `data: ${JSON.stringify({ choices: [{ delta: { content: "profile applied" } }] })}`,
        `data: ${JSON.stringify({ choices: [{ finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}`,
        "",
      ].join("\n\n"),
      { headers: { "content-type": "text/event-stream" } },
    );
  }) as typeof fetch;
  try {
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
      async () => { throw new Error("the direct command must not request UI"); },
      () => false,
    );
    try {
      const commands = JSON.parse(cetas_js_list_commands(agent)) as Array<{ id: string }>;
      expect(commands.some((item) => item.id === "profiles")).toBe(true);
      cetas_js_set_active_session(agent, "profiles-e2e-session");
      const outcome = JSON.parse(await cetas_js_invoke_command(
        agent,
        "profiles",
        JSON.stringify({ profile: "research" }),
      )) as { type: string; feedback?: string; reason?: string };
      expect(outcome.type).toBe("success");
      expect(outcome.feedback).toContain("activated profile: research");
      expect(requests).toHaveLength(1);
      const modelMessages = JSON.stringify(requests[0]?.messages);
      expect(modelMessages).toContain("profile research activated");
      expect(modelMessages).toContain("webfetch");
    } finally {
      await cetas_js_shutdown(agent);
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});
