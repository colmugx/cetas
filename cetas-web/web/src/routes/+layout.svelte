<script lang="ts">
  import "../app.css";
  import AppShell from "#lib/components/AppShell.svelte";
  import { themeStore } from "#lib/theme.svelte";

  let { children } = $props();

  $effect(() => {
    document.documentElement.classList.toggle("dark", themeStore.isDark);
  });
</script>

<AppShell>{@render children()}</AppShell>
