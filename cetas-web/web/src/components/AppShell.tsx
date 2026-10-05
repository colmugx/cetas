import {
  Activity,
  Bot,
  FolderTree,
  MessageSquare,
  Plus,
  Settings,
} from "@lucide/solid";
import { useLocation } from "@solidjs/router";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";
import { StatusPill } from "../ui/StatusPill";

export default function AppShell(props: { children: JSX.Element }) {
  const location = useLocation();
  const runtime = useCetasRuntime();

  const navClass = (path: string) =>
    `flex items-center gap-2 rounded-lg px-3 py-2 text-sm transition ${
      location.pathname === path
        ? "bg-zinc-800 text-zinc-100"
        : "text-zinc-500 hover:bg-zinc-900 hover:text-zinc-200"
    }`;

  return (
    <div class="grid min-h-screen grid-cols-1 bg-zinc-950 text-zinc-100 lg:grid-cols-[248px_minmax(0,1fr)]">
      <aside class="hidden border-r border-zinc-800/80 bg-zinc-950/90 p-3 lg:flex lg:flex-col">
        <div class="flex items-center gap-2 px-2 py-3">
          <div class="grid size-8 place-items-center rounded-lg border border-zinc-700 bg-zinc-900">
            <Bot size={17} strokeWidth={1.8} />
          </div>
          <div>
            <div class="text-sm font-semibold tracking-tight">Cetas</div>
            <div class="font-mono text-[10px] uppercase tracking-[0.18em] text-zinc-600">
              web / solid 2
            </div>
          </div>
        </div>

        <button
          disabled
          class="mt-3 flex h-9 items-center justify-center gap-2 rounded-lg border border-zinc-700 bg-zinc-100 px-3 text-sm font-medium text-zinc-950 opacity-70"
          title="Session creation lands with the realtime protocol"
        >
          <Plus size={15} />
          New session
        </button>

        <nav class="mt-5 space-y-1">
          <a class={navClass("/")} href="/">
            <MessageSquare size={16} />
            Chat
          </a>
          <a class={navClass("/workspace")} href="/workspace">
            <FolderTree size={16} />
            Workspace
          </a>
          <a class={navClass("/settings")} href="/settings">
            <Settings size={16} />
            Settings
          </a>
        </nav>

        <div class="mt-auto rounded-xl border border-zinc-800 bg-zinc-900/45 p-3">
          <div class="mb-2 flex items-center gap-2 text-xs font-medium text-zinc-300">
            <Activity size={14} />
            Runtime
          </div>
          <div class="flex flex-wrap gap-1.5">
            <StatusPill
              tone={runtime.core() === "ready" ? "good" : runtime.core() === "needs_setup" ? "warn" : "neutral"}
            >
              core {runtime.core()}
            </StatusPill>
            <StatusPill tone={runtime.socket() === "online" ? "good" : "neutral"}>
              ws {runtime.socket()}
            </StatusPill>
          </div>
        </div>
      </aside>

      <main class="min-w-0">
        <header class="sticky top-0 z-20 flex h-14 items-center justify-between border-b border-zinc-800/80 bg-zinc-950/85 px-4 backdrop-blur md:px-6">
          <div class="flex items-center gap-3">
            <div class="grid size-8 place-items-center rounded-lg border border-zinc-800 bg-zinc-900 lg:hidden">
              <Bot size={16} />
            </div>
            <div>
              <div class="text-sm font-medium">Cetas Web</div>
              <div class="hidden font-mono text-[10px] text-zinc-600 sm:block">
                Moonback · cetas-core · Solid 2
              </div>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <StatusPill tone={runtime.http() === "online" ? "good" : "neutral"}>
              http {runtime.http()}
            </StatusPill>
            <StatusPill tone={runtime.socket() === "online" ? "good" : "neutral"}>
              realtime {runtime.socket()}
            </StatusPill>
          </div>
        </header>

        {props.children}
      </main>
    </div>
  );
}
