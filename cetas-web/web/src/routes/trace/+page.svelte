<script lang="ts">
  import { ChevronDown, RotateCw } from "@lucide/svelte";
  import { fetchTrace, type TraceEvent, type TraceTurn } from "#lib/api";
  import { runtimeStore } from "#lib/runtime.svelte";

  const eventTypes = [
    "turn.accepted",
    "turn.started",
    "assistant.reasoning_delta",
    "assistant.text_delta",
    "tool.started",
    "tool.approved",
    "tool.completed",
    "usage.delta",
    "context.state",
    "turn.completed",
    "turn.failed",
    "protocol.error",
  ];

  let turns = $state<TraceTurn[]>([]);
  let orphans = $state<TraceEvent[]>([]);
  let selectedKey = $state<string | null>(null);
  let typeFilter = $state("");
  let expandedSeq = $state<number | null>(null);
  let loading = $state(false);

  const sessionId = $derived(runtimeStore.activeSessionId);

  async function load() {
    loading = true;
    try {
      const page = await fetchTrace({
        session: sessionId || undefined,
        limit: 400,
      });
      turns = page.turns;
      orphans = page.orphans;
      if (selectedKey === null && turns.length > 0) {
        selectedKey = turnKey(turns[0]);
      }
    } catch {
      // Keep the last snapshot while the API is unreachable.
    } finally {
      loading = false;
    }
  }

  const turnKey = (turn: TraceTurn): string =>
    `${turn.session_id}/${turn.turn_id}`;

  const selected = $derived(
    turns.find((turn) => turnKey(turn) === selectedKey) ?? null,
  );

  const visibleEvents = $derived.by(() => {
    const events = selected?.events ?? [];
    if (!typeFilter) return events;
    return events.filter((event) => event.type === typeFilter);
  });

  $effect(() => {
    void sessionId;
    void load();
    const timer = setInterval(() => void load(), 2500);
    return () => clearInterval(timer);
  });

  const shortId = (id: string): string => (id.split("-").pop() ?? id).slice(-6);

  const eventCountFor = (turn: TraceTurn): number => turn.events.length;
</script>

<div class="mx-auto flex h-full w-full max-w-5xl flex-col px-5 py-8">
  <div class="flex items-center justify-between gap-4">
    <div>
      <h1 class="text-base font-semibold tracking-tight text-fg">Trace</h1>
      <p class="mt-0.5 text-xs text-fg-muted">
        The path each answer took — one ledger per turn, newest first.
      </p>
    </div>
    <div class="flex items-center gap-2">
      <label class="flex items-center gap-2 text-xs text-fg-muted">
        type
        <select
          bind:value={typeFilter}
          class="rounded-lg border border-line bg-panel px-2 py-1.5 text-xs text-fg outline-none"
        >
          <option value="">all</option>
          {#each eventTypes as eventType (eventType)}
            <option value={eventType}>{eventType}</option>
          {/each}
        </select>
      </label>
      <button
        onclick={() => void load()}
        class="grid size-8 place-items-center rounded-lg border border-line bg-raised/60 text-fg-muted transition-colors hover:text-fg"
        title="Refresh"
      >
        <RotateCw size={13} class={loading ? "animate-spin" : ""} />
      </button>
    </div>
  </div>

  <div class="mt-5 flex min-h-0 flex-1 gap-3">
    <div
      class="scroll-slim w-56 shrink-0 overflow-y-auto rounded-xl border border-line bg-panel/40 p-1.5"
    >
      {#if turns.length === 0 && orphans.length === 0}
        <p class="px-2 py-2 text-[11px] text-fg-faint">
          No turns traced yet — run one first.
        </p>
      {/if}
      {#each orphans as orphanGroup, index (index)}
        <button
          onclick={() => (selectedKey = sessionId + "/")}
          class="mb-0.5 w-full rounded-lg px-2.5 py-1.5 text-left text-[11px] transition-colors {selectedKey ===
          sessionId + '/'
            ? 'bg-raised text-fg'
            : 'text-fg-muted hover:bg-raised/50'}"
        >
          <span class="font-mono text-fg-faint">preamble</span>
          <span class="ml-1 text-fg-faint"
            >· {orphanGroup.length} events</span
          >
        </button>
      {/each}
      {#each turns as turn (turnKey(turn))}
        {@const key = turnKey(turn)}
        <button
          onclick={() => {
            selectedKey = key;
            expandedSeq = null;
          }}
          class="mb-0.5 w-full rounded-lg px-2.5 py-1.5 text-left text-[11px] transition-colors {selectedKey ===
          key
            ? 'bg-raised text-fg'
            : 'text-fg-muted hover:bg-raised/50 hover:text-fg'}"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="min-w-0 truncate font-mono text-fg"
              >{turn.turn_id}</span
            >
            <span class="shrink-0 text-fg-faint"
              >{eventCountFor(turn)} ev</span
            >
          </div>
          <div class="mt-0.5 flex items-center gap-1.5">
            <span
              class="size-1 rounded-full {turn.session_id === sessionId
                ? 'bg-accent'
                : 'bg-line-strong'}"
            ></span>
            <span class="min-w-0 truncate text-fg-faint"
              >s·{shortId(turn.session_id)}</span
            >
          </div>
        </button>
      {/each}
    </div>

    <div
      class="scroll-slim min-w-0 flex-1 overflow-y-auto rounded-xl border border-line bg-panel/40"
    >
      {#if selected === null}
        <p class="px-4 py-3 text-xs text-fg-faint">
          Select a turn to follow its path.
        </p>
      {:else}
        {#each visibleEvents as event (event.event_id)}
          <div class="border-b border-line/60 last:border-b-0">
            <button
              onclick={() => (expandedSeq = expandedSeq === event.seq ? null : event.seq)}
              class="flex w-full items-center gap-3 px-4 py-2 text-left text-xs transition-colors hover:bg-raised/50"
            >
              <span
                class="w-12 shrink-0 font-mono text-[10px] text-fg-faint"
                >#{event.seq}</span
              >
              <span class="w-44 shrink-0 truncate font-mono text-[11px] text-fg"
                >{event.type}</span
              >
              <span class="min-w-0 flex-1 truncate text-fg-faint">
                {typeof event.delta === "string"
                  ? event.delta.slice(0, 60)
                  : typeof event.prompt === "string"
                    ? event.prompt.slice(0, 60)
                    : typeof event.tool_name === "string"
                      ? event.tool_name
                      : ""}
              </span>
              <ChevronDown
                size={12}
                class="shrink-0 text-fg-faint {expandedSeq === event.seq
                  ? 'rotate-180'
                  : ''} transition-transform"
              />
            </button>
            {#if expandedSeq === event.seq}
              <pre
                class="scroll-slim mx-4 mb-2 max-h-48 overflow-auto whitespace-pre-wrap rounded-lg border border-line bg-canvas px-3 py-2.5 font-mono text-[10.5px] leading-5 text-fg-muted"
                >{JSON.stringify(event, null, 2)}</pre
              >
            {/if}
          </div>
        {/each}
        {#if visibleEvents.length === 0}
          <p class="px-4 py-3 text-xs text-fg-faint">
            No events of this type in the selected turn.
          </p>
        {/if}
      {/if}
    </div>
  </div>
</div>
