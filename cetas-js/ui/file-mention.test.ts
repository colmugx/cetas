import { describe, expect, test } from "bun:test";
import { rankFileMentionItems, toolDisplayLabel } from "./terminal-shell.ts";

describe("rankFileMentionItems", () => {
  test("ranks basename exact over prefix over contains over path contains", () => {
    const entries = [
      "src/lib/agent.d.ts",
      "agent.mbt",
      "agent_utils.mbt",
      "docs/agent-guide.md",
      "README.md",
    ];
    expect(rankFileMentionItems(entries, "agent")).toEqual([
      "agent.mbt",
      "agent_utils.mbt",
      "docs/agent-guide.md",
      "src/lib/agent.d.ts",
    ]);
  });

  test("drops entries that do not match the query", () => {
    expect(rankFileMentionItems(["src/agent.mbt", "lib/core.mbt"], "agent")).toEqual([
      "src/agent.mbt",
    ]);
  });

  test("ranks directories above files on equal scores", () => {
    const entries = ["agent.mbt", "agent/"];
    expect(rankFileMentionItems(entries, "agent")).toEqual(["agent/", "agent.mbt"]);
  });

  test("empty query prefers directories and shallower paths", () => {
    const entries = ["deep/nest/ed/file.mbt", "src/", "top.mbt", "a/b/c.mbt"];
    expect(rankFileMentionItems(entries, "")).toEqual(["src/", "top.mbt", "a/b/c.mbt", "deep/nest/ed/file.mbt"]);
  });

  test("caps the result list", () => {
    const entries = Array.from({ length: 80 }, (_, i) => `f${i}.mbt`);
    expect(rankFileMentionItems(entries, "f").length).toBe(50);
  });
});

describe("toolDisplayLabel", () => {
  test("tools missing from the catalog keep the bare name", () => {
    expect(toolDisplayLabel(undefined, "read")).toBe("read");
  });

  test("extension display name equal to the tool name collapses to the bare name", () => {
    expect(toolDisplayLabel("posoco_ext_read", "read")).toBe("read");
    expect(toolDisplayLabel("posoco_ext_bash", "bash")).toBe("bash");
  });

  test("differing extension display name prefixes the tool name", () => {
    expect(toolDisplayLabel("posoco_ext_nowledge_mem", "memory_search")).toBe(
      "nowledge-mem:memory_search",
    );
    expect(toolDisplayLabel("custom_ext", "grep")).toBe("custom_ext:grep");
  });
});
