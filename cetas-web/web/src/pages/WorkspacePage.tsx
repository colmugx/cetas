import { FolderTree, Search, TerminalSquare } from "@lucide/solid";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";

export default function WorkspacePage() {
  const runtime = useCetasRuntime();

  return (
    <div class="mx-auto w-full max-w-6xl px-4 py-6 md:px-6">
      <div class="flex items-start justify-between gap-5">
        <div>
          <div class="flex items-center gap-2 text-sm font-medium text-zinc-200">
            <FolderTree size={17} />
            Workspace
          </div>
          <p class="mt-2 text-sm text-zinc-500">
            Files, search, diffs, and tool artifacts will live here.
          </p>
        </div>
      </div>

      <div class="mt-6 grid gap-3 md:grid-cols-2">
        <Placeholder
          icon={<Search size={17} />}
          title="File explorer"
          detail="Waiting for the workspace HTTP surface."
        />
        <Placeholder
          icon={<TerminalSquare size={17} />}
          title="Current working directory"
          detail={runtime.runtime()?.cwd || "Runtime not ready"}
          mono
        />
      </div>
    </div>
  );
}

function Placeholder(props: {
  icon: JSX.Element;
  title: string;
  detail: string;
  mono?: boolean;
}) {
  return (
    <section class="rounded-2xl border border-zinc-800 bg-zinc-900/30 p-5">
      <div class="flex items-center gap-2 text-sm font-medium text-zinc-300">
        {props.icon}
        {props.title}
      </div>
      <p
        class={`mt-8 text-sm text-zinc-500 ${props.mono ? "font-mono text-xs" : ""}`}
      >
        {props.detail}
      </p>
    </section>
  );
}
