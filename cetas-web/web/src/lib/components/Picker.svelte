<script lang="ts">
  import { Check, ChevronDown, Search } from "@lucide/svelte";

  export type PickerOption = {
    value: string;
    label: string;
    hint?: string;
    group?: string;
    active?: boolean;
  };

  let {
    label,
    value,
    options,
    disabled = false,
    searchable = false,
    onSelect,
  }: {
    label: string;
    value: string;
    options: PickerOption[];
    disabled?: boolean;
    searchable?: boolean;
    onSelect: (value: string) => void;
  } = $props();

  let open = $state(false);
  let query = $state("");
  let cursor = $state(0);
  let rootEl: HTMLDivElement | undefined = $state();
  let searchEl: HTMLInputElement | undefined = $state();
  let listEl: HTMLDivElement | undefined = $state();

  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    if (!q) return options;
    return options.filter(
      (option) =>
        option.label.toLowerCase().includes(q) ||
        (option.group ?? "").toLowerCase().includes(q) ||
        (option.hint ?? "").toLowerCase().includes(q),
    );
  });

  const groups = $derived.by(() => {
    const map = new Map<string, PickerOption[]>();
    for (const option of filtered) {
      const key = option.group ?? "";
      const bucket = map.get(key);
      if (bucket) {
        bucket.push(option);
      } else {
        map.set(key, [option]);
      }
    }
    return [...map.entries()];
  });

  function openMenu() {
    query = "";
    const activeIndex = options.findIndex((option) => option.active);
    cursor = activeIndex >= 0 ? activeIndex : 0;
    open = true;
  }

  function choose(option: PickerOption) {
    onSelect(option.value);
    open = false;
  }

  function onListKey(event: KeyboardEvent) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      cursor = Math.min(cursor + 1, filtered.length - 1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      cursor = Math.max(cursor - 1, 0);
    } else if (event.key === "Enter") {
      event.preventDefault();
      const option = filtered[cursor];
      if (option) choose(option);
    }
  }

  $effect(() => {
    if (open) searchEl?.focus();
  });

  $effect(() => {
    listEl
      ?.querySelector(`[data-index="${cursor}"]`)
      ?.scrollIntoView({ block: "nearest" });
  });
</script>

<svelte:window
  onclick={(event) => {
    if (rootEl && !rootEl.contains(event.target as Node)) open = false;
  }}
  onkeydown={(event) => {
    if (event.key === "Escape") open = false;
  }}
/>

<div bind:this={rootEl} class="relative">
  <button
    onclick={() => (open ? (open = false) : openMenu())}
    {disabled}
    aria-expanded={open ? "true" : "false"}
    class="flex max-w-[220px] items-center gap-1.5 rounded-lg border border-line bg-panel px-2 py-1.5 text-[11px] transition-colors hover:border-line-strong disabled:opacity-40"
    title="{label}: {value}"
  >
    <span class="shrink-0 font-mono text-fg-faint">{label}</span>
    <span class="min-w-0 truncate font-medium text-fg">{value}</span>
    <ChevronDown size={12} class="shrink-0 text-fg-faint" />
  </button>
  {#if open}
    <div
      class="animate-pop absolute bottom-full left-0 z-30 mb-1.5 w-[300px] overflow-hidden rounded-xl border border-line-strong bg-raised shadow-[0_12px_40px_-12px_var(--shadow-color)]"
      role="listbox"
    >
      {#if searchable}
        <div class="flex items-center gap-2 border-b border-line px-3 py-2">
          <Search size={12} class="shrink-0 text-fg-faint" />
          <input
            bind:this={searchEl}
            bind:value={query}
            oninput={() => (cursor = 0)}
            onkeydown={onListKey}
            placeholder="Search {label}…"
            class="w-full bg-transparent text-xs text-fg outline-none placeholder:text-fg-faint"
          />
        </div>
      {/if}
      <div
        bind:this={listEl}
        onkeydown={onListKey}
        role="presentation"
        class="scroll-slim max-h-72 overflow-y-auto p-1"
      >
        {#each groups as [groupName, groupOptions] (groupName)}
          {#if groupName}
            <div
              class="px-2.5 pb-1 pt-2 font-mono text-[10px] uppercase tracking-wide text-fg-faint"
            >
              {groupName}
            </div>
          {/if}
          {#each groupOptions as option (option.value)}
            {@const index = options.indexOf(option)}
            <button
              data-index={index}
              role="option"
              aria-selected={option.active ? "true" : "false"}
              onclick={() => choose(option)}
              onmouseenter={() => (cursor = index)}
              class="flex w-full items-center gap-2 rounded-lg px-2.5 py-2 text-left text-xs transition-colors {cursor ===
              index
                ? 'bg-panel'
                : ''}"
            >
              <span class="min-w-0 flex-1 truncate text-fg">
                {option.label}
              </span>
              {#if option.hint}
                <span class="shrink-0 font-mono text-[10px] text-fg-faint">
                  {option.hint}
                </span>
              {/if}
              {#if option.active}
                <Check size={13} class="shrink-0 text-accent" />
              {/if}
            </button>
          {/each}
        {/each}
        {#if filtered.length === 0}
          <p class="px-2.5 py-3 text-xs text-fg-faint">No matches.</p>
        {/if}
      </div>
    </div>
  {/if}
</div>
