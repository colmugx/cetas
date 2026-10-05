import {
  Cpu,
  GitBranch,
  Layers,
  Monitor,
  Moon,
  Palette,
  Settings,
  Sparkles,
  Sun,
  Workflow,
  Zap,
} from "@lucide/solid";
import { For, Show } from "solid-js";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";
import { useTheme, type ThemeChoice } from "../theme";
import { StatusPill } from "../ui/StatusPill";

const themeOptions: Array<{ value: ThemeChoice; label: string; icon: JSX.Element }> = [
  { value: "system", label: "System", icon: <Monitor size={13} /> },
  { value: "light", label: "Light", icon: <Sun size={13} /> },
  { value: "dark", label: "Dark", icon: <Moon size={13} /> },
];

export default function SettingsPage() {
  const runtime = useCetasRuntime();
  const theme = useTheme();
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
          icon={<Palette size={15} />}
          title="Appearance"
          detail="Theme follows the system by default"
          right={<ThemeSwitch value={theme.choice()} onChange={theme.setChoice} />}
        />
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

function ThemeSwitch(props: {
  value: ThemeChoice;
  onChange: (choice: ThemeChoice) => void;
}) {
  return (
    <div class="flex items-center gap-0.5 rounded-lg border border-line bg-panel p-0.5">
      <For each={themeOptions}>
        {(option) => (
          <button
            onClick={() => props.onChange(option.value)}
            class={`flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium transition-colors ${
              props.value === option.value
                ? "bg-raised text-fg shadow-sm"
                : "text-fg-muted hover:text-fg"
            }`}
            title={`${option.label} theme`}
          >
            {option.icon}
            <span class="hidden sm:inline">{option.label}</span>
          </button>
        )}
      </For>
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
