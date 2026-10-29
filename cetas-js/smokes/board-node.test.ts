// e2e: the npm channel runs this host under plain Node, where there is no
// `Bun` global. Opening the Board there must serve the dashboard and accept a
// Board WebSocket — `Bun is not defined` was the failure this guards.
import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

test(
  "the Board transport serves a dashboard under plain Node",
  () => {
    const run = spawnSync(
      process.env.CETAS_NODE_BIN ?? "node",
      [join("smokes", "fixtures", "board-node-harness.mjs")],
      { cwd: join(import.meta.dir, ".."), encoding: "utf8", timeout: 120_000 },
    );
    expect(run.status, `${run.stdout}\n${run.stderr}`).toBe(0);
    expect(run.stdout).toContain("board-node ok");
  },
  180_000,
);
