<script lang="ts">
  import {
    Brain,
    ChevronDown,
    Copy,
    ListPlus,
    Radio,
    Send,
    Square,
    TriangleAlert,
    Waves,
    X,
  } from "@lucide/svelte";
  import { fetchTrace, type TraceEvent } from "#lib/api";
  import type { PickerOption } from "#lib/components/Picker.svelte";
  import FloatExtWindow from "#lib/components/FloatExtWindow.svelte";
  import MarkdownStream from "#lib/components/MarkdownStream.svelte";
  import Picker from "#lib/components/Picker.svelte";
  import ToolCard from "#lib/components/ToolCard.svelte";
  import { setEffort, setModel, setPermission } from "#lib/api";
  import { runtimeStore } from "#lib/runtime.svelte";
  import { toast } from "#lib/toast.svelte";

  const suggestions = [
    "Map this workspace and summarize what it does",
    "Review the latest changes and flag risky ones",
    "Draft a release checklist for this repository",
  ];

  const permissionOptions: PickerOption[] = [
    { value: "readonly", label: "Read only" },
    { value: "workspace_write", label: "Workspace write" },
    { value: "interactive", label: "Interactive · ask for tools" },
    { value: "yolo", label: "Yolo · no approvals" },
  ];

  let prompt = $state("");
  let atBottom = $state(true);
  let scrollEl: HTMLDivElement | undefined = $state();
  let composerEl: HTMLTextAreaElement | undefined = $state();
  let configError = $state("");
  let uiInputDraft = $state("");
  let traceTurnId = $state<string | null>(null);
  let traceEvents = $state<TraceEvent[] | null>(null);

  const fmtTime = (ts?: number): string | null =>
    ts
      ? new Date(ts).toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
        })
      : null;

  function openTrace(turnId: string) {
    traceTurnId = turnId;
    traceEvents = null;
    const session = runtimeStore.activeSessionId;
    if (!session) return;
    void fetchTrace({ session, turn: turnId, limit: 400 }).then((page) => {
      traceEvents = page.turns[0]?.events ?? [];
    });
  }

  function copyText(text: string) {
    void navigator.clipboard.writeText(text);
    toast("success", "Copied");
  }

  function focusOnMount(node: HTMLElement, focus: boolean) {
    if (focus) node.focus();
  }
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
    if (!text || !ready) return;
    const sessionId = runtimeStore.activeSessionId;
    if (!sessionId) return;
    if (busy) {
      // Steering-compatible queue: dispatch happens when the turn settles.
      runtimeStore.enqueuePrompt(sessionId, text);
      prompt = "";
      if (composerEl) composerEl.style.height = "auto";
      toast("info", "Queued — dispatches when the turn settles");
      return;
    }
    const sent = runtimeStore.realtime.send({
      type: "turn.start",
      prompt: text,
      session_id: sessionId,
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

<div class="relative flex h-full min-h-0 flex-col">
  <div
    bind:this={scrollEl}
    onscroll={onScroll}
    class="scroll-slim min-h-0 flex-1 overflow-y-auto"
  >
    <div class="relative mx-auto h-full w-full">
      <FloatExtWindow sessionId={runtimeStore.activeSessionId} />
      <div class="mx-auto w-full max-w-3xl px-5 py-6">
      {#if items.length > 0}
        <div class="space-y-4 pb-2">
          {#each items as item (item)}
            <div class="animate-rise">
              {#if item.kind === "user"}
                {@const times = view?.turnTimes[item.turnId]}
                <div class="flex flex-col items-end gap-1">
                  <!-- header slot: attachments land here -->
                  <div
                    class="max-w-[82%] rounded-2xl rounded-br-md border border-line bg-raised px-4 py-2.5 text-sm leading-6 text-fg"
                  >
                    {item.text}
                  </div>
                  <div
                    class="flex w-full max-w-[82%] items-center justify-between text-[10px]"
                  >
                    <button
                      onclick={() => copyText(item.text)}
                      class="flex items-center gap-1 rounded px-1 py-0.5 text-fg-faint transition-colors hover:text-fg"
                      title="Copy prompt"
                    >
                      <Copy size={10} />
                      copy
                    </button>
                    <span class="font-mono text-fg-faint"
                      >{fmtTime(times?.sentAt)}</span
                    >
                  </div>
                </div>
              {:else if item.kind === "assistant"}
                {@const times = view?.turnTimes[item.turnId]}
                {@const isLive = view?.liveTurnId === item.turnId && view?.live}
                <div class="flex flex-col gap-1">
                  <!-- header slot: attachments land here -->
                  {#if isLive && view?.live}
                    <MarkdownStream
                      content={view.live.visible}
                      final={view.live.final}
                      streaming={!view.live.done}
                    />
                  {:else}
                    <MarkdownStream content={item.text} />
                  {/if}
                  {#if !isLive}
                    <div
                      class="flex items-center justify-between text-[10px]"
                    >
                      <div class="flex items-center gap-2">
                        <button
                          onclick={() => openTrace(item.turnId)}
                          class="flex items-center gap-1 rounded px-1 py-0.5 text-fg-faint transition-colors hover:text-fg"
                          title="Open the trace of this answer"
                        >
                          <Radio size={10} />
                          trace
                        </button>
                        <button
                          onclick={() => copyText(item.text)}
                          class="flex items-center gap-1 rounded px-1 py-0.5 text-fg-faint transition-colors hover:text-fg"
                          title="Copy answer"
                        >
                          <Copy size={10} />
                          copy
                        </button>
                      </div>
                      <span class="font-mono text-fg-faint">
                        {fmtTime(times?.completedAt)
                          ? `done ${fmtTime(times?.completedAt)}`
                          : ""}
                      </span>
                    </div>
                  {/if}
                </div>
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
  </div>

  {#if traceTurnId}
    <div
      class="absolute top-14 right-5 z-30 flex max-h-[70vh] w-[420px] flex-col overflow-hidden rounded-xl border border-line-strong bg-raised/95 shadow-[0_12px_40px_-12px_var(--shadow-color)] backdrop-blur"
    >
      <div
        class="flex shrink-0 items-center justify-between border-b border-line px-3.5 py-2.5"
      >
        <div class="flex items-center gap-2">
          <Radio size={12} class="text-accent" />
          <span class="text-xs font-medium text-fg"
            >Trace · {traceTurnId}</span
          >
        </div>
        <button
          onclick={() => (traceTurnId = null)}
          class="rounded p-0.5 text-fg-faint transition-colors hover:text-fg"
          title="Close trace"
        >
          <X size={12} />
        </button>
      </div>
      <div class="scroll-slim min-h-0 flex-1 overflow-y-auto">
        {#if traceEvents === null}
          <p class="px-3.5 py-3 text-[11px] text-fg-faint">Loading…</p>
        {:else if traceEvents.length === 0}
          <p class="px-3.5 py-3 text-[11px] text-fg-faint">
            No events recorded for this turn.
          </p>
        {:else}
          {#each traceEvents as event (event.event_id)}
            <div class="border-b border-line/50 last:border-b-0">
              <div
                class="flex items-center gap-2.5 px-3.5 py-1.5 text-[10.5px]"
              >
                <span
                  class="w-10 shrink-0 font-mono text-fg-faint">#{event.seq}</span
                >
                <span class="w-40 shrink-0 truncate font-mono text-fg"
                  >{event.type}</span
                >
                <span class="min-w-0 flex-1 truncate text-fg-faint">
                  {typeof event.delta === "string"
                    ? event.delta.slice(0, 50)
                    : typeof event.tool_name === "string"
                      ? event.tool_name
                      : ""}
                </span>
                <span
                  class="shrink-0 font-mono text-[9.5px] text-fg-faint"
                >
                  {event.ts
                    ? new Date(event.ts).toLocaleTimeString([], {
                        hour: "2-digit",
                        minute: "2-digit",
                        second: "2-digit",
                      })
                    : ""}
                </span>
              </div>
            </div>
          {/each}
        {/if}
      </div>
    </div>
  {/if}

  <div class="shrink-0 border-t border-line bg-panel/50 backdrop-blur">
    <div class="mx-auto w-full max-w-3xl px-5 pb-4 pt-3">
      <div
        class="rounded-2xl border border-line-strong bg-raised shadow-[0_12px_40px_-12px_var(--shadow-color)] transition-colors focus-within:border-accent/40"
      >
        {#if view?.context && view.context.measured &&
        !view.statusSegments.some((segment) => segment.key === "ctx")}
          {@const measured = view.context.measured}
          {@const window = view.context.window}
          {@const percent = window
            ? Math.min(100, Math.round((measured / window) * 100))
            : null}
          <div class="flex items-center gap-2 px-4 pt-2.5">
            {#if percent !== null}
              <div
                class="relative h-1 flex-1 overflow-hidden rounded-full bg-canvas"
              >
                <div
                  class="h-full rounded-full {percent >=
                  Math.round(view.context.threshold * 100)
                    ? 'bg-warn'
                    : 'bg-accent/70'}"
                  style="width: {percent}%"
                ></div>
              </div>
              <span class="font-mono text-[9.5px] text-fg-faint"
                >ctx {percent}%</span
              >
            {:else}
              <span class="font-mono text-[9.5px] text-fg-faint"
                >ctx {(measured / 1000).toFixed(1)}k tok · {view.context.messages}
                msgs</span
              >
            {/if}
          </div>
        {/if}
        {#if view?.uiRequest}
          {@const req = view.uiRequest}
          <div class="border-t border-accent/30 bg-accent-dim/60 px-4 py-3.5">
            <div class="flex items-center justify-between gap-3">
              <span
                class="text-[10px] font-semibold uppercase tracking-[0.14em] text-accent"
              >
                {req.kind === "select"
                  ? "Approval requested"
                  : req.kind === "confirm"
                    ? "Confirmation requested"
                    : "Input requested"}
              </span>
              <span class="font-mono text-[10px] text-fg-faint"
                >Enter allow · Esc deny</span
              >
            </div>
            <p class="mt-2 whitespace-pre-wrap text-xs leading-5 text-fg">
              {req.prompt}
            </p>
            {#if req.kind === "select"}
              <div class="mt-3 flex flex-wrap gap-1.5">
                {#each req.options as option, index (option + index)}
                  <button
                    onclick={() =>
                      runtimeStore.respondUi(
                        view.id,
                        req.requestId,
                        { selected: index },
                      )}
                    use:focusOnMount={index === (req.defaultIndex ?? 0)}
                    class="rounded-lg border border-line-strong bg-raised px-3 py-1.5 text-xs font-medium text-fg transition-colors hover:border-accent/50 hover:text-accent {index ===
                    (req.defaultIndex ?? 0)
                      ? 'border-accent/50'
                      : ''}"
                  >
                    {option}
                  </button>
                {/each}
              </div>
            {:else if req.kind === "confirm"}
              <div class="mt-3 flex gap-1.5">
                <button
                  onclick={() =>
                    runtimeStore.respondUi(view.id, req.requestId, { yes: true })}
                  class="rounded-lg border border-accent/50 bg-raised px-3 py-1.5 text-xs font-medium text-accent transition-colors hover:bg-accent-dim"
                >
                  Yes
                </button>
                <button
                  onclick={() =>
                    runtimeStore.respondUi(view.id, req.requestId, { no: true })}
                  class="rounded-lg border border-line-strong bg-raised px-3 py-1.5 text-xs font-medium text-fg transition-colors hover:bg-panel"
                >
                  No
                </button>
              </div>
            {:else}
              <input
                bind:value={uiInputDraft}
                onkeydown={(event) => {
                  if (event.key === "Enter") {
                    runtimeStore.respondUi(view.id, req.requestId, {
                      text: uiInputDraft,
                    });
                    uiInputDraft = "";
                  }
                }}
                placeholder={req.defaultText ?? "Type your answer…"}
                class="mt-3 w-full rounded-lg border border-line-strong bg-raised px-3 py-2 text-xs text-fg outline-none placeholder:text-fg-faint"
                spellcheck="false"
              />
            {/if}
          </div>
        {:else if view?.queue.length}
          <div class="flex flex-wrap gap-1.5 px-3 pt-3">
            {#each view.queue as queued, index (index + queued)}
              <span
                class="flex max-w-full items-center gap-1.5 rounded-full border border-line bg-panel px-2.5 py-1 text-[11px] text-fg-muted"
                title={queued}
              >
                <span class="font-mono text-[10px] text-fg-faint"
                  >{index + 1}</span
                >
                <span class="min-w-0 max-w-[280px] truncate">{queued}</span>
                <button
                  onclick={() => runtimeStore.removeQueued(view.id, index)}
                  class="rounded p-0.5 text-fg-faint transition-colors hover:text-fg"
                  title="Remove from queue"
                >
                  <X size={10} />
                </button>
              </span>
            {/each}
          </div>
        {/if}
        <textarea
          bind:this={composerEl}
          bind:value={prompt}
          oninput={onInput}
          onkeydown={onKeyDown}
          rows="1"
          disabled={!ready || view?.uiRequest !== null && view?.uiRequest !== undefined}
          placeholder={ready
            ? "Ask Cetas to change something…"
            : "Finish Cetas setup before starting a turn…"}
          class="scroll-slim block max-h-52 w-full resize-none bg-transparent px-4 py-3.5 text-sm leading-6 text-fg outline-none placeholder:text-fg-faint disabled:opacity-50"
        ></textarea>
        <div class="flex items-center justify-between gap-3 px-3 pb-2.5">
          <div class="flex min-w-0 items-center gap-1.5">
            <Picker
              label="model"
              value="{shortModel} · {view?.effort || "default"}"
              options={modelOptions}
              disabled={busy || !ready}
              searchable
              onSelect={(value) => void applyConfig(() => setModel(value))}
            >
              {#snippet pinned()}
                  <div class="mb-1 text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-faint">
                    effort
                  </div>
                  <div class="flex flex-wrap gap-1">
                    {#each effortOptions as effort (effort.value)}
                      <button
                        onclick={() => void applyConfig(() => setEffort(effort.value))}
                        class="rounded-md border px-2 py-1 text-[11px] transition-colors {effort.active
                          ? 'border-accent/50 bg-accent-dim text-accent'
                          : 'border-line bg-raised text-fg-muted hover:text-fg'}"
                      >
                        {effort.label}
                      </button>
                    {/each}
                  </div>
              {/snippet}
            </Picker>
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
              title="Abort turn (Esc)"
            >
              <Square size={12} fill="currentColor" />
            </button>
            <button
              onclick={send}
              disabled={!prompt.trim()}
              class="grid size-8 shrink-0 place-items-center rounded-xl border border-accent/30 bg-accent-dim text-accent transition hover:bg-accent/20 disabled:opacity-30"
              title="Queue prompt (dispatches when the turn settles)"
            >
              <ListPlus size={15} />
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

      <!-- composer dock: session stats pills + leftover statusbar segments,
           docked below the whole input box -->
      {#if view && (view.dockStats || view.statusSegments.length > 0)}
        <div
          class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-0.5 px-2 text-[11px] text-fg-faint"
        >
          {#if view.dockStats}
            {@const dock = view.dockStats}
            <span class="flex items-center gap-1" title="{dock.ttftMs} ms avg ttft">
              <span class="font-mono">
                {dock.turns} {dock.turns === 1 ? "turn" : "turns"} · {dock.steps}
                {dock.steps === 1 ? "step" : "steps"}
              </span>
              {#if dock.tokPerSec > 0}
                <span class="font-mono">{dock.tokPerSec} tok/s</span>
              {/if}
            </span>
          {/if}
          {#if view.dockStats && view.dockStats.tokens > 0}
            <span class="flex items-center gap-1 font-mono">
              <span>{(view.dockStats.tokens / 1000).toFixed(1)}k tokens</span>
              {#if view.dockStats.cacheHitPct !== null}
                <span>{view.dockStats.cacheHitPct}% cached</span>
              {/if}
            </span>
          {/if}
          {#each view.statusSegments as segment (segment.key)}
            {#if !["turns", "steps", "ttft", "tps", "avg", "cache", "ctx", "permission", "model", "time_limit", "5h"].includes(
                segment.key.toLowerCase(),
              )}
              <span class="flex items-center gap-1">
                <span class="text-fg-muted">{segment.key}</span>
                <span
                  class="font-mono"
                  style={segment.color ? `color: ${segment.color}` : ""}
                >
                  {segment.value}
                </span>
              </span>
            {/if}
          {/each}
        </div>
      {/if}
    </div>
  </div>
</div>
