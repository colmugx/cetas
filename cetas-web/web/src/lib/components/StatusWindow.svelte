<script lang="ts">
  import { tick } from "svelte";
  import { ArrowUpRight, RotateCw } from "@lucide/svelte";
  import { runtimeStore } from "#lib/runtime.svelte";
  import type { QuotaReading } from "#lib/runtime.svelte";

  const view = $derived(runtimeStore.activeSession());
  const quota = $derived(view?.quota ?? null);
  const quotaAll = $derived(view?.quotaAll ?? []);

  let refreshing = $state(false);
  let expanded = $state(false);
  let expanding = false;
  /** Collapsed-card layer visibility — fades are ≥300ms and strictly
   *  sequenced: fadeout → morph → fadein, never overlapping the morph. */
  let contentShown = $state(true);
  let gridShown = $state(false);
  let cardEl: HTMLDivElement | undefined = $state();

  function refresh() {
    if (refreshing) return;
    refreshing = true;
    runtimeStore.refreshQuota();
    setTimeout(() => (refreshing = false), 1500);
  }

  // A provider switch changes which quota source is authoritative — pull it.
  let previousModel: string | undefined;
  $effect(() => {
    const model = view?.model;
    if (previousModel !== undefined && model !== previousModel) {
      runtimeStore.refreshQuota();
    }
    previousModel = model;
  });
  // First sighting of a session pulls the strip once; later updates are
  // refresh-button or provider-switch driven.
  $effect(() => {
    if (view !== undefined && view.quota === null) {
      runtimeStore.refreshQuota();
    }
  });

  /** Provider display name from the active slot's label — data, not branches:
   *  "OpenAI / gpt-6.1-sol" → "OpenAI"; "zai-coding-plan" → "Zai Coding Plan". */
  function providerDisplayName(providerId: string): string {
    const slot = runtimeStore.catalog?.slots.find(
      (candidate) => candidate.provider === providerId,
    );
    const fromLabel = slot?.label.split("/")[0]?.trim();
    if (fromLabel) return fromLabel;
    return providerId
      .replace(/[_-]/g, " ")
      .trim()
      .split(" ")
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join(" ");
  }

  const providerName = $derived.by(() => {
    const slot = runtimeStore.catalog?.slots.find(
      (candidate) => candidate.id === (view?.model ?? ""),
    );
    if (!slot) return null;
    return providerDisplayName(slot.provider);
  });

  /** Readings carry used_percent — the UI speaks in REMAINING capacity. */
  const remainingOf = (reading: QuotaReading): number | null =>
    reading.used_percent === null
      ? null
      : Math.max(0, Math.min(100, 100 - reading.used_percent));

  const RING_LEN = 2 * Math.PI * 19;
  /** 270° gauge: the gap sits at the bottom, 0% at the left terminal
   *  filling clockwise to 100% at the right terminal. */
  const ARC_LEN = RING_LEN * 0.75;

  // The card portals to <body>: the expanded panel intentionally overflows
  // the sidebar, whose overflow-hidden would clip an in-place child.
  function portal(el: HTMLElement) {
    document.body.appendChild(el);
    return {
      destroy() {
        el.remove();
      },
    };
  }

  /** Expand covers a 3× surface, so it earns a longer breath than the
   *  usual UI budget; the collapse snaps home. */
  const MORPH_EXPAND_MS = 400;
  const MORPH_COLLAPSE_MS = 300;
  const GRID_FADE_MS = 200;
  const FADE_MS = 300;
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  /** Breath morph (WAAPI, compositor-only): the frame first contracts a
   *  hair, then blooms to full size on a strong ease-out — 收 then 展.
   *  Content layers fade around it, so no readable text is ever stretched.
   *  Reduced motion swaps the size instantly and keeps the fades. */
  function morph(target: boolean): Promise<void> {
    return new Promise((resolve) => {
      const el = cardEl;
      if (!el) {
        expanded = target;
        resolve();
        return;
      }
      const settle = (anim?: Animation) => {
        anim?.cancel();
        resolve();
      };
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        expanded = target;
        void tick().then(() => resolve());
        return;
      }
      const first = el.getBoundingClientRect();
      expanded = target;
      void tick().then(() => {
        const last = el.getBoundingClientRect();
        const sx = first.width / last.width;
        const sy = first.height / last.height;
        const frames =
          target === true
            ? [
                {
                  transform: `scale(${sx}, ${sy})`,
                  easing: "cubic-bezier(0.77, 0, 0.175, 1)",
                },
                {
                  transform: `scale(${sx * 0.94}, ${sy * 0.94})`,
                  offset: 0.3,
                  easing: "cubic-bezier(0.23, 1, 0.32, 1)",
                },
                { transform: "scale(1, 1)" },
              ]
            : [
                // Collapse: the layout is already card-sized, so the morph
                // starts inflated (scale = expanded/card) and settles home.
                {
                  transform: `scale(${sx}, ${sy})`,
                  easing: "cubic-bezier(0.23, 1, 0.32, 1)",
                },
                { transform: "scale(1, 1)" },
              ];
        const anim = el.animate(frames, {
          duration: target ? MORPH_EXPAND_MS : MORPH_COLLAPSE_MS,
          fill: "both",
        });
        anim.finished.then(
          () => settle(anim),
          () => settle(anim),
        );
      });
    });
  }

  // The expanded panel overlaps the composer on narrow screens — a click
  // anywhere outside it collapses back to the card immediately.
  function onWindowPointerDown(event: MouseEvent) {
    if (!expanded || !cardEl) return;
    if (!cardEl.contains(event.target as Node)) {
      expanded = false;
      contentShown = true;
      gridShown = false;
      expanding = false;
    }
  }

  async function toggleExpand() {
    if (expanding) return;
    expanding = true;
    if (!expanded) {
      // The fadeout breathes with the extend — parallel, not sequential.
      contentShown = false;
      await morph(true);
      gridShown = true;
      await sleep(GRID_FADE_MS + quotaAll.length * 40);
    } else {
      // Mirror of expand: hide the grid first, then the empty frame
      // settles home, then the card content fades in.
      gridShown = false;
      await sleep(GRID_FADE_MS);
      await morph(false);
      contentShown = true;
      await sleep(GRID_FADE_MS);
    }
    expanding = false;
  }
