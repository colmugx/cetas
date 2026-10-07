<script lang="ts">
  import { runtimeStore } from "#lib/runtime.svelte";

  /** Segment keys rendered elsewhere (composer dock / pickers). */
  const covered = new Set([
    "permission",
    "model",
    "turns",
    "steps",
    "ttft",
    "tps",
    "avg",
    "cache",
    "ctx",
  ]);

  const view = $derived(runtimeStore.activeSession());
  const rows = $derived(
    (view?.statusSegments ?? []).filter((segment) => !covered.has(segment.key)),
  );

  /** Provider display name from the active slot's label — data, not branches:
   *  "OpenAI / gpt-6.1-sol" → "OpenAI"; "DeepSeek / chat" → "DeepSeek". */
  const providerName = $derived.by(() => {
    const slot = runtimeStore.catalog?.slots.find(
      (candidate) => candidate.id === (view?.model ?? ""),
    );
    const fromLabel = slot?.label.split("/")[0]?.trim();
    if (fromLabel) return fromLabel;
    const fromProvider = slot?.provider.replace(/[_-]/g, " ").trim();
    if (fromProvider) {
      return fromProvider
        .split(" ")
        .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
        .join(" ");
    }
    return null;
  });

  /** Percent embedded in a pushed value ("91% left") drives the bar fill. */
  const percentOf = (value: string): number | null => {
    const match = /(\d{1,3})\s*%/.exec(value);
    if (!match) return null;
    const parsed = Number(match[1]);
    return Number.isNaN(parsed) ? null : Math.max(0, Math.min(100, parsed));
  };
</script>

{#if rows.length > 0}
  <div class="shrink-0 p-3">
    <div class="rounded-xl border border-line bg-raised/40 p-3">
      <div
        class="mb-2.5 flex items-center justify-between text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint"
      >
        <span class="truncate">
          {providerName ?? "Provider"} Status
        </span>
      </div>
      <div class="space-y-2.5">
        {#each rows as row (row.key)}
          {@const percent = percentOf(row.value)}
          <div>
            <div
              class="flex items-center justify-between gap-2 text-[11px] text-fg-muted"
            >
              <span class="min-w-0 truncate">{row.key}</span>
              <span
                class="shrink-0 font-mono"
                style={row.color ? `color: ${row.color}` : ""}
              >
                {row.value}
              </span>
            </div>
            {#if percent !== null}
              <div
                class="relative mt-1 h-1 overflow-hidden rounded-full bg-canvas"
              >
                <div
                  class="h-full rounded-full {percent >= 90
                    ? 'bg-warn'
                    : 'bg-accent/70'}"
                  style="width: {percent}%"
                ></div>
              </div>
            {/if}
          </div>
        {/each}
      </div>
    </div>
  </div>
{/if}
