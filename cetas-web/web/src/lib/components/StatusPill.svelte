<script lang="ts">
  import type { Snippet } from "svelte";

  type Tone = "neutral" | "good" | "warn" | "bad";

  let {
    children,
    tone = "neutral",
    pulse = false,
    dot = true,
  }: {
    children: Snippet;
    tone?: Tone;
    pulse?: boolean;
    dot?: boolean;
  } = $props();

  const toneClass: Record<Tone, string> = {
    neutral: "border-line bg-raised/70 text-fg-muted",
    good: "border-accent/25 bg-accent-dim text-accent",
    warn: "border-warn/25 bg-warn/10 text-warn",
    bad: "border-bad/25 bg-bad/10 text-bad",
  };
</script>

<span
  class="inline-flex h-6 items-center gap-1.5 rounded-full border px-2.5 text-[11px] font-medium {toneClass[tone]}"
>
  {#if dot}
    <span
      class="size-1.5 rounded-full bg-current {pulse ? 'animate-breathe' : 'opacity-80'}"
    ></span>
  {/if}
  {@render children()}
</span>
