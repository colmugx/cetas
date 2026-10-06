<script lang="ts">
  import { X } from "@lucide/svelte";
  import { fly } from "svelte/transition";
  import { toastStore } from "#lib/toast.svelte";

  const tone: Record<string, string> = {
    info: "border-line-strong text-fg",
    success: "border-accent/40 text-fg",
    error: "border-bad/40 text-bad",
  };
</script>

<div class="pointer-events-none fixed right-5 bottom-5 z-50 flex w-80 flex-col gap-2">
  {#each toastStore.toasts as entry (entry.id)}
    <div
      transition:fly={{ y: 8, duration: 150 }}
      class="pointer-events-auto flex items-start gap-2.5 rounded-xl border bg-raised px-3.5 py-3 text-xs leading-5 shadow-[0_12px_40px_-12px_var(--shadow-color)] {tone[
        entry.kind
      ]}"
      role="status"
    >
      <span class="min-w-0 flex-1">{entry.text}</span>
      <button
        onclick={() => toastStore.dismiss(entry.id)}
        class="shrink-0 rounded p-0.5 text-fg-faint transition-colors hover:text-fg"
        title="Dismiss"
      >
        <X size={11} />
      </button>
    </div>
  {/each}
</div>
