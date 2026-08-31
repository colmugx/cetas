import { describe, expect, test } from "bun:test";

import { UiRegistry } from "./ui-registry.ts";

function signal(): AbortSignal {
  return new AbortController().signal;
}

// Two sources with different triggers that produce equal-length prefixes.
function tieRegistry(): UiRegistry {
  const registry = new UiRegistry();
  registry.register("files", {
    component_keys: [],
    autocomplete: [{
      trigger: "@",
      kind: "file",
      fetch: (prefix) => [{
        label: `file:${prefix}`,
        detail: "file",
        insert_text: `@${prefix}`,
      }],
    }],
  });
  registry.register("skills", {
    component_keys: [],
    autocomplete: [{
      trigger: "$",
      kind: "custom",
      fetch: (prefix) => [{
        label: `skill:${prefix}`,
        detail: "skill",
        insert_text: `$${prefix}`,
      }],
    }],
  });
  return registry;
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

  test("spanSpaces keeps matching after whitespace; default still rejects it", async () => {
    const registry = new UiRegistry();
    registry.register("plain", {
      component_keys: [],
      autocomplete: [{
        trigger: "/",
        kind: "command",
        fetch: (prefix) => [{
          label: `plain:${prefix}`,
          detail: "",
          insert_text: `/${prefix}`,
        }],
      }],
    });
    registry.register("argful", {
      component_keys: [],
      autocomplete: [{
        trigger: "/",
        kind: "command",
        spanSpaces: true,
        fetch: (prefix) => [{
          label: `argful:${prefix}`,
          detail: "",
          insert_text: `/${prefix}`,
        }],
      }],
    });

    // "/permission re" — the plain source drops out, the spanSpaces source
    // receives the full "command arg" query and owns the replacement prefix.
    const result = await registry.getSuggestions(
      ["/permission re"],
      0,
      14,
      { signal: signal() },
    );
    expect(result).toEqual({
      prefix: "/permission re",
      items: [
        { value: "/permission re", label: "argful:permission re" },
      ],
    });

    // Without spanSpaces, a space after the trigger never matches.
    const plainOnly = new UiRegistry();
    plainOnly.register("plain", {
      component_keys: [],
      autocomplete: [{
        trigger: "/",
        kind: "command",
        fetch: () => [{
          label: "x",
          detail: "",
          insert_text: "/x",
        }],
      }],
    });
    expect(
      await plainOnly.getSuggestions(["/cmd "], 0, 5, { signal: signal() }),
    ).toBeNull();
  });

  test("equal-length prefixes from different triggers: the trigger closest to the cursor wins", async () => {
    // "@a $b" — "@" and "$" both match with a 2-char prefix; "$" starts
    // closer to the cursor, so only skill items appear under prefix "$b".
    const result = await tieRegistry().getSuggestions(
      ["@a $b"],
      0,
      5,
      { signal: signal() },
    );
    expect(result).toEqual({
      prefix: "$b",
      items: [{ value: "$b", label: "skill:b", description: "skill" }],
    });
  });

  test("equal-length prefixes from different triggers: winner follows cursor position", async () => {
    // "$b @a" — mirrored line; "@" now owns the closest trigger occurrence.
    const result = await tieRegistry().getSuggestions(
      ["$b @a"],
      0,
      5,
      { signal: signal() },
    );
    expect(result).toEqual({
      prefix: "@a",
      items: [{ value: "@a", label: "file:a", description: "file" }],
    });
  });
});
