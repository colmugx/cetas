<script lang="ts">
  import {
    Brain,
    ChevronDown,
    Send,
    Square,
    TriangleAlert,
    Waves,
  } from "@lucide/svelte";
  import {
    listModels,
    setEffort,
    setModel,
    setPermission,
    type ModelCatalog,
  } from "#lib/api";
  import { runtimeStore } from "#lib/runtime.svelte";
  import type { ServerEvent } from "#lib/socket";
  import MarkdownStream from "#lib/components/MarkdownStream.svelte";
  import Picker, { type PickerOption } from "#lib/components/Picker.svelte";
  import ToolCard from "#lib/components/ToolCard.svelte";
  import {
    useSmoothMarkdownStream,
  } from "markstream-svelte";

  type TranscriptItem =
    | { kind: "user"; turnId: string; text: string }
    | { kind: "assistant"; turnId: string; text: string; streaming: boolean }
    | { kind: "reasoning"; turnId: string; text: string }
    | {
        kind: "tool";
        turnId: string;
        callId: string;
        name: string;
        status: "running" | "done" | "error";
        args: Record<string, unknown>;
        result: string;
      }
    | { kind: "error"; turnId: string; text: string };

  const suggestions = [
    "Map this workspace and summarize what it does",
    "Review the latest changes and flag risky ones",
    "Draft a release checklist for this repository",
  ];

  const permissionOptions: PickerOption[] = [
    { value: "readonly", label: "Read only" },
    { value: "workspace_write", label: "Workspace write" },
    { value: "yolo", label: "Yolo · no approvals" },
  ];

  let prompt = $state("");
  let items = $state<TranscriptItem[]>([]);
  let busy = $state(false);
  let lastSeq = $state(0);
  let atBottom = $state(true);
  let scrollEl: HTMLDivElement | undefined = $state();
  let composerEl: HTMLTextAreaElement | undefined = $state();
  let catalog = $state<ModelCatalog | null>(null);
  let configError = $state("");
  let configErrorTimer: ReturnType<typeof setTimeout> | undefined;

  const snapshot = $derived(runtimeStore.runtime);
  const ready = $derived(runtimeStore.core === "ready");

  // Streaming text lives in a smooth-reveal controller instead of the items
  // array: deltas never copy the transcript, and reveal is paced per frame.
  const live = useSmoothMarkdownStream({
    minCharsPerSecond: 30,
    maxCharsPerSecond: 2400,
    maxCommitFps: 30,
  });
  let liveTurnId = $state("");

  const liveVolume = $derived(live.visible.length);

  const currentTurn = $derived.by(() => {
    const active = items.findLast(
      (item) => item.kind === "assistant" && item.streaming,
    );
    return active?.turnId ?? "";
  });

  const textVolume = $derived.by(() =>
    items.reduce(
      (total, item) =>
        total +
        ("text" in item ? item.text.length : 0) +
        ("result" in item ? item.result.length : 0),
      0,
    ),
  );

  const modelOptions = $derived.by<PickerOption[]>(() =>
    (catalog?.slots ?? []).map((slot) => ({
      value: slot.id,
      label: slot.label || slot.id,
      hint: slot.context_window
        ? `${Math.round(slot.context_window / 1000)}k`
        : undefined,
      group: slot.provider,
      active: slot.id === (snapshot?.model ?? ""),
    })),
  );

  const effortOptions = $derived.by<PickerOption[]>(() => {
    const activeSlot = catalog?.slots.find(
      (slot) => slot.id === (snapshot?.model ?? ""),
    );
    const efforts = activeSlot?.efforts ?? [];
    const current = snapshot?.effort ?? "default";
    if (efforts.length === 0) {
      return [{ value: current, label: current, active: true }];
    }
    return efforts.map((effort) => ({
      value: effort,
      label: effort,
      active: effort === current,
    }));
  });

  const shortModel = $derived.by(() => {
    const model = snapshot?.model ?? "";
    return model.length > 0 ? (model.split("/").pop() ?? model) : "—";
  });

  $effect(() => {
    const dispose = runtimeStore.realtime.onEvent(onEvent);
    return dispose;
  });

  // A new session means a fresh transcript; history replay is future work.
  let previousSessionId: string | undefined;
  $effect(() => {
    const id = snapshot?.session_id ?? "";
    if (previousSessionId !== undefined && id !== previousSessionId) {
      items = [];
      busy = false;
      liveTurnId = "";
      live.reset();
    }
    previousSessionId = id;
  });

  $effect(() => {
    if (ready) void loadCatalog();
  });

  $effect(() => {
    // Track both committed items and the live reveal so autoscroll follows
    // the paced stream, not just turn boundaries.
    void textVolume;
    void liveVolume;
    if (atBottom && scrollEl) {
      scrollEl.scrollTo({ top: scrollEl.scrollHeight });
    }
  });

  function onEvent(event: ServerEvent) {
    if (typeof event.seq === "number") {
      if (event.seq <= lastSeq) return;
      lastSeq = event.seq;
    }

    const turnId =
      typeof event.turn_id === "string" && event.turn_id.length > 0
        ? event.turn_id
        : currentTurn;

    switch (event.type) {
      case "session.snapshot":
        busy = Boolean(event.busy);
        return;

      case "turn.accepted":
        if (!turnId) return;
        busy = true;
        liveTurnId = turnId;
        live.reset();
        items = [
          ...items,
          {
            kind: "user",
            turnId,
            text: typeof event.prompt === "string" ? event.prompt : "",
          },
          { kind: "assistant", turnId, text: "", streaming: true },
        ];
        return;

      case "assistant.text_delta":
        if (typeof event.delta !== "string") return;
        live.enqueue(event.delta);
        return;

      case "assistant.reasoning_delta":
        if (!turnId || typeof event.delta !== "string") return;
        enqueueReasoning(turnId, event.delta);
        return;

      case "tool.started":
        if (
          !turnId ||
          typeof event.tool_call_id !== "string" ||
          typeof event.tool_name !== "string"
        )
          return;
        items = [
          ...items,
          {
            kind: "tool",
            turnId,
            callId: event.tool_call_id,
            name: event.tool_name,
            status: "running",
            args:
              event.arguments !== undefined &&
              typeof event.arguments === "object" &&
              event.arguments !== null
                ? (event.arguments as Record<string, unknown>)
                : {},
            result: "",
          },
        ];
        return;

      case "tool.completed":
        if (typeof event.tool_call_id !== "string") return;
        items = items.map((item) =>
          item.kind === "tool" && item.callId === event.tool_call_id
            ? {
                ...item,
                status: event.is_error ? "error" : "done",
                result:
                  typeof event.result === "string" ? event.result : item.result,
              }
            : item,
        );
        return;

      case "turn.completed":
        if (!turnId) return;
        busy = false;
        if (turnId === liveTurnId) {
          live.finish();
          liveTurnId = "";
        }
        items = items.map((item) =>
          item.kind === "assistant" && item.turnId === turnId
            ? {
                ...item,
                text:
                  item.text ||
                  (typeof event.text === "string" ? event.text : ""),
                streaming: false,
              }
            : item,
        );
        return;

      case "turn.failed":
        busy = false;
        if (turnId === liveTurnId) {
          live.finish();
          liveTurnId = "";
        }
        items = [
          ...items.map((item) =>
            item.kind === "assistant" && item.turnId === turnId
              ? { ...item, streaming: false }
              : item,
          ),
          {
            kind: "error",
            turnId,
            text:
              typeof event.message === "string" ? event.message : "Turn failed",
          },
        ];
        return;

      case "protocol.error":
        items = [
          ...items,
          {
            kind: "error",
            turnId,
            text:
              typeof event.message === "string"
                ? event.message
                : "Protocol error",
          },
        ];
        return;
    }
  }

  // Reasoning deltas are coalesced per animation frame: one reactive write
  // per frame instead of one per network token.
  let pendingReasoningText = "";
  let pendingReasoningTurn = "";
  let reasoningFlushScheduled = false;

  function enqueueReasoning(turnId: string, delta: string) {
    pendingReasoningTurn = turnId;
    pendingReasoningText += delta;
    if (reasoningFlushScheduled) return;
    reasoningFlushScheduled = true;
    requestAnimationFrame(() => {
      reasoningFlushScheduled = false;
      flushReasoning();
    });
  }

  function flushReasoning() {
    const turnId = pendingReasoningTurn;
    const delta = pendingReasoningText;
    pendingReasoningText = "";
    if (!turnId || !delta) return;
    const index = items.findIndex(
      (item) => item.kind === "reasoning" && item.turnId === turnId,
    );
    if (index < 0) {
      items = [...items, { kind: "reasoning", turnId, text: delta }];
      return;
    }
    const item = items[index];
    if (item.kind === "reasoning") {
      items[index] = { ...item, text: item.text + delta };
    }
  }

  async function loadCatalog() {
    try {
      catalog = await listModels();
    } catch {
      // The picker falls back to the current runtime values.
    }
  }

  function flashConfigError(message: string) {
    configError = message;
    if (configErrorTimer) clearTimeout(configErrorTimer);
    configErrorTimer = setTimeout(() => (configError = ""), 6000);
  }

  async function applyConfig(action: () => Promise<unknown>) {
    try {
      await action();
      await loadCatalog();
    } catch (error) {
      flashConfigError(error instanceof Error ? error.message : String(error));
    }
  }

  function send() {
    const text = prompt.trim();
    if (!text || busy || runtimeStore.core !== "ready") return;
    const sent = runtimeStore.realtime.send({ type: "turn.start", prompt: text });
    if (sent) {
      prompt = "";
      if (composerEl) composerEl.style.height = "auto";
    }
  }

  function abort() {
    runtimeStore.realtime.send({ type: "turn.abort" });
  }

  function onInput(event: Event) {
    const el = event.currentTarget as HTMLTextAreaElement;
    prompt = el.value;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 208)}px`;
  }

  function onKeyDown(event: KeyboardEvent) {
    if (event.key !== "Enter" || event.shiftKey) return;
    event.preventDefault();
    send();
  }

  function onScroll() {
    if (!scrollEl) return;
    atBottom =
      scrollEl.scrollHeight - scrollEl.scrollTop - scrollEl.clientHeight < 80;
  }
</script>

<div class="flex h-full min-h-0 flex-col">
  <div
    bind:this={scrollEl}
    onscroll={onScroll}
    class="scroll-slim min-h-0 flex-1 overflow-y-auto"
  >
    <div class="mx-auto w-full max-w-3xl px-5 py-6">
      {#if items.length > 0}
        <div class="space-y-4 pb-2">
          {#each items as item (item)}
            <div class="animate-rise">
              {#if item.kind === "user"}
                <div class="flex justify-end">
                  <div
                    class="max-w-[82%] rounded-2xl rounded-br-md border border-line bg-raised px-4 py-2.5 text-sm leading-6 text-fg"
                  >
                    {item.text}
                  </div>
                </div>
              {:else if item.kind === "assistant"}
                {#if liveTurnId === item.turnId}
                  <MarkdownStream
                    content={live.visible}
                    final={live.final}
                    streaming={!live.done}
                  />
                {:else}
                  <MarkdownStream content={item.text} />
                {/if}
              {:else if item.kind === "reasoning"}
                <details class="group rounded-xl border border-line bg-panel/60">
                  <summary
                    class="flex cursor-pointer select-none items-center gap-2 px-3.5 py-2.5 text-xs font-medium text-fg-muted [&::-webkit-details-marker]:hidden"
                  >
                    <Brain size={13} class="text-fg-faint" />
                    Reasoning
                    <ChevronDown
                      size={13}
                      class="ml-auto text-fg-faint transition-transform group-open:rotate-180"
                    />
                  </summary>
                  <div
                    class="whitespace-pre-wrap border-t border-line px-3.5 py-3 text-xs leading-5 text-fg-muted"
                  >
                    {item.text}
                  </div>
                </details>
              {:else if item.kind === "tool"}
                <ToolCard
                  name={item.name}
                  args={item.args}
                  result={item.result}
                  status={item.status}
                />
              {:else}
                <div
                  class="flex items-start gap-2.5 rounded-xl border border-bad/25 bg-bad/10 px-4 py-3 text-xs leading-5 text-bad"
                >
                  <TriangleAlert size={14} class="mt-0.5 shrink-0" />
                  <span class="min-w-0 whitespace-pre-wrap">{item.text}</span>
                </div>
              {/if}
            </div>
          {/each}
        </div>
      {:else}
        <div class="flex min-h-[52vh] flex-col items-center justify-center text-center">
          <div
            class="grid size-12 place-items-center rounded-2xl border border-accent/20 bg-accent-dim text-accent"
          >
            <Waves size={22} />
          </div>
          <h1 class="mt-5 text-2xl font-semibold tracking-[-0.02em] text-fg">
            What should Cetas work on?
          </h1>
          <p class="mt-2 max-w-md text-sm leading-6 text-fg-muted">
            Turns run in the MoonBit host. Reasoning, tool calls, and replies
            stream back over the realtime channel.
          </p>
          {#if ready}
            <div class="mt-7 flex flex-wrap justify-center gap-2">
              {#each suggestions as suggestion (suggestion)}
                <button
                  onclick={() => {
                    prompt = suggestion;
                    composerEl?.focus();
                  }}
                  class="rounded-full border border-line bg-panel px-3.5 py-2 text-xs text-fg-muted transition-colors hover:border-line-strong hover:bg-raised hover:text-fg"
                >
                  {suggestion}
                </button>
              {/each}
            </div>
          {/if}
          <p class="mt-7 font-mono text-[11px] text-fg-faint">
            {ready
              ? "Enter to send · Shift+Enter for newline"
              : "Finish Cetas setup before starting a turn"}
          </p>
        </div>
      {/if}
    </div>
  </div>

  <div class="shrink-0 border-t border-line bg-panel/50 backdrop-blur">
    <div class="mx-auto w-full max-w-3xl px-5 pb-4 pt-3">
      <div
        class="rounded-2xl border border-line-strong bg-raised shadow-[0_12px_40px_-12px_var(--shadow-color)] transition-colors focus-within:border-accent/40"
      >
        <textarea
          bind:this={composerEl}
          bind:value={prompt}
          oninput={onInput}
          onkeydown={onKeyDown}
          rows="1"
          disabled={!ready}
          placeholder={ready
            ? "Ask Cetas to change something…"
            : "Finish Cetas setup before starting a turn…"}
          class="scroll-slim block max-h-52 w-full resize-none bg-transparent px-4 py-3.5 text-sm leading-6 text-fg outline-none placeholder:text-fg-faint disabled:opacity-50"
        ></textarea>
        <div class="flex items-center justify-between gap-3 px-3 pb-2.5">
          <div class="flex min-w-0 items-center gap-1.5">
            <Picker
              label="model"
              value={shortModel}
              options={modelOptions}
              disabled={busy || !ready}
              searchable
              onSelect={(value) => void applyConfig(() => setModel(value))}
            />
            <Picker
              label="effort"
              value={snapshot?.effort || "default"}
              options={effortOptions}
              disabled={busy || !ready}
              onSelect={(value) => void applyConfig(() => setEffort(value))}
            />
            <Picker
              label="permission"
              value={snapshot?.permission || "readonly"}
              options={permissionOptions}
              disabled={busy || !ready}
              onSelect={(value) => void applyConfig(() => setPermission(value))}
            />
            {#if configError}
              <span class="hidden min-w-0 truncate text-[11px] text-bad md:inline">
                {configError}
              </span>
            {:else if busy}
              <span class="hidden font-mono text-[11px] text-fg-faint md:inline">
                turn running
              </span>
            {/if}
          </div>
          {#if busy}
            <button
              onclick={abort}
              class="grid size-8 shrink-0 place-items-center rounded-xl border border-bad/30 bg-bad/10 text-bad transition hover:bg-bad/20"
              title="Abort turn"
            >
              <Square size={12} fill="currentColor" />
            </button>
          {:else}
            <button
              onclick={send}
              disabled={!prompt.trim() || !ready || runtimeStore.socketState !== "online"}
              class="grid size-8 shrink-0 place-items-center rounded-xl bg-accent text-canvas transition hover:bg-accent-strong disabled:opacity-30"
              title="Send"
            >
              <Send size={15} />
            </button>
          {/if}
        </div>
      </div>
    </div>
  </div>
</div>
