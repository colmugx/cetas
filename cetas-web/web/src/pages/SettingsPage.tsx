import { Cpu, Settings, Workflow } from "@lucide/solid";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";
import { StatusPill } from "../ui/StatusPill";

export default function SettingsPage() {
  const runtime = useCetasRuntime();
  const snapshot = () => runtime.runtime();

  return (
    <div class="mx-auto w-full max-w-4xl px-4 py-6 md:px-6">
      <div class="flex items-center gap-2 text-sm font-medium text-zinc-200">
        <Settings size={17} />
        Settings
      </div>
      <p class="mt-2 text-sm text-zinc-500">
        This page intentionally reads the real cetas-core boot state before
        provider/model controls arrive.
      </p>

      <div class="mt-6 space-y-3">
        <SettingRow
          icon={<Cpu size={17} />}
          title="cetas-core"
          detail={snapshot()?.detail || snapshot()?.model || "Connecting…"}
          right={
            <StatusPill tone={runtime.core() === "ready" ? "good" : "warn"}>
              {runtime.core()}
            </StatusPill>
          }
        />
        <SettingRow
          icon={<Workflow size={17} />}
          title="Frontend stack"
          detail="Solid 2 RC · Solid Router 2 next · Tailwind CSS v4"
          right={<StatusPill>pinned</StatusPill>}
        />
      </div>
    </div>
  );
}

function SettingRow(props: {
  icon: JSX.Element;
  title: string;
  detail: string;
  right: JSX.Element;
}) {
  return (
    <section class="flex items-start justify-between gap-5 rounded-2xl border border-zinc-800 bg-zinc-900/30 p-5">
      <div class="flex min-w-0 gap-3">
        <div class="mt-0.5 text-zinc-500">{props.icon}</div>
        <div class="min-w-0">
          <div class="text-sm font-medium text-zinc-200">{props.title}</div>
          <div class="mt-1 break-words text-xs leading-5 text-zinc-500">
            {props.detail}
          </div>
        </div>
      </div>
      <div class="shrink-0">{props.right}</div>
    </section>
  );
}
