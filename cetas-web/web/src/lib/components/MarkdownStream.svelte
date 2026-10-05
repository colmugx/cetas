<script lang="ts">
  import { MarkdownRender } from "markstream-svelte";
  import "markstream-svelte/index.css";
  import { themeStore } from "#lib/theme.svelte";

  let {
    content,
    final = true,
    streaming = false,
  }: { content: string; final?: boolean; streaming?: boolean } = $props();
</script>

<div class="md-live" data-streaming={streaming ? "true" : "false"}>
  <MarkdownRender content={content} {final} isDark={themeStore.isDark} htmlPolicy="safe" />
</div>
