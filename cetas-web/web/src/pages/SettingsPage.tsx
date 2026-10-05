import {
  Cpu,
  GitBranch,
  Layers,
  Settings,
  Sparkles,
  Workflow,
  Zap,
} from "@lucide/solid";
import { Show } from "solid-js";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";
import { StatusPill } from "../ui/StatusPill";

export default function SettingsPage() {
  const runtime = useCetasRuntime();
  const snapshot = () => runtime.runtime();

  return (
    <div class="mx-auto w-full max-w-3xl px-5 py-8">
      <div class="flex items-center gap-2.5">
        <span class="grid size-8 place-items-center rounded-lg border border-line bg-raised text-fg-muted">
          <Settings size={15} />
        </span>
        <div>
          <h1 class="text-base font-semibold tracking-tight text-fg">
            Settings
          </h1>
          <p class="mt-0.5 text-xs text-fg-muted">
            Live state of the Cetas host this console is attached to.
          </p>
        </div>
      </div>

      <div class="mt-7 space-y-2.5">
        <Row
          icon={<Cpu size={15} />}
          title="cetas-core"
          detail={
            snapshot()?.detail || snapshot()?.model || "Connecting to the host…"
          }
          right={
            <StatusPill
              tone={
                runtime.core() === "ready"
                  ? "good"
                  : runtime.core() === "needs_setup"
                    ? "warn"
                    : "neutral"
              }
              pulse={runtime.core() === "checking"}
            >
              {runtime.core()}
            </StatusPill>
          }
        />
        <Row
          icon={<Sparkles size={15} />}
          title="Model"
          detail="Reasoning model used for new turns"
          right={
            <span
              class="max-w-[240px] truncate font-mono text-xs text-fg-muted"
              title={snapshot()?.model || undefined}
            >
              {snapshot()?.model || "—"}
            </span>
          }
        />
        <Row
          icon={<Zap size={15} />}
          title="Effort"
          detail="Reasoning depth requested from the model"
          right={
            <span class="font-mono text-xs text-fg-muted">
              {snapshot()?.effort || "—"}
            </span>
          }
        />
        <Row
          icon={<GitBranch size={15} />}
          title="Session"
          detail="Host session bound to this browser"
          right={
            <span
              class="max-w-[220px] truncate font-mono text-xs text-fg-muted"
              title={snapshot()?.session_id || undefined}
            >
              {snapshot()?.session_id || "—"}
            </span>
          }
        />
        <Row
          icon={<Layers size={15} />}
          title="Frontend stack"
          detail="Solid 2 RC · Solid Router 2 next · Tailwind CSS v4"
          right={<StatusPill>pinned</StatusPill>}
        />
      </div>
    </div>
  );
}

function Row(props: {
  icon: JSX.Element;
  title: string;
  detail?: string;
  right: JSX.Element;
}) {
  return (
    <section class="flex items-center justify-between gap-4 rounded-xl border border-line bg-panel/60 px-4 py-3.5">
      <div class="flex min-w-0 items-center gap-3">
        <span class="grid size-8 shrink-0 place-items-center rounded-lg border border-line bg-raised text-fg-muted">
          {props.icon}
        </span>
        <div class="min-w-0">
          <div class="text-sm font-medium text-fg">{props.title}</div>
          <Show when={props.detail}>
            <div
              class="mt-0.5 truncate text-xs text-fg-muted"
              title={props.detail}
            >
              {props.detail}
            </div>
          </Show>
        </div>
      </div>
      <div class="shrink-0">{props.right}</div>
    </section>
  );
}
