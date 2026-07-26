import { describe, expect, test } from "bun:test";

import { UiRegistry } from "./ui-registry.ts";

function signal(): AbortSignal {
  return new AbortController().signal;
}

describe("UiRegistry", () => {
  test("aggregates sources with the same trigger in registration order", async () => {
    const registry = new UiRegistry();
    registry.register("core", {
      component_keys: [],
      autocomplete: [{
        trigger: "/",
        kind: "command",
        fetch: (prefix) => [{
          label: `help:${prefix}`,
          detail: "core command",
          insert_text: "/help",
        }],
      }],
    });
    registry.register("workflow", {
      component_keys: ["workflow.status"],
      autocomplete: [{
        trigger: "/",
        kind: "command",
        fetch: async () => [{
          label: "workflow",
          detail: "workflow command",
          insert_text: "/workflow",
        }],
      }],
    });

    const result = await registry.getSuggestions(
      ["/he"],
      0,
      3,
      { signal: signal() },
    );
    expect(result).toEqual({
      prefix: "/he",
      items: [
        { value: "/help", label: "help:he", description: "core command" },
        { value: "/workflow", label: "workflow", description: "workflow command" },
      ],
    });
  });

  test("fails fast on component key collisions", () => {
    const registry = new UiRegistry();
    registry.register("goal", {
      component_keys: ["status"],
      autocomplete: [],
    });
    expect(() =>
      registry.register("workflow", {
        component_keys: ["status"],
        autocomplete: [],
      })
    ).toThrow("UI component key collision");
  });

  test("applies the selected completion at the active prefix", () => {
    const registry = new UiRegistry();
    expect(
      registry.applyCompletion(
        ["run /he now"],
        0,
        7,
        { value: "/help", label: "help" },
        "/he",
      ),
    ).toEqual({
      lines: ["run /help now"],
      cursorLine: 0,
      cursorCol: 9,
    });
  });

  test("propagates source failures", async () => {
    const registry = new UiRegistry();
    registry.register("broken", {
      component_keys: [],
      autocomplete: [{
        trigger: "/",
        kind: "command",
        fetch: () => {
          throw new Error("fetch failed");
        },
      }],
    });
    await expect(
      registry.getSuggestions(["/"], 0, 1, { signal: signal() }),
    ).rejects.toThrow("fetch failed");
  });
});
