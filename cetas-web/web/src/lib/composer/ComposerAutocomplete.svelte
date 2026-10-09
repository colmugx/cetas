<script lang="ts">
  import { Check } from "@lucide/svelte";
  import type { SuggestionItem } from "#lib/composer/providers";

  let {
    anchor,
    items,
    selected,
    onpick,
    onclose,
  }: {
    /** Viewport-space anchor: the dropdown hangs above this point. */
    anchor: { left: number; bottom: number };
    items: SuggestionItem[];
    selected: number;
    onpick: (item: SuggestionItem) => void;
    onclose: () => void;
  } = $props();

  // Portaled to <body>: the dropdown must overflow the composer card and
  // survive its stacking context.
  function portal(el: HTMLElement) {
    document.body.appendChild(el);
    return {
      destroy() {
        el.remove();
      },
    };
  }

  let el: HTMLElement | undefined = $state();
</script>

<svelte:window
  onresize={onclose}
  onmousedown={(event) => {
    const target = event.target as HTMLElement | null;
    if (el && !el.contains(target)) onclose();
  }}
/>

<div bind:this={el} use:portal class="contents">
  {#if items.length > 0}
    <div
      class="animate-pop fixed z-40 w-[340px] rounded-xl border border-line-strong bg-raised shadow-[0_12px_40px_-12px_var(--shadow-color)]"
      style="left: {Math.max(8, Math.min(anchor.left, window.innerWidth - 352))}px; bottom: {anchor.bottom}px;"
      role="listbox"
      aria-label="Composer suggestions"
    >
      <div class="scroll-slim max-h-64 overflow-y-auto p-1">
        {#each items as item, index (item.kind + item.label)}
          <button
            role="option"
            aria-selected={index === selected ? "true" : "false"}
            onclick={() => onpick(item)}
            onpointerenter={() => undefined}
            class="flex w-full items-center gap-2 rounded-lg px-2.5 py-2 text-left text-xs transition-colors hover:bg-panel {index ===
            selected
              ? 'bg-panel'
              : ''}"
          >
            <span class="min-w-0 flex-1 truncate text-fg">
              {item.label}
            </span>
            {#if item.detail}
              <span class="shrink-0 truncate text-[10px] text-fg-faint">
                {item.detail}
              </span>
            {/if}
            {#if index === selected}
              <Check size={13} class="shrink-0 text-accent" />
            {/if}
          </button>
        {/each}
      </div>
    </div>
  {/if}
</div>