</script>

{#snippet ringStat(remaining: number, label: string)}
  <div class="flex flex-col items-center gap-1">
    <div class="relative size-11">
      <svg viewBox="0 0 44 44" class="size-11">
        <circle
          cx="22"
          cy="22"
          r="19"
          fill="none"
          stroke-width="3.5"
          stroke-dasharray={`${ARC_LEN} ${RING_LEN}`}
          transform="rotate(135 22 22)"
          class="stroke-line"
        ></circle>
        <circle
          cx="22"
          cy="22"
          r="19"
          fill="none"
          stroke-width="3.5"
          stroke-linecap="round"
          stroke-dasharray={`${ARC_LEN} ${RING_LEN}`}
          stroke-dashoffset={ARC_LEN * (1 - remaining / 100)}
          transform="rotate(135 22 22)"
          class="motion-safe:transition-[stroke-dashoffset] motion-safe:duration-300 {remaining <= 10
            ? 'stroke-warn'
            : 'stroke-accent/80'}"
        ></circle>
      </svg>
      <span
        class="absolute inset-0 grid place-items-center pb-1 font-mono text-[10px] {remaining <= 10
          ? 'text-warn'
          : 'text-fg'}"
      >
        {Math.round(remaining)}%
      </span>
    </div>
    <span class="text-[10px] uppercase tracking-wide text-fg-faint">
      {label}
    </span>
  </div>
{/snippet}

