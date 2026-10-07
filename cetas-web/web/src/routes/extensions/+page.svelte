<script lang="ts">
  import { ChevronDown, Layers } from "@lucide/svelte";
  import { listExts, type ExtInfo } from "#lib/api";

  let extensions = $state<ExtInfo[] | null>(null);
  let error = $state("");

  const shortId = (id: string): string => id.replace(/^posoco_ext_/, "");

  $effect(() => {
    void listExts()
      .then((zoo) => (extensions = zoo.extensions))
      .catch((err) => (error = String(err)));
  });
</script>

<div class="mx-auto w-full max-w-3xl px-5 py-8">
  <div class="flex items-center gap-2.5">
    <span
      class="grid size-8 place-items-center rounded-lg border border-line bg-raised text-fg-muted"
    >
      <Layers size={15} />
    </span>
    <div>
      <h1 class="text-base font-semibold tracking-tight text-fg">Extensions</h1>
      <p class="mt-0.5 text-xs text-fg-muted">
        Every posoco-ext composed into this workspace's agent — expand a blind
        to see each port role it fills and what that port provides.
      </p>
    </div>
  </div>

  {#if error}
    <p
      class="mt-6 rounded-xl border border-bad/25 bg-bad/10 px-4 py-3 text-xs text-bad"
    >
      {error}
    </p>
  {:else if extensions === null}
    <p class="mt-6 text-xs text-fg-faint">Loading the zoo…</p>
  {:else}
    <div class="mt-7 space-y-1.5">
      {#each extensions as ext (ext.id)}
        <details class="group rounded-xl border border-line bg-panel/60">
          <summary
            class="flex cursor-pointer select-none items-center gap-3 px-4 py-3 [&::-webkit-details-marker]:hidden"
          >
            <span class="min-w-0 flex-1 truncate font-mono text-xs text-fg">
              {ext.id}
            </span>
            <div class="flex shrink-0 gap-1">
              {#each ext.roles as role (role.role)}
                <span
                  class="rounded-md border border-line bg-raised px-1.5 py-0.5 font-mono text-[9.5px] text-fg-faint"
                  >{role.role}·{role.count}</span
                >
              {/each}
            </div>
            <ChevronDown
              size={13}
              class="shrink-0 text-fg-faint transition-transform group-open:rotate-180"
            />
          </summary>

          <div class="border-t border-line px-4 py-3.5">
            {#each ext.roles as role, roleIndex (role.role)}
              <!-- h2: port role; h3: capability items -->
              <h2
                class="mb-1.5 text-[11px] font-semibold uppercase tracking-[0.14em] text-fg {roleIndex >
                0
                  ? 'mt-4'
                  : ''}"
              >
                {role.role}
                <span class="ml-1 font-mono text-[9.5px] text-fg-faint"
                  >×{role.count}</span
                >
              </h2>
              {#if role.items.length > 0}
                <div class="space-y-1">
                  {#each role.items as item (item.label)}
                    <h3 class="flex items-baseline gap-2.5 text-xs font-normal">
                      <span class="shrink-0 font-mono text-[11px] text-fg">
                        {item.label}
                      </span>
                      {#if item.detail}
                        <span class="min-w-0 flex-1 truncate text-fg-muted">
                          {item.detail}
                        </span>
                      {/if}
                    </h3>
                  {/each}
                </div>
              {:else}
                <p class="text-fg-faint">
                  Port slot filled — the contract exposes no further details.
                </p>
              {/if}
            {/each}
          </div>
        </details>
      {/each}
    </div>
    <p class="mt-4 font-mono text-[10.5px] text-fg-faint">
      {extensions.length} extensions · read from live manifests via port
      contracts only
    </p>
  {/if}
</div>
