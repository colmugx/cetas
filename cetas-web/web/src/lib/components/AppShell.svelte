<script lang="ts">
  import {
    Activity,
    FolderTree,
    MessageSquare,
    Monitor,
    Moon,
    Plus,
    Settings,
    Sun,
    Waves,
  } from "@lucide/svelte";
  import { page } from "$app/state";
  import { listSessions, switchSession, type SessionSummary } from "#lib/api";
  import { runtimeStore } from "#lib/runtime.svelte";
  import { themeStore } from "#lib/theme.svelte";

  let { children } = $props();

  const navItems = [
    { path: "/", label: "Chat", icon: MessageSquare },
    { path: "/workspace", label: "Workspace", icon: FolderTree },
    { path: "/settings", label: "Settings", icon: Settings },
  ];

  const pageTitle = $derived(
    navItems.find((item) => item.path === page.url.pathname)?.label ?? "Cetas",
  );

  $effect(() => {
    document.title = `Cetas · ${pageTitle}`;
  });

  const dotTone = (state: string) => {
    switch (state) {
      case "online":
      case "ready":
        return "bg-accent";
      case "checking":
      case "connecting":
      case "needs_setup":
        return "bg-warn animate-breathe";
      case "offline":
        return "bg-bad";
      default:
        return "bg-line-strong";
    }
  };

  let sessions = $state<SessionSummary[]>([]);
  let sessionError = $state("");
  let errorTimer: ReturnType<typeof setTimeout> | undefined;
  const activeSessionId = $derived(runtimeStore.runtime?.session_id ?? "");

  function flashSessionError(message: string) {
    sessionError = message;
    if (errorTimer) clearTimeout(errorTimer);
    errorTimer = setTimeout(() => (sessionError = ""), 6000);
  }

  async function loadSessions() {
    try {
      const data = await listSessions();
      sessions = data.sessions;
    } catch {
      // Keep the last known list while the API is unreachable.
    }
  }

  let previousSessionId: string | undefined;
  $effect(() => {
    const id = activeSessionId;
    // Load on mount too: previous is undefined on the first run.
    if (previousSessionId === undefined || id !== previousSessionId) {
      void loadSessions();
    }
    previousSessionId = id;
  });

  async function pickSession(id?: string) {
    try {
      await switchSession(id);
    } catch (error) {
      flashSessionError(error instanceof Error ? error.message : String(error));
    }
  }
</script>