{#snippet numberStat(value: string, label: string)}
  <div class="flex flex-col items-center gap-1">
    <span class="grid size-11 place-items-center font-mono text-sm text-fg">
      {value}
    </span>
    <span class="text-[10px] uppercase tracking-wide text-fg-faint">
      {label}
    </span>
  </div>
{/snippet}

{#snippet stats(readings: QuotaReading[])}
  <div class="flex items-start justify-around">
    {#each readings as reading (reading.window)}
      {@const remaining = remainingOf(reading)}
      {#if remaining !== null}
        {@render ringStat(remaining, reading.window)}
      {:else if reading.amount}
        {@render numberStat(reading.amount.value, reading.amount.currency)}
      {:else if reading.available !== null}
        {@render numberStat(reading.available ? "ok" : "—", reading.window)}
      {/if}
    {/each}
  </div>
{/snippet}

<svelte:window onmousedown={onWindowPointerDown} />

{#if providerName !== null}
  <div use:portal class="fixed bottom-3 left-3 z-30 hidden lg:block">
    <div
      bind:this={cardEl}
      class="group/card relative origin-bottom-left overflow-hidden rounded-xl border border-line bg-raised/95 shadow-[0_12px_40px_-12px_var(--shadow-color)] backdrop-blur {expanded
        ? 'h-[440px] w-[736px]'
        : 'h-[112px] w-56'}"
    >
      <button
        onclick={toggleExpand}
        class="absolute top-1.5 right-1.5 z-10 rounded-md p-1 text-fg-faint transition-opacity hover:bg-panel hover:text-fg {expanded
          ? 'opacity-100'
          : 'opacity-0 group-hover/card:opacity-100'}"
        title={expanded ? "Collapse" : "Expand"}
      >
        <ArrowUpRight
          size={13}
          class="transition-transform duration-200 {expanded ? 'rotate-180' : ''}"
        />
      </button>
      <div
        class="absolute inset-0 flex flex-col p-3 transition-opacity duration-300 {contentShown
          ? 'opacity-100'
          : 'pointer-events-none opacity-0'}"
      >
        <div class="flex items-center gap-1.5">
          <span
            class="truncate text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint"
          >
            {providerName}
          </span>
          <button
            onclick={refresh}
            class="rounded p-0.5 text-fg-faint transition-colors hover:text-fg"
            title="Refresh quota"
          >
            <RotateCw size={10} class={refreshing ? "animate-spin" : ""} />
          </button>
        </div>
        {#if quota && quota.readings.length > 0}
          <div class="mt-2.5">
            {@render stats(quota.readings)}
          </div>
        {:else}
          <p class="mt-4 text-[11px] text-fg-faint">No quota reported.</p>
        {/if}
      </div>
      <div
        class="absolute inset-0 flex flex-col transition-opacity duration-300 {gridShown
          ? 'opacity-100'
          : 'pointer-events-none opacity-0'}"
      >
        <div class="flex h-10 shrink-0 items-center border-b border-line px-4">
          <span
            class="text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint"
          >
            Quota
          </span>
        </div>
        <div
          class="grid flex-1 grid-cols-3 content-start gap-4 overflow-y-auto p-4"
        >
          {#each quotaAll as entry, i (entry.provider)}
            <div
              class="h-[112px] rounded-xl border border-line bg-raised p-3 shadow-[0_6px_20px_-8px_var(--shadow-color)] transition-opacity duration-200 ease-out {gridShown
                ? 'opacity-100'
                : 'opacity-0'}"
              style="transition-delay: {gridShown ? i * 40 : 0}ms"
            >
              <div
                class="truncate text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint"
              >
                {providerDisplayName(entry.provider)}
              </div>
              {#if entry.readings.length > 0}
                <div class="mt-1.5">
                  {@render stats(entry.readings)}
                </div>
              {:else}
                <p class="mt-3 text-[11px] text-fg-faint">
                  No quota reported.
                </p>
              {/if}
            </div>
          {/each}
          {#if quotaAll.length === 0}
            <div class="p-3 text-[11px] text-fg-faint">
              No quota providers.
            </div>
          {/if}
        </div>
      </div>
    </div>
  </div>
{/if}
