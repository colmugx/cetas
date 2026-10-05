import { FolderTree, Search, SquareTerminal } from "@lucide/solid";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";

export default function WorkspacePage() {
  const runtime = useCetasRuntime();

  return (
    <div class="mx-auto w-full max-w-3xl px-5 py-8">
      <div class="flex items-center gap-2.5">
        <span class="grid size-8 place-items-center rounded-lg border border-line bg-raised text-fg-muted">
          <FolderTree size={15} />
        </span>
        <div>
          <h1 class="text-base font-semibold tracking-tight text-fg">
            Workspace
          </h1>
          <p class="mt-0.5 text-xs text-fg-muted">
            Files, search, diffs, and tool artifacts will mount here.
          </p>
        </div>
      </div>

      <div class="mt-7 grid gap-3 md:grid-cols-2">
        <Placeholder
          icon={<Search size={15} />}
          title="File explorer"
          detail="Waiting for the workspace HTTP surface."
        />
        <Placeholder
          icon={<SquareTerminal size={15} />}
          title="Working directory"
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
    <section class="rounded-xl border border-dashed border-line-strong/70 bg-panel/40 p-5">
      <div class="flex items-center gap-3">
        <span class="grid size-8 place-items-center rounded-lg border border-line bg-raised text-fg-faint">
          {props.icon}
        </span>
        <div class="text-sm font-medium text-fg">{props.title}</div>
      </div>
      <p
        class={`mt-4 text-xs leading-5 text-fg-muted ${props.mono ? "break-words font-mono" : ""}`}
      >
        {props.detail}
      </p>
    </section>
  );
}