<div class="flex h-svh overflow-hidden bg-canvas text-fg">
  <aside
    class="hidden w-[248px] shrink-0 flex-col border-r border-line bg-panel lg:flex"
  >
    <div class="flex items-center gap-2.5 px-4 pb-4 pt-5">
      <div
        class="grid size-8 shrink-0 place-items-center rounded-lg border border-accent/20 bg-accent-dim text-accent"
      >
        <Waves size={16} />
      </div>
      <div class="min-w-0">
        <div class="text-[13px] font-semibold tracking-tight">Cetas</div>
        <div
          class="text-[10px] font-medium uppercase tracking-[0.16em] text-fg-faint"
        >
          Agent console
        </div>
      </div>
    </div>

    <nav class="space-y-0.5 px-3">
      {#each navItems as item (item.path)}
        {@const Icon = item.icon}
        {@const active = page.url.pathname === item.path}
        <a
          class="flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-[13px] transition-colors {active
            ? 'bg-raised text-fg'
            : 'text-fg-muted hover:bg-raised/50 hover:text-fg'}"
          href={item.path}
        >
          <Icon size={15} class={active ? "text-accent" : "text-fg-faint"} />
          {item.label}
        </a>
      {/each}
    </nav>

    <div class="mt-4 flex min-h-0 flex-1 flex-col px-3">
      <div class="flex items-center justify-between px-2">
        <span
          class="text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint"
        >
          Sessions
        </span>
        <button
          onclick={() => void pickSession()}
          class="flex items-center gap-1 rounded-md px-1.5 py-1 text-[11px] font-medium text-fg-muted transition-colors hover:bg-raised hover:text-fg"
          title="Start a new session"
        >
          <Plus size={13} />
          New
        </button>
      </div>
      {#if sessionError}
        <p
          class="mt-1.5 rounded-lg border border-bad/25 bg-bad/10 px-2 py-1.5 text-[10.5px] leading-4 text-bad"
        >
          {sessionError}
        </p>
      {/if}
      <div class="scroll-slim mt-1.5 min-h-0 flex-1 space-y-0.5 overflow-y-auto">
        {#each sessions as session (session.id)}
          {@const isActive = session.id === activeSessionId}
          <button
            onclick={() => void pickSession(session.id)}
            class="flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-xs transition-colors {isActive
              ? 'bg-raised text-fg'
              : 'text-fg-muted hover:bg-raised/50 hover:text-fg'}"
            title={session.id}
          >
            <span
              class="size-1.5 shrink-0 rounded-full {isActive
                ? 'bg-accent'
                : 'bg-line-strong'}"
            ></span>
            <span class="min-w-0 flex-1 truncate">{session.title}</span>
          </button>
        {/each}
        {#if sessions.length === 0}
          <p class="px-2.5 py-2 text-[11px] text-fg-faint">
            No persisted sessions yet.
          </p>
        {/if}
      </div>
    </div>

    <div class="shrink-0 p-3">
      <div class="rounded-xl border border-line bg-raised/40 p-3">
        <div
          class="flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint"
        >
          <Activity size={11} />
          Runtime
        </div>
        <div class="mt-2.5 space-y-1.5">
          <div class="flex items-center gap-2 text-[11px]">
            <span
              class="w-9 shrink-0 font-mono uppercase tracking-wide text-fg-faint"
            >
              core
            </span>
            <span
              class="inline-block size-1.5 shrink-0 rounded-full {dotTone(
                runtimeStore.core,
              )}"
            ></span>
            <span class="min-w-0 flex-1 truncate text-fg-muted">
              {runtimeStore.core}
            </span>
          </div>
          <div class="flex items-center gap-2 text-[11px]">
            <span
              class="w-9 shrink-0 font-mono uppercase tracking-wide text-fg-faint"
            >
              ws
            </span>
            <span
              class="inline-block size-1.5 shrink-0 rounded-full {dotTone(
                runtimeStore.socketState,
              )}"
            ></span>
            <span class="min-w-0 flex-1 truncate text-fg-muted">
              {runtimeStore.socketState}
            </span>
          </div>
          <div class="flex items-center gap-2 text-[11px]">
            <span
              class="w-9 shrink-0 font-mono uppercase tracking-wide text-fg-faint"
            >
              http
            </span>
            <span
              class="inline-block size-1.5 shrink-0 rounded-full {dotTone(
                runtimeStore.http,
              )}"
            ></span>
            <span class="min-w-0 flex-1 truncate text-fg-muted">
              {runtimeStore.http}
            </span>
          </div>
        </div>
      </div>
    </div>
  </aside>

  <div class="flex min-w-0 flex-1 flex-col">
    <header
      class="flex h-12 shrink-0 items-center justify-between border-b border-line bg-panel/60 px-4 backdrop-blur md:px-5"
    >
      <div class="flex items-center gap-2.5">
        <div
          class="grid size-7 place-items-center rounded-lg border border-accent/20 bg-accent-dim text-accent lg:hidden"
        >
          <Waves size={14} />
        </div>
        <span class="text-sm font-medium tracking-tight">{pageTitle}</span>
      </div>

      <div class="flex items-center gap-2.5">
        <span
          class="flex items-center gap-1.5 text-[11px] text-fg-muted"
          title="api {runtimeStore.http}"
        >
          <span
            class="inline-block size-1.5 shrink-0 rounded-full {dotTone(
              runtimeStore.http,
            )}"
          ></span>
          api
        </span>
        <span
          class="flex items-center gap-1.5 text-[11px] text-fg-muted"
          title="realtime {runtimeStore.socketState}"
        >
          <span
            class="inline-block size-1.5 shrink-0 rounded-full {dotTone(
              runtimeStore.socketState,
            )}"
          ></span>
          ws
        </span>
        <button
          onclick={() => themeStore.cycle()}
          class="grid size-7 place-items-center rounded-lg border border-line bg-raised/60 text-fg-muted transition-colors hover:text-fg"
          title="Theme: {themeStore.choice} (click to cycle)"
        >
          {#if themeStore.choice === "dark"}
            <Moon size={14} />
          {:else if themeStore.choice === "light"}
            <Sun size={14} />
          {:else}
            <Monitor size={14} />
          {/if}
        </button>
      </div>
    </header>

    <main class="min-h-0 flex-1">{@render children()}</main>
  </div>
</div>
