<script module lang="ts">
  export type PickerOption = {
    value: string;
    label: string;
    hint?: string;
    group?: string;
    active?: boolean;
    /** Same-page cascade: hovering the row fans these out beside it. */
    follow?: PickerOption[];
  };
</script>

<script lang="ts">
  import { Check, ChevronDown, ChevronRight, Search } from "@lucide/svelte";

  let {
    label,
    value,
    options,
    disabled = false,
    searchable = false,
    onSelect,
    onFollowSelect,
  }: {
    label: string;
    value: string;
    options: PickerOption[];
    disabled?: boolean;
    searchable?: boolean;
    onSelect: (value: string) => void;
    onFollowSelect?: (parentValue: string, value: string) => void;
  } = $props();

  let open = $state(false);
  let query = $state("");
  let rootEl: HTMLDivElement | undefined = $state();
  let followParent = $state<PickerOption | undefined>();
  let followX = $state(0);
  let followBottom = $state(0);
  let hideTimer: ReturnType<typeof setTimeout> | undefined;

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

  // The effort flyout is portaled to <body>: the menu body scrolls, so any
  // in-panel flyout would be clipped by the scroll container's overflow.
  function portal(el: HTMLElement) {
    document.body.appendChild(el);
    return {
      destroy() {
        el.remove();
      },
    };
  }

  function openFollow(option: PickerOption, el: HTMLElement) {
    if (hideTimer) {
      clearTimeout(hideTimer);
      hideTimer = undefined;
    }
    if (!option.follow || option.follow.length === 0) {
      followParent = undefined;
      return;
    }
    followParent = option;
    const rect = el.getBoundingClientRect();
    followX = rect.right + 4;
    followBottom = window.innerHeight - rect.bottom;
  }

  function scheduleCloseFollow() {
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = setTimeout(() => (followParent = undefined), 120);
  }

  function keepFollow() {
    if (hideTimer) {
      clearTimeout(hideTimer);
      hideTimer = undefined;
    }
  }

  function closeMenu() {
    open = false;
    followParent = undefined;
  }

  function openMenu() {
    query = "";
    followParent = undefined;
    open = true;
  }

  function choose(option: PickerOption) {
    closeMenu();
    onSelect(option.value);
  }

  function chooseFollow(parent: PickerOption, option: PickerOption) {
    closeMenu();
    if (onFollowSelect) {
      onFollowSelect(parent.value, option.value);
      return;
    }
    onSelect(option.value);
  }
</script>

<svelte:window
  onclick={(event) => {
    if (rootEl && !rootEl.contains(event.target as Node)) closeMenu();
  }}
  onkeydown={(event) => {
    if (event.key === "Escape") closeMenu();
  }}
/>

<div bind:this={rootEl} class="relative">
  <button
    onclick={() => (open ? closeMenu() : openMenu())}
    {disabled}
    aria-expanded={open ? "true" : "false"}
    class="flex max-w-[260px] items-center gap-1.5 rounded-lg border border-line bg-panel px-2 py-1.5 text-[11px] transition-colors hover:border-line-strong disabled:opacity-40"
    title="{label}: {value}"
  >
    <span class="shrink-0 font-mono text-fg-faint">{label}</span>
    <span class="min-w-0 truncate font-medium text-fg">{value}</span>
    <ChevronDown size={12} class="shrink-0 text-fg-faint" />
  </button>
  {#if open}
    <div
      class="animate-pop absolute bottom-full left-0 z-30 mb-1.5 w-[320px] rounded-xl border border-line-strong bg-raised shadow-[0_12px_40px_-12px_var(--shadow-color)]"
      role="listbox"
    >
      {#if searchable}
        <div class="flex items-center gap-2 border-b border-line px-3 py-2">
          <Search size={12} class="shrink-0 text-fg-faint" />
          <input
            bind:value={query}
            onkeydown={(event) => {
              if (event.key === "Enter" && filtered.length > 0) {
                choose(filtered[0]);
              }
            }}
            placeholder="Search {label}…"
            class="w-full bg-transparent text-xs text-fg outline-none placeholder:text-fg-faint"
          />
        </div>
      {/if}
      <div
        class="scroll-slim max-h-72 overflow-y-auto p-1"
        onscroll={() => (followParent = undefined)}
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
            <button
              role="option"
              aria-selected={option.active ? "true" : "false"}
              onclick={() => choose(option)}
              onmouseenter={(event) => openFollow(option, event.currentTarget)}
              onmouseleave={option.follow && option.follow.length > 0
                ? scheduleCloseFollow
                : () => (followParent = undefined)}
              class="flex w-full items-center gap-2 rounded-lg px-2.5 py-2 text-left text-xs transition-colors hover:bg-panel"
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
              {#if option.follow && option.follow.length > 0}
                <ChevronRight
                  size={12}
                  class="shrink-0 text-fg-faint opacity-0 transition-opacity hover:opacity-100"
                />
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

{#if followParent}
  <div
    use:portal
    class="fixed z-50 w-36 rounded-lg border border-line-strong bg-raised p-1 shadow-[0_12px_40px_-12px_var(--shadow-color)]"
    style="left: {followX}px; bottom: {followBottom}px;"
    role="group"
    aria-label="Effort for {followParent.label}"
    onmouseenter={keepFollow}
    onmouseleave={scheduleCloseFollow}
  >
    {#each followParent.follow as effort (effort.value)}
      <button
        aria-label="{followParent.label} · {effort.label}"
        onclick={() => chooseFollow(followParent!, effort)}
        class="flex w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-left text-xs transition-colors hover:bg-panel"
      >
        <span class="min-w-0 flex-1 truncate text-fg">{effort.label}</span>
        {#if effort.active}
          <Check size={13} class="shrink-0 text-accent" />
        {/if}
      </button>
    {/each}
  </div>
{/if}
