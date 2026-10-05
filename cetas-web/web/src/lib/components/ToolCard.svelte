<script lang="ts">
  import { synthesizeDiff } from "#lib/markdown";
  import { Wrench } from "@lucide/svelte";

  export type ToolStatus = "running" | "done" | "error";

  let {
    name,
    args = {},
    result = "",
    status,
  }: {
    name: string;
    args?: Record<string, unknown>;
    result?: string;
    status: ToolStatus;
  } = $props();

  const arg = (key: string): string | undefined => {
    const value = args[key];
    return typeof value === "string" ? value : undefined;
  };

  const headerTone = $derived(
    status === "done"
      ? "text-accent"
      : status === "error"
        ? "text-bad"
        : "text-fg-muted",
  );

  const body = $derived.by(() => {
    switch (name) {
      case "bash":
        return { kind: "terminal" as const, command: arg("cmd") ?? arg("command") };
      case "read":
        return { kind: "read" as const, path: arg("path") ?? "—", content: result };
      case "write":
        return {
          kind: "diff" as const,
          path: arg("path") ?? "—",
          lines: synthesizeDiff(undefined, arg("content")),
        };
      case "edit":
        return {
          kind: "diff" as const,
          path: arg("path") ?? "—",
          lines: synthesizeDiff(arg("old_text"), arg("new_text")),
        };
      case "glob":
        return { kind: "search" as const, label: "pattern", needle: arg("pattern") ?? "—", output: result };
      case "grep":
        return { kind: "search" as const, label: "needle", needle: arg("needle") ?? "—", output: result };
      case "webfetch":
        return { kind: "web" as const, url: arg("url") ?? "—", output: result };
      default:
        return { kind: "generic" as const };
    }
  });
</script>

<div class="overflow-hidden rounded-xl border border-line bg-panel/60">
  <div class="flex items-center gap-2.5 border-b border-line px-3.5 py-2.5">
    <span class="grid size-6 shrink-0 place-items-center rounded-md bg-raised text-fg-muted">
      <Wrench size={12} />
    </span>
    <span class="min-w-0 truncate font-mono text-xs text-fg">{name}</span>
    <span class="ml-auto flex shrink-0 items-center gap-1.5 text-[11px] font-medium {headerTone}">
      <span
        class="size-1.5 rounded-full bg-current {status === 'running'
          ? 'animate-breathe'
          : 'opacity-80'}"
      ></span>
      {status}
    </span>
  </div>

  {#if body.kind === "terminal"}
    <div class="border-b border-line px-3.5 py-2 font-mono text-[11px] text-fg">
      <span class="select-none text-fg-faint">$ </span>{body.command ?? "—"}
    </div>
    <pre
      class="scroll-slim max-h-56 overflow-auto whitespace-pre-wrap px-3.5 py-3 font-mono text-[11px] leading-5 text-fg-muted"
    >{result || "waiting for output…"}</pre
    >
  {:else if body.kind === "read"}
    <div class="border-b border-line px-3.5 py-2 font-mono text-[11px] text-fg">
      {body.path}
    </div>
    <pre
      class="scroll-slim max-h-56 overflow-auto whitespace-pre-wrap px-3.5 py-3 font-mono text-[11px] leading-5 text-fg-muted"
    >{body.content || "waiting for content…"}</pre
    >
  {:else if body.kind === "diff"}
    <div class="border-b border-line px-3.5 py-2 font-mono text-[11px] text-fg">
      {body.path}
    </div>
    <div class="scroll-slim max-h-56 overflow-auto px-3.5 py-3 font-mono text-[11px] leading-5">
      {#if body.lines.length === 0}
        <span class="text-fg-faint">no changes captured</span>
      {/if}
      {#each body.lines as line, i (i)}
        <div
          class="whitespace-pre-wrap rounded px-1 {line.sign === '+'
            ? 'bg-accent/10 text-fg'
            : line.sign === '-'
              ? 'bg-bad/10 text-fg'
              : 'text-fg-faint'}"
        ><span class="select-none opacity-60">{line.sign}&nbsp;</span>{line.text || " "}</div>
      {/each}
    </div>
  {:else if body.kind === "search"}
    <div class="border-b border-line px-3.5 py-2 font-mono text-[11px] text-fg">
      <span class="text-fg-faint">{body.label}: </span>{body.needle}
    </div>
    <pre
      class="scroll-slim max-h-56 overflow-auto whitespace-pre-wrap px-3.5 py-3 font-mono text-[11px] leading-5 text-fg-muted"
    >{body.output || "waiting for matches…"}</pre
    >
  {:else if body.kind === "web"}
    <div class="border-b border-line truncate px-3.5 py-2 font-mono text-[11px] text-fg">
      {body.url}
    </div>
    <pre
      class="scroll-slim max-h-56 overflow-auto whitespace-pre-wrap px-3.5 py-3 font-mono text-[11px] leading-5 text-fg-muted"
    >{body.output || "waiting for content…"}</pre
    >
  {:else}
    <pre
      class="scroll-slim max-h-56 overflow-auto whitespace-pre-wrap px-3.5 py-3 font-mono text-[11px] leading-5 text-fg-muted"
    >{result || "waiting for result…"}</pre
    >
  {/if}
</div>
