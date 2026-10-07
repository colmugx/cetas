<script lang="ts">
  import { Monitor, Moon, Palette, Sun } from "@lucide/svelte";
  import { probeVersions, type Versions } from "#lib/api";
  import { runtimeStore } from "#lib/runtime.svelte";
  import { themeStore, type ThemeChoice } from "#lib/theme.svelte";

  const themeOptions: Array<{
    value: ThemeChoice;
    label: string;
    icon: typeof Monitor;
  }> = [
    { value: "system", label: "System", icon: Monitor },
    { value: "light", label: "Light", icon: Sun },
    { value: "dark", label: "Dark", icon: Moon },
  ];

  let versions = $state<Versions | null>(null);
  const view = $derived(runtimeStore.activeSession());

  $effect(() => {
    void probeVersions()
      .then((value) => (versions = value))
      .catch(() => (versions = null));
  });
</script>

<div class="mx-auto w-full max-w-3xl px-5 py-8">
  <div class="flex items-center gap-2.5">
    <span
      class="grid size-8 place-items-center rounded-lg border border-line bg-raised text-fg-muted"
    >
      <Palette size={15} />
    </span>
    <div>
      <h1 class="text-base font-semibold tracking-tight text-fg">Settings</h1>
      <p class="mt-0.5 text-xs text-fg-muted">
        Workspace and model controls live where you use them — in the composer
        and the sidebar.
      </p>
    </div>
  </div>

  <div class="mt-7 space-y-2.5">
    <section
      class="flex items-center justify-between gap-4 rounded-xl border border-line bg-panel/60 px-4 py-3.5"
    >
      <div class="min-w-0">
        <div class="text-sm font-medium text-fg">Appearance</div>
        <div class="mt-0.5 truncate text-xs text-fg-muted">
          Theme follows the system by default
        </div>
      </div>
      <div class="flex shrink-0 items-center gap-0.5 rounded-lg border border-line bg-panel p-0.5">
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
            <span class="hidden sm:inline">{option.label}</span>
          </button>
        {/each}
      </div>
    </section>

    <!-- Context + usage for the active session -->
    <section class="rounded-xl border border-line bg-panel/60 px-4 py-3.5">
      <div class="flex items-center justify-between gap-4">
        <div class="text-sm font-medium text-fg">Context & usage</div>
        <span
          class="font-mono text-[10.5px] text-fg-faint"
          title={runtimeStore.activeSessionId}
        >
          {view?.model ? view.model.split("/").pop() : "no active session"}
        </span>
      </div>

      {#if view?.context && (view.context.window ?? 0) > 0}
        {@const measured = view.context.measured ?? 0}
        {@const window = view.context.window ?? 1}
        {@const percent = Math.min(100, Math.round((measured / window) * 100))}
        {@const thresholdPct = Math.round(view.context.threshold * 100)}
        <div class="mt-3">
          <div class="flex items-center justify-between text-[11px] text-fg-muted">
            <span>
              context {measured.toLocaleString()} / {window.toLocaleString()} tok
              ({percent}%)
            </span>
            <span class="text-fg-faint">
              compact at {thresholdPct}% · {view.context.messages} msgs
            </span>
          </div>
          <div class="relative mt-1.5 h-1.5 overflow-hidden rounded-full bg-canvas">
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
            <div class="text-[10px] uppercase tracking-wide text-fg-faint">
              {label}
            </div>
            <div class="font-mono text-xs text-fg">
              {typeof value === "number" ? value.toLocaleString() : value}
            </div>
          </div>
        {/each}
      </div>
      <p class="mt-3 text-[10.5px] text-fg-faint">
        Context occupancy is session-persisted; cumulative tokens accumulate
        while this console stays open.
      </p>
    </section>

    <!-- Connection state (moved from the shell chrome) -->
    <section class="rounded-xl border border-line bg-panel/60 px-4 py-3.5">
      <div class="text-sm font-medium text-fg">状态信息 · Connection</div>
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
    </section>

    <section
      class="flex items-center justify-between gap-4 rounded-xl border border-line bg-panel/60 px-4 py-3.5"
    >
      <div class="min-w-0">
        <div class="text-sm font-medium text-fg">Versions</div>
        <div class="mt-0.5 truncate text-xs text-fg-muted">
          The stack this console runs on
        </div>
      </div>
      <div class="shrink-0">
        {#if versions}
          <div class="space-y-1 text-right font-mono text-[11px] text-fg-muted">
            <div><span class="text-fg-faint">posoco </span>{versions.posoco}</div>
            <div><span class="text-fg-faint">cetas </span>{versions.cetas}</div>
            <div><span class="text-fg-faint">web </span>{versions.web}</div>
          </div>
        {:else}
          <span class="text-xs text-fg-faint">—</span>
        {/if}
      </div>
    </section>
  </div>
</div>
