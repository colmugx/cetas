<script lang="ts">
  import {
    Activity,
    FolderOpen,
    MessageSquare,
    Monitor,
    Moon,
    Pencil,
    Plus,
    Settings,
    Sun,
    Waves,
    X,
  } from "@lucide/svelte";
  import { page } from "$app/state";
  import { listSessions, renameSession, type SessionSummary } from "#lib/api";
  import { runtimeStore } from "#lib/runtime.svelte";
  import { themeStore } from "#lib/theme.svelte";

  let { children } = $props();

  const navItems = [
    { path: "/", label: "Chat", icon: MessageSquare },
    { path: "/workspace", label: "Workspace", icon: FolderOpen },
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
  const activeSessionId = $derived(runtimeStore.activeSessionId);

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
    if (previousSessionId === undefined || id !== previousSessionId) {
      void loadSessions();
    }
    previousSessionId = id;
  });

  async function pickSession(id: string) {
    try {
      await runtimeStore.switchSession(id);
    } catch (error) {
      flashSessionError(error instanceof Error ? error.message : String(error));
    }
  }

  let editingId = $state("");
  let editingDraft = $state("");

  function focusOnMount(node: HTMLElement) {
    node.focus();
  }

  async function commitRename(id: string) {
    const name = editingDraft.trim();
    editingId = "";
    if (!name) return;
    try {
      await renameSession(id, name);
      await loadSessions();
    } catch (error) {
      flashSessionError(error instanceof Error ? error.message : String(error));
    }
  }

  let addingWorkspace = $state(false);
  let workspaceDraft = $state("");

  async function commitWorkspace() {
    const cwd = workspaceDraft.trim();
    addingWorkspace = false;
    workspaceDraft = "";
    if (!cwd) return;
    try {
      await runtimeStore.addOrSwitchWorkspace(cwd);
    } catch (error) {
      flashSessionError(error instanceof Error ? error.message : String(error));
    }
  }

  const activeWorkspaceSessions = $derived(
    runtimeStore.sessionsByWorkspace[runtimeStore.activeWorkspace] ?? [],
  );

  const tabTitle = (id: string): string => {
    const listed = activeWorkspaceSessions.find((s) => s.id === id);
    if (listed) return listed.title;
    return id.slice(-6);
  };
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
          Workspaces
        </span>
        <button
          onclick={() => {
            addingWorkspace = true;
            workspaceDraft = "";
          }}
          class="flex items-center gap-1 rounded-md px-1.5 py-1 text-[11px] font-medium text-fg-muted transition-colors hover:bg-raised hover:text-fg"
          title="Add a workspace by directory path"
        >
          <Plus size={13} />
          Add
        </button>
      </div>

      {#if addingWorkspace}
        <input
          use:focusOnMount
          bind:value={workspaceDraft}
          onkeydown={(event) => {
            if (event.key === "Enter") void commitWorkspace();
            if (event.key === "Escape") (addingWorkspace = false);
          }}
          placeholder="/absolute/path/to/dir"
          spellcheck="false"
          class="mt-1.5 w-full rounded-lg border border-accent/40 bg-panel px-2.5 py-1.5 text-xs text-fg outline-none placeholder:text-fg-faint"
        />
      {/if}

      {#if sessionError}
        <p
          class="mt-1.5 rounded-lg border border-bad/25 bg-bad/10 px-2 py-1.5 text-[10.5px] leading-4 text-bad"
        >
          {sessionError}
        </p>
      {/if}

      <div class="scroll-slim mt-1.5 min-h-0 flex-1 overflow-y-auto">
        {#each runtimeStore.workspaces as workspace (workspace.cwd)}
          <button
            onclick={() => void runtimeStore.addOrSwitchWorkspace(workspace.cwd)}
            class="mt-1 flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-[11px] font-medium transition-colors {workspace.cwd ===
            runtimeStore.activeWorkspace
              ? 'text-fg'
              : 'text-fg-muted hover:text-fg'}"
            title={workspace.cwd}
          >
            <FolderOpen
              size={12}
              class="shrink-0 {workspace.cwd === runtimeStore.activeWorkspace
                ? 'text-accent'
                : 'text-fg-faint'}"
            />
            <span class="min-w-0 flex-1 truncate">{workspace.name}</span>
          </button>
          {#if workspace.cwd === runtimeStore.activeWorkspace}
            <div class="space-y-0.5 pb-1">
              {#each sessions as session (session.id)}
                {@const isActive = session.id === activeSessionId}
                {#if editingId === session.id}
                  <input
                    use:focusOnMount
                    bind:value={editingDraft}
                    onkeydown={(event) => {
                      if (event.key === "Enter") void commitRename(session.id);
                      if (event.key === "Escape") (editingId = "");
                    }}
                    onblur={() => (editingId = "")}
                    class="w-full rounded-lg border border-accent/40 bg-panel px-2.5 py-1.5 text-xs text-fg outline-none"
                    spellcheck="false"
                  />
                {:else}
                  <div class="group relative">
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
                      <span class="min-w-0 flex-1 truncate pr-5"
                        >{session.title}</span
                      >
                    </button>
                    <button
                      onclick={(event) => {
                        event.stopPropagation();
                        editingId = session.id;
                        editingDraft = session.title;
                      }}
                      class="absolute top-1/2 right-1.5 hidden -translate-y-1/2 rounded-md p-1 text-fg-faint transition-colors hover:bg-raised hover:text-fg group-hover:block"
                      title="Rename session"
                    >
                      <Pencil size={11} />
                    </button>
                  </div>
                {/if}
              {/each}
              {#if sessions.length === 0}
                <p class="px-2.5 py-1.5 text-[11px] text-fg-faint">
                  No persisted sessions yet.
                </p>
              {/if}
            </div>
          {/if}
        {/each}
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
      <div class="flex min-w-0 items-center gap-2.5">
        <div
          class="grid size-7 place-items-center rounded-lg border border-accent/20 bg-accent-dim text-accent lg:hidden"
        >
          <Waves size={14} />
        </div>
        <span class="truncate text-sm font-medium tracking-tight"
          >{pageTitle}</span
        >
        {#if runtimeStore.activeWorkspace}
          <span
            class="hidden rounded-md border border-line bg-raised/60 px-2 py-1 font-mono text-[10.5px] text-fg-muted sm:inline"
            title={runtimeStore.activeWorkspace}
          >
            {runtimeStore.activeWorkspace.split("/").pop()}
          </span>
        {/if}
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

    {#if runtimeStore.openTabsForActive().length > 0}
      <div
        class="scroll-slim flex h-9 shrink-0 items-center gap-1 overflow-x-auto border-b border-line bg-panel/40 px-3"
      >
        {#each runtimeStore.openTabsForActive() as tabId (tabId)}
          {@const isActive = tabId === runtimeStore.activeSessionId}
          {@const tabState = runtimeStore.session(tabId)}
          <div
            class="flex h-7 shrink-0 items-center gap-1.5 rounded-lg border px-2.5 text-xs transition-colors {isActive
              ? 'border-line-strong bg-raised text-fg'
              : 'border-transparent text-fg-muted hover:bg-raised/50 hover:text-fg'}"
          >
            <button
              onclick={() => void pickSession(tabId)}
              class="flex items-center gap-1.5"
              title={tabId}
            >
              <span
                class="size-1.5 rounded-full {tabState?.busy
                  ? 'bg-warn animate-breathe'
                  : isActive
                    ? 'bg-accent'
                    : 'bg-line-strong'}"
              ></span>
              <span class="max-w-[160px] truncate">{tabTitle(tabId)}</span>
            </button>
            <button
              onclick={() => runtimeStore.closeTab(tabId)}
              class="rounded p-0.5 text-fg-faint transition-colors hover:bg-line hover:text-fg"
              title="Close tab"
            >
              <X size={11} />
            </button>
          </div>
        {/each}
      </div>
    {/if}

    <main class="min-h-0 flex-1">{@render children()}</main>
  </div>
</div>
