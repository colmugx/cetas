import {
  Cable,
  Cpu,
  GitBranch,
  Send,
  Sparkles,
  TerminalSquare,
} from "@lucide/solid";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";
import { StatusPill } from "../ui/StatusPill";

export default function ChatPage() {
  const runtime = useCetasRuntime();
  const snapshot = () => runtime.runtime();

  return (
    <div class="mx-auto flex min-h-[calc(100vh-3.5rem)] w-full max-w-6xl flex-col px-4 py-5 md:px-6">
      <section class="grid gap-3 xl:grid-cols-[minmax(0,1fr)_310px]">
        <div class="rounded-2xl border border-zinc-800 bg-zinc-900/35 p-5 md:p-7">
          <div class="mb-8 flex items-center justify-between gap-3">
            <StatusPill tone={runtime.core() === "ready" ? "good" : "warn"}>
              cetas-core {runtime.core()}
            </StatusPill>
            <span class="font-mono text-[10px] uppercase tracking-[0.16em] text-zinc-600">
              day 1 shell
            </span>
          </div>

          <div class="max-w-2xl">
            <h1 class="text-3xl font-semibold tracking-[-0.035em] text-zinc-50 md:text-4xl">
              A web-native surface for the same Cetas.
            </h1>
            <p class="mt-3 max-w-xl text-sm leading-6 text-zinc-400">
              The MoonBit host is already composing cetas-core. Solid owns the
              interaction layer; HTTP and WebSocket stay behind a Cetas-native
              protocol boundary.
            </p>
          </div>

          <div class="mt-8 grid gap-2 sm:grid-cols-3">
            <Metric
              icon={<Cpu size={16} />}
              label="Core runtime"
              value={snapshot()?.status ?? "checking"}
            />
            <Metric
              icon={<Cable size={16} />}
              label="Active model"
              value={snapshot()?.model || "not selected"}
            />
            <Metric
              icon={<GitBranch size={16} />}
              label="Session"
              value={snapshot()?.session_id || "not minted"}
            />
          </div>

          {snapshot()?.status === "needs_setup" && (
            <div class="mt-4 rounded-xl border border-amber-500/20 bg-amber-500/5 p-4">
              <div class="text-sm font-medium text-amber-200">Setup required</div>
              <p class="mt-1 break-words font-mono text-xs leading-5 text-amber-200/65">
                {snapshot()?.detail}
              </p>
            </div>
          )}
        </div>

        <aside class="rounded-2xl border border-zinc-800 bg-zinc-900/35 p-5">
          <div class="flex items-center gap-2 text-sm font-medium">
            <TerminalSquare size={16} />
            Host inspector
          </div>
          <dl class="mt-5 space-y-4 text-xs">
            <Inspector label="cwd" value={snapshot()?.cwd || "—"} />
            <Inspector label="effort" value={snapshot()?.effort || "default"} />
            <Inspector
              label="protocol"
              value={
                runtime.health()?.protocol
                  ? `cetas-web/${runtime.health()?.protocol}`
                  : "—"
              }
            />
            <Inspector label="static assets" value="Moonback seam" />
          </dl>
        </aside>
      </section>

      <section class="mt-3 flex min-h-[300px] flex-1 flex-col items-center justify-center rounded-2xl border border-dashed border-zinc-800 bg-zinc-950/35 px-5 text-center">
        <div class="grid size-11 place-items-center rounded-xl border border-zinc-800 bg-zinc-900 text-zinc-300">
          <Sparkles size={19} />
        </div>
        <h2 class="mt-4 text-sm font-medium text-zinc-200">Transcript lands next</h2>
        <p class="mt-1 max-w-md text-xs leading-5 text-zinc-500">
          The host is alive now. The next slice replaces this empty state with
          session attach, turn streaming, tool lifecycle, approvals, and replay.
        </p>
      </section>

      <section class="sticky bottom-0 mt-3 pb-3 pt-2">
        <div class="rounded-2xl border border-zinc-700/80 bg-zinc-900/95 p-2 shadow-2xl shadow-black/30 backdrop-blur">
          <textarea
            rows={3}
            placeholder="Ask Cetas to change something…"
            class="w-full resize-none bg-transparent px-3 py-2 text-sm leading-6 text-zinc-200 outline-none placeholder:text-zinc-600"
          />
          <div class="flex items-center justify-between gap-3 px-2 pb-1">
            <span class="font-mono text-[10px] text-zinc-600">
              turn transport not wired yet
            </span>
            <button
              disabled
              class="grid size-8 place-items-center rounded-lg bg-zinc-100 text-zinc-950 opacity-45"
              title="Turn protocol lands in the next slice"
            >
              <Send size={15} />
            </button>
          </div>
        </div>
      </section>
    </div>
  );
}

function Metric(props: {
  icon: JSX.Element;
  label: string;
  value: string;
}) {
  return (
    <div class="rounded-xl border border-zinc-800 bg-zinc-950/55 p-3">
      <div class="flex items-center gap-2 text-zinc-500">
        {props.icon}
        <span class="text-[11px]">{props.label}</span>
      </div>
      <div class="mt-3 truncate font-mono text-xs text-zinc-200" title={props.value}>
        {props.value}
      </div>
    </div>
  );
}

function Inspector(props: { label: string; value: string }) {
  return (
    <div>
      <dt class="font-mono text-[10px] uppercase tracking-[0.14em] text-zinc-600">
        {props.label}
      </dt>
      <dd class="mt-1 break-words text-zinc-300">{props.value}</dd>
    </div>
  );
}
