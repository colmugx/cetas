// Baseline repro for the secondary_failure observer event on first turn and
// the /memory status "unreachable" outcome. Non-interactive: the model call
// may fail (network) — secondary_failure fires before the model call — the
// script still proceeds to /memory status so both symptoms are captured.
//
// Usage:
//   bun repro-secondary.ts

import { CetasApplication } from "./src/app/application.ts";
import { buildCetasHostConfig } from "./src/app/host-config.ts";
import { MoonbitCetasAgentBridge } from "./src/app/moonbit-bridge.ts";
import { newSessionId } from "./src/app/session-id.ts";

const observerCallback = (eventJson: string): void => {
  const ev: unknown = JSON.parse(eventJson);
  if (
    typeof ev === "object" &&
    ev !== null &&
    (ev as { type?: unknown }).type === "custom"
  ) {
    console.log(`[custom] ${eventJson}`);
  }
};

const renderCallback = (_eventJson: string): void => {};

const requestCallback = (_eventJson: string): Promise<string> => {
  throw new Error("interactive UI requests are unsupported in repro mode");
};

async function main(): Promise<number> {
  const config = buildCetasHostConfig();
  const sessionId = newSessionId();
  console.log(`[repro] cwd=${config.cwd}`);
  console.log(`[repro] sessionsDir=${config.sessionsDir}`);
  console.log(`[repro] sessionId=${sessionId}`);

  const app = new CetasApplication({
    bridge: new MoonbitCetasAgentBridge(config),
    config,
    callbacks: {
      observerCallback,
      renderCallback,
      requestCallback,
    },
    initialSessionId: sessionId,
  });

  const setup = await app.start();
  console.log(`[repro] state=${setup.state}`);
  if (setup.state === "needs_setup") {
    console.log(
      "[repro] provider setup required; configure ~/.cetas/settings.json " +
        "or use /login [provider] [method] in the interactive host",
    );
    await app.shutdown();
    return 2;
  }

  try {
    console.log("[repro] turn 1: Reply with exactly: ok");
    const reply = await app.runTurn("Reply with exactly: ok");
    console.log("--- reply 1 ---");
    console.log(reply);
  } catch (e: unknown) {
    console.error("--- turn error (continuing) ---");
    console.error(e instanceof Error ? e.message : String(e));
  }

  try {
    const outcome = await app.invokeCommand(
      "memory",
      JSON.stringify({ action: "status" }),
    );
    console.log("--- /memory status ---");
    console.log(outcome);
  } catch (e: unknown) {
    console.error("--- /memory status error ---");
    console.error(e instanceof Error ? e.message : String(e));
  }

  await app.shutdown();
  return 0;
}

try {
  const code = await main();
  process.exit(code);
} catch (e: unknown) {
  console.error("[repro] unexpected error", e);
  process.exit(1);
}
