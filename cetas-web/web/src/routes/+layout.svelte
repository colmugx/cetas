<script lang="ts">
  import "../app.css";
  import AppShell from "#lib/components/AppShell.svelte";
  import { themeStore } from "#lib/theme.svelte";
  import { page } from "$app/state";
  import { fade } from "svelte/transition";

  let { children } = $props();

  $effect(() => {
    document.documentElement.classList.toggle("dark", themeStore.isDark);
  });
</script>

<AppShell>
  {#key page.url.pathname}
    <main class="h-full" in:fade={{ duration: 130 }}>
      {@render children()}
    </main>
  {/key}
</AppShell>
