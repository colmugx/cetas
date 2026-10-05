<script lang="ts">
  import {
    escapeHtml,
    highlightCode,
    parseFence,
    renderMarkdownBlock,
    splitStream,
  } from "#lib/markdown";

  let { text, streaming = false }: { text: string; streaming?: boolean } =
    $props();

  const split = $derived(splitStream(text));

  let rendered = $state<Record<string, string>>({});

  $effect(() => {
    for (const block of split.blocks) {
      if (rendered[block.key] !== undefined) continue;
      void renderBlock(block).then(
        (html) => (rendered[block.key] = html),
      );
    }
  });

  async function renderBlock(block: (typeof split.blocks)[number]) {
    if (block.kind === "fence") {
      const { lang, code } = parseFence(block.text);
      try {
        return await highlightCode(code, lang);
      } catch {
        return `<pre><code>${escapeHtml(code)}</code></pre>`;
      }
    }
    return renderMarkdownBlock(block.text);
  }
</script>

<div class="md-stream text-[15px] leading-7 text-fg">
  {#each split.blocks as block (block.key)}
    {#if rendered[block.key] !== undefined}
      {@html rendered[block.key]}
    {:else}
      <div class="whitespace-pre-wrap">{block.text}</div>
    {/if}
  {/each}
  {#if split.tail.length > 0 || split.blocks.length === 0}
    <div class="whitespace-pre-wrap">
      {split.tail}{#if streaming}<span
          class="ml-1 inline-block h-4 w-[3px] translate-y-0.5 animate-caret rounded-full bg-accent align-middle"
        ></span>{/if}
    </div>
  {/if}
</div>
