<script lang="ts">
  import { Monitor, Moon, Sun, X } from "@lucide/svelte";
  import { probeVersions, type Versions } from "#lib/api";
  import { runtimeStore } from "#lib/runtime.svelte";
  import { themeStore, type ThemeChoice } from "#lib/theme.svelte";

  let { onclose }: { onclose: () => void } = $props();

  type SectionId = "providers" | "appearance" | "usage" | "connection" | "versions";
  const sections: Array<{ id: SectionId; label: string }> = [
    { id: "providers", label: "Providers" },
    { id: "appearance", label: "Appearance" },
    { id: "usage", label: "Context & usage" },
    { id: "connection", label: "Connection" },
    { id: "versions", label: "Versions" },
  ];
  let section = $state<SectionId>("providers");

  const themeOptions: Array<{
    value: ThemeChoice;
    label: string;
    icon: typeof Monitor;
  }> = [
    { value: "system", label: "System", icon: Monitor },
    { value: "light", label: "Light", icon: Sun },
    { value: "dark", label: "Dark", icon: Moon },
  ];

  const view = $derived(runtimeStore.activeSession());

  let versions = $state<Versions | null>(null);
  $effect(() => {
    void probeVersions()
      .then((value) => (versions = value))
      .catch(() => (versions = null));
  });

  type ProviderTab = {
    provider: string;
    label: string;
    models: Array<{
      id: string;
      label: string;
      efforts: string[];
      active: boolean;
    }>;
  };
  let activeProvider = $state("");
  const providerTabs = $derived.by<ProviderTab[]>(() => {
    const byProvider = new Map<string, ProviderTab>();
    for (const slot of runtimeStore.catalog?.slots ?? []) {
      let tab = byProvider.get(slot.provider);
      if (!tab) {
        tab = {
          provider: slot.provider,
          label: (slot.label.split("/")[0] ?? slot.provider).trim(),
          models: [],
        };
        byProvider.set(slot.provider, tab);
      }
      tab.models.push({
        id: slot.id,
        label: slot.label || slot.id,
        efforts: slot.efforts,
        active: slot.id === (view?.model ?? ""),
      });
    }
    return [...byProvider.values()];
  });
  const currentProviderTab = $derived(
    providerTabs.find((tab) => tab.provider === activeProvider) ??
      providerTabs[0] ??
      null,
  );

  function onkeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onclose();
    }
  }
</script>

<svelte:window onkeydown={onkeydown} />

<div
  class="fixed inset-0 z-40 grid place-items-center bg-black/50 backdrop-blur-sm"
  role="presentation"
  onclick={(event) => {
    if (event.target === event.currentTarget) onclose();
  }}
