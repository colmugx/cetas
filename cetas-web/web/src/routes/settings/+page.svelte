<script lang="ts">
  import { Monitor, Moon, Palette, Sun } from "@lucide/svelte";
  import { probeVersions, type Versions } from "#lib/api";
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
