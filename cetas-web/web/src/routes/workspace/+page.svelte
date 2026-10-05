<script lang="ts">
  import { FolderTree, Search, SquareTerminal } from "@lucide/svelte";
  import { runtimeStore } from "#lib/runtime.svelte";

  const cwd = $derived(runtimeStore.runtime?.cwd || "Runtime not ready");
</script>

<div class="mx-auto w-full max-w-3xl px-5 py-8">
  <div class="flex items-center gap-2.5">
    <span
      class="grid size-8 place-items-center rounded-lg border border-line bg-raised text-fg-muted"
    >
      <FolderTree size={15} />
    </span>
    <div>
      <h1 class="text-base font-semibold tracking-tight text-fg">Workspace</h1>
      <p class="mt-0.5 text-xs text-fg-muted">
        Files, search, diffs, and tool artifacts will mount here.
      </p>
    </div>
  </div>

  <div class="mt-7 grid gap-3 md:grid-cols-2">
    <section class="rounded-xl border border-dashed border-line-strong/70 bg-panel/40 p-5">
      <div class="flex items-center gap-3">
        <span
          class="grid size-8 place-items-center rounded-lg border border-line bg-raised text-fg-faint"
        >
          <Search size={15} />
        </span>
        <div class="text-sm font-medium text-fg">File explorer</div>
      </div>
      <p class="mt-4 text-xs leading-5 text-fg-muted">
        Waiting for the workspace HTTP surface.
      </p>
    </section>
    <section class="rounded-xl border border-dashed border-line-strong/70 bg-panel/40 p-5">
      <div class="flex items-center gap-3">
        <span
          class="grid size-8 place-items-center rounded-lg border border-line bg-raised text-fg-faint"
        >
          <SquareTerminal size={15} />
        </span>
        <div class="text-sm font-medium text-fg">Working directory</div>
      </div>
      <p class="mt-4 break-words font-mono text-xs leading-5 text-fg-muted">
        {cwd}
      </p>
    </section>
  </div>
</div>