>
  <div
    class="flex h-[560px] w-[860px] max-w-[92vw] overflow-hidden rounded-2xl border border-line-strong bg-raised shadow-[0_12px_40px_-12px_var(--shadow-color)]"
    role="dialog"
    aria-label="Settings"
  >
    <nav
      class="flex w-44 shrink-0 flex-col gap-0.5 border-r border-line bg-panel/60 p-3"
    >
      <div
        class="px-2 pb-2 text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint"
      >
        Settings
      </div>
      {#each sections as item (item.id)}
        <button
          onclick={() => (section = item.id)}
          class="rounded-lg px-2.5 py-1.5 text-left text-[13px] transition-colors {section ===
          item.id
            ? 'bg-raised text-fg'
            : 'text-fg-muted hover:bg-raised/50 hover:text-fg'}"
        >
          {item.label}
        </button>
      {/each}
    </nav>

    <div class="relative flex min-w-0 flex-1 flex-col">
      <button
        onclick={onclose}
        class="absolute top-3 right-3 rounded-md p-1 text-fg-faint transition-colors hover:bg-panel hover:text-fg"
        title="Close settings"
      >
        <X size={14} />
      </button>
      <div class="scroll-slim min-h-0 flex-1 overflow-y-auto p-5">
        {#if section === "providers"}
          <div class="text-sm font-medium text-fg">Providers</div>
          <p class="mt-0.5 text-xs text-fg-muted">
            Switching providers happens in the composer's model picker; this is
            the inventory of what each provider exposes.
          </p>
          {#if providerTabs.length > 0}
            <div
              class="scroll-slim mt-3 flex items-center gap-1 overflow-x-auto border-b border-line pb-2.5"
              role="tablist"
            >
              {#each providerTabs as tab (tab.provider)}
                <button
                  role="tab"
                  aria-selected={currentProviderTab?.provider === tab.provider
                    ? "true"
                    : "false"}
                  onclick={() => (activeProvider = tab.provider)}
                  class="shrink-0 rounded-lg px-2.5 py-1.5 text-xs transition-colors {currentProviderTab?.provider ===
                  tab.provider
                    ? 'bg-raised text-fg'
                    : 'text-fg-muted hover:bg-raised/50 hover:text-fg'}"
                >
                  {tab.label}
                </button>
              {/each}
            </div>
            {#if currentProviderTab}
              <div class="mt-3 space-y-1">
                {#each currentProviderTab.models as model (model.id)}
                  <div
                    class="flex items-center justify-between gap-3 rounded-lg px-2 py-1.5 text-xs {model.active
                      ? 'bg-raised'
                      : ''}"
                  >
                    <span
                      class="min-w-0 truncate {model.active
                        ? 'font-medium text-fg'
                        : 'text-fg-muted'}"
                    >
                      {model.label}
                    </span>
                    <span
                      class="shrink-0 font-mono text-[10px] text-fg-faint"
                    >
                      {model.efforts.length > 0
                        ? model.efforts.join(" · ")
                        : "—"}
                    </span>
                  </div>
                {/each}
              </div>
            {/if}
          {:else}
            <p class="mt-3 text-xs text-fg-faint">
              No providers in the composed catalog yet.
            </p>
          {/if}
        {:else if section === "appearance"}
          <div class="text-sm font-medium text-fg">Appearance</div>
          <p class="mt-0.5 text-xs text-fg-muted">
            Theme follows the system by default
          </p>
          <div
            class="mt-4 flex items-center gap-0.5 rounded-lg border border-line bg-panel p-0.5"
          >
            {#each themeOptions as option (option.value)}
              <button
                onclick={() => themeStore.setChoice(option.value)}
                class="flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium transition-colors {themeStore.choice ===
                option.value
                  ? 'bg-raised text-fg shadow-sm'
                  : 'text-fg-muted hover:text-fg'}"
                title="{option.label} theme"
              >
                <option.icon size={13} />
                <span>{option.label}</span>
              </button>
            {/each}
          </div>
        {:else if section === "usage"}
          <div class="flex items-center justify-between gap-4">
            <div class="text-sm font-medium text-fg">Context & usage</div>
            <span
              class="font-mono text-[10.5px] text-fg-faint"
              title={runtimeStore.activeSessionId}
            >
              {view?.model
                ? view.model.split("/").pop()
                : "no active session"}
            </span>
          </div>
          {#if view?.context && (view.context.window ?? 0) > 0}
            {@const measured = view.context.measured ?? 0}
            {@const window = view.context.window ?? 1}
            {@const percent = Math.min(
              100,
              Math.round((measured / window) * 100),
            )}
            {@const thresholdPct = Math.round(view.context.threshold * 100)}
            <div class="mt-3">
              <div
                class="flex items-center justify-between text-[11px] text-fg-muted"
              >
                <span>
                  context {measured.toLocaleString()} /
                  {window.toLocaleString()} tok ({percent}%)
                </span>
                <span class="text-fg-faint">
                  compact at {thresholdPct}% · {view.context.messages} msgs
                </span>
              </div>
              <div
                class="relative mt-1.5 h-1.5 overflow-hidden rounded-full bg-canvas"
              >
                <div
                  class="h-full rounded-full {percent >= thresholdPct
                    ? 'bg-warn'
                    : 'bg-accent'}"
                  style="width: {percent}%"
                ></div>
                <div
                  class="absolute top-0 h-full w-0.5 bg-warn/70"
                  style="left: {thresholdPct}%"
                ></div>
              </div>
            </div>
          {:else}
            <p class="mt-3 text-xs text-fg-faint">
              Run a turn to measure context occupancy.
            </p>
          {/if}
          <div class="mt-4 grid grid-cols-2 gap-x-6 gap-y-1.5 sm:grid-cols-4">
            {#each [["input", view?.usage.input ?? 0], ["output", view?.usage.output ?? 0], ["cached in", view?.usage.cached ?? 0], ["requests", view?.usage.requests ?? 0]] as [label, value] (label)}
              <div>
                <div
                  class="text-[10px] uppercase tracking-wide text-fg-faint"
                >
                  {label}
                </div>
                <div class="font-mono text-xs text-fg">
                  {typeof value === "number" ? value.toLocaleString() : value}
                </div>
              </div>
            {/each}
          </div>
          <p class="mt-3 text-[10.5px] text-fg-faint">
            Context occupancy is session-persisted; cumulative tokens
            accumulate while this console stays open.
          </p>
        {:else if section === "connection"}
          <div class="text-sm font-medium text-fg">Connection</div>
          <div class="mt-3 space-y-2">
            {#each [["api", runtimeStore.http], ["realtime", runtimeStore.socketState], ["core", runtimeStore.core]] as [label, value] (label)}
              <div class="flex items-center justify-between text-xs">
                <span class="text-fg-muted">{label}</span>
                <span class="flex items-center gap-1.5">
                  <span
                    class="inline-block size-1.5 rounded-full {value === 'online' ||
                    value === 'ready'
                      ? 'bg-accent'
                      : value === 'offline'
                        ? 'bg-bad'
                        : 'bg-warn animate-breathe'}"
                  ></span>
                  <span class="font-mono text-fg">{value}</span>
                </span>
              </div>
            {/each}
          </div>
        {:else}
          <div class="text-sm font-medium text-fg">Versions</div>
          <p class="mt-0.5 text-xs text-fg-muted">
            The stack this console runs on
          </p>
          <div class="mt-3 space-y-1 font-mono text-[11px] text-fg-muted">
            <div><span class="text-fg-faint">posoco </span>{versions?.posoco ?? "—"}</div>
            <div><span class="text-fg-faint">cetas </span>{versions?.cetas ?? "—"}</div>
            <div><span class="text-fg-faint">web </span>{versions?.web ?? "—"}</div>
          </div>
        {/if}
      </div>
    </div>
  </div>
</div>
