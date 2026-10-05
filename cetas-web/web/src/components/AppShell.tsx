import {
  Activity,
  FolderTree,
  MessageSquare,
  Plus,
  Settings,
  Waves,
} from "@lucide/solid";
import { useLocation } from "@solidjs/router";
import { createEffect, Show } from "solid-js";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";

const navItems = [
  { path: "/", label: "Chat", icon: MessageSquare },
  { path: "/workspace", label: "Workspace", icon: FolderTree },
  { path: "/settings", label: "Settings", icon: Settings },
] as const;

function dotTone(state: string): string {
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
}

function StatusDot(props: { state: string }) {
  return (
    <span
      class={`inline-block size-1.5 shrink-0 rounded-full ${dotTone(props.state)}`}
    />
  );
}

function RuntimeRow(props: { label: string; value: string }) {
  return (
    <div class="flex items-center gap-2 text-[11px]">
      <span class="w-9 shrink-0 font-mono uppercase tracking-wide text-fg-faint">
        {props.label}
      </span>
      <StatusDot state={props.value} />
      <span class="min-w-0 flex-1 truncate text-fg-muted">{props.value}</span>
    </div>
  );
}

function ValueRow(props: { label: string; value: string }) {
  return (
    <div class="flex items-baseline gap-2 text-[11px]">
      <span class="w-9 shrink-0 font-mono uppercase tracking-wide text-fg-faint">
        {props.label}
      </span>
      <span
        class="min-w-0 flex-1 truncate font-mono text-fg-muted"
        title={props.value || undefined}
      >
        {props.value || "—"}
      </span>
    </div>
  );
}

export default function AppShell(props: { children: JSX.Element }) {
  const location = useLocation();
  const runtime = useCetasRuntime();
  const snapshot = () => runtime.runtime();

  const pageTitle = () =>
    navItems.find((item) => item.path === location.pathname)?.label ?? "Cetas";
  const modelName = () => {
    const model = snapshot()?.model ?? "";
    return model.length > 0 ? (model.split("/").pop() ?? model) : "";
  };
  const effort = () => snapshot()?.effort ?? "";

  createEffect(
    () => location.pathname,
    (path) => {
      const page =
        navItems.find((item) => item.path === path)?.label ?? "Cetas";
      document.title = `Cetas · ${page}`;
    },
  );

  return (
    <div class="flex h-svh overflow-hidden bg-canvas text-fg">
      <aside class="hidden w-[248px] shrink-0 flex-col border-r border-line bg-panel lg:flex">
        <div class="flex items-center gap-2.5 px-4 pb-4 pt-5">
          <div class="grid size-8 shrink-0 place-items-center rounded-lg border border-accent/20 bg-accent-dim text-accent">
            <Waves size={16} />
          </div>
          <div class="min-w-0">
            <div class="text-[13px] font-semibold tracking-tight">Cetas</div>
            <div class="text-[10px] font-medium uppercase tracking-[0.16em] text-fg-faint">
              Agent console
            </div>
          </div>
        </div>

        <div class="px-3">
          <button
            disabled
            title="Session creation lands with the realtime protocol"
            class="flex h-8 w-full items-center justify-center gap-1.5 rounded-lg border border-dashed border-line-strong text-xs font-medium text-fg-faint"
          >
            <Plus size={14} />
            New session
          </button>
        </div>

        <nav class="mt-4 space-y-0.5 px-3">
          {navItems.map((item) => {
            const Icon = item.icon;
            const active = location.pathname === item.path;
            return (
              <a
                class={`flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-[13px] transition-colors ${
                  active
                    ? "bg-raised text-fg"
                    : "text-fg-muted hover:bg-raised/50 hover:text-fg"
                }`}
                href={item.path}
              >
                <Icon
                  size={15}
                  class={active ? "text-accent" : "text-fg-faint"}
                />
                {item.label}
              </a>
            );
          })}
        </nav>

        <div class="mt-auto p-3">
          <div class="rounded-xl border border-line bg-raised/40 p-3">
            <div class="flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-fg-faint">
              <Activity size={11} />
              Runtime
            </div>
            <div class="mt-2.5 space-y-1.5">
              <RuntimeRow label="core" value={runtime.core()} />
              <RuntimeRow label="ws" value={runtime.socket()} />
              <RuntimeRow label="http" value={runtime.http()} />
            </div>
            <div class="mt-3 space-y-1.5 border-t border-line pt-2.5">
              <ValueRow label="model" value={modelName()} />
              <ValueRow label="effort" value={effort()} />
              <ValueRow label="cwd" value={snapshot()?.cwd ?? ""} />
            </div>
          </div>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="flex h-12 shrink-0 items-center justify-between border-b border-line bg-panel/60 px-4 backdrop-blur md:px-5">
          <div class="flex items-center gap-2.5">
            <div class="grid size-7 place-items-center rounded-lg border border-accent/20 bg-accent-dim text-accent lg:hidden">
              <Waves size={14} />
            </div>
            <span class="text-sm font-medium tracking-tight">
              {pageTitle()}
            </span>
          </div>

          <div class="flex items-center gap-2.5">
            <Show when={modelName()}>
              <span class="hidden rounded-md border border-line bg-raised/60 px-2 py-1 font-mono text-[10.5px] text-fg-muted sm:inline">
                {modelName()}
                <Show when={effort()}> · {effort()}</Show>
              </span>
            </Show>
            <span
              class="flex items-center gap-1.5 text-[11px] text-fg-muted"
              title={`api ${runtime.http()}`}
            >
              <StatusDot state={runtime.http()} />
              api
            </span>
            <span
              class="flex items-center gap-1.5 text-[11px] text-fg-muted"
              title={`realtime ${runtime.socket()}`}
            >
              <StatusDot state={runtime.socket()} />
              ws
            </span>
          </div>
        </header>

        <main class="min-h-0 flex-1">{props.children}</main>
      </div>
    </div>
  );
}
