<script lang="ts">
  import {
    Brain,
    ChevronDown,
    Send,
    Square,
    TriangleAlert,
    Waves,
  } from "@lucide/svelte";
  import type { PickerOption } from "#lib/components/Picker.svelte";
  import MarkdownStream from "#lib/components/MarkdownStream.svelte";
  import Picker from "#lib/components/Picker.svelte";
  import ToolCard from "#lib/components/ToolCard.svelte";
  import { setEffort, setModel, setPermission } from "#lib/api";
  import { runtimeStore } from "#lib/runtime.svelte";

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
  let atBottom = $state(true);
  let scrollEl: HTMLDivElement | undefined = $state();
  let composerEl: HTMLTextAreaElement | undefined = $state();
  let configError = $state("");
  let configErrorTimer: ReturnType<typeof setTimeout> | undefined;

  const view = $derived(runtimeStore.activeSession());
  const items = $derived(view?.items ?? []);
  const busy = $derived(view?.busy ?? false);
  const ready = $derived(runtimeStore.core === "ready");

  const liveVolume = $derived(view?.live?.visible.length ?? 0);
  const itemVolume = $derived.by(() =>
    items.reduce(
      (total, item) =>
        total +
        ("text" in item ? item.text.length : 0) +
        ("result" in item ? item.result.length : 0),
      0,
    ),
  );

  const modelOptions = $derived.by<PickerOption[]>(() =>
    (runtimeStore.catalog?.slots ?? []).map((slot) => ({
      value: slot.id,
      label: slot.label || slot.id,
      hint: slot.context_window
        ? `${Math.round(slot.context_window / 1000)}k`
        : undefined,
      group: slot.provider,
      active: slot.id === (view?.model ?? ""),
    })),
  );

  const effortOptions = $derived.by<PickerOption[]>(() => {
    const efforts =
      runtimeStore.catalog?.slots.find(
        (slot) => slot.id === (view?.model ?? ""),
      )?.efforts ?? [];
    const current = view?.effort || "default";
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
    const model = view?.model ?? "";
    return model.length > 0 ? (model.split("/").pop() ?? model) : "—";
  });

  $effect(() => {
    void itemVolume;
    void liveVolume;
    if (atBottom && scrollEl) {
      scrollEl.scrollTo({ top: scrollEl.scrollHeight });
    }
  });

  function flashConfigError(message: string) {
    configError = message;
    if (configErrorTimer) clearTimeout(configErrorTimer);
    configErrorTimer = setTimeout(() => (configError = ""), 6000);
  }

  async function applyConfig(action: () => Promise<unknown>) {
    try {
      await action();
      await runtimeStore.loadCatalog();
    } catch (error) {
      flashConfigError(error instanceof Error ? error.message : String(error));
    }
  }

  function send() {
    const text = prompt.trim();
    if (!text || busy || !ready) return;
    const sent = runtimeStore.realtime.send({
      type: "turn.start",
      prompt: text,
      session_id: runtimeStore.activeSessionId,
    });
    if (sent) {
      prompt = "";
      if (composerEl) composerEl.style.height = "auto";
    }
  }

  function abort() {
    runtimeStore.realtime.send({
      type: "turn.abort",
      session_id: runtimeStore.activeSessionId,
    });
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
                {#if view?.liveTurnId === item.turnId && view?.live}
                  <MarkdownStream
                    content={view.live.visible}
                    final={view.live.final}
                    streaming={!view.live.done}
                  />
                {:else}
                  <MarkdownStream content={item.text} />
                {/if}
              {:else if item.kind === "reasoning"}
                <details open={item.streaming} class="group rounded-xl border border-line bg-panel/60">
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
        <div
          class="flex min-h-[52vh] flex-col items-center justify-center text-center"
        >
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
              value={view?.effort || "default"}
              options={effortOptions}
              disabled={busy || !ready}
              onSelect={(value) => void applyConfig(() => setEffort(value))}
            />
            <Picker
              label="permission"
              value={view?.permission || "readonly"}
              options={permissionOptions}
              disabled={busy || !ready}
              onSelect={(value) => void applyConfig(() => setPermission(value))}
            />
            {#if configError}
              <span
                class="hidden min-w-0 truncate text-[11px] text-bad md:inline"
              >
                {configError}
              </span>
            {:else if busy}
              <span
                class="hidden font-mono text-[11px] text-fg-faint md:inline"
              >
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
