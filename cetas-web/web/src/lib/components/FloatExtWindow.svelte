<script lang="ts">
  import { ChevronDown } from "@lucide/svelte";
  import { runtimeStore } from "#lib/runtime.svelte";

  let { sessionId }: { sessionId: string } = $props();

  let collapsed = $state(false);

  const view = $derived(runtimeStore.session(sessionId));
  /** Shown only for persisted sessions — a fresh chat has no zoo yet. */
  const visible = $derived(
    (runtimeStore.sessionsByWorkspace[runtimeStore.activeWorkspace] ?? []).some(
      (session) => session.id === sessionId,
    ),
  );

  const active = $derived(view?.activeExts ?? null);

  const shortName = (id: string): string =>
    id.replace(/^posoco_ext_/, "").replace(/^cetas_web_/, "");

  const isLive = (id: string): boolean => active?.has(id) ?? false;

  $effect(() => {
    if (visible && sessionId) {
      void runtimeStore.loadExts();
      void runtimeStore.refreshActiveExts(sessionId);
      const timer = setInterval(() => {
        void runtimeStore.refreshActiveExts(sessionId);
      }, 2500);
      return () => clearInterval(timer);
    }
  });
</script>

{#if visible && runtimeStore.exts && runtimeStore.exts.length > 0}
  <div
    class="fixed top-16 right-5 z-20 w-52 overflow-hidden rounded-xl border border-line-strong bg-raised/90 shadow-[0_12px_40px_-12px_var(--shadow-color)] backdrop-blur"
  >
    <button
      onclick={() => (collapsed = !collapsed)}
      class="flex w-full items-center gap-1.5 px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint transition-colors hover:text-fg"
    >
      <span class="min-w-0 flex-1">Extensions</span>
      <ChevronDown
        size={11}
        class="transition-transform {collapsed ? '' : 'rotate-180'}"
      />
    </button>
    {#if !collapsed}
      <div class="scroll-slim max-h-64 overflow-y-auto px-2.5 pb-2">
        {#each runtimeStore.exts as ext (ext.id)}
          <div class="flex items-center gap-2 rounded-md px-1 py-1">
            <span
              class="size-1.5 shrink-0 rounded-full {isLive(ext.id)
                ? 'bg-accent'
                : 'bg-line-strong'}"
              title={isLive(ext.id) ? "participating" : "idle"}
            ></span>
            <span
              class="min-w-0 flex-1 truncate font-mono text-[10.5px] {isLive(
                ext.id,
              )
                ? 'text-fg'
                : 'text-fg-faint'}"
              title={ext.id}
            >
              {shortName(ext.id)}
            </span>
          </div>
        {/each}
      </div>
    {/if}
  </div>
{/if}
