import { Check, ChevronDown } from "@lucide/solid";
import { For, Show, createSignal, onCleanup } from "solid-js";

export type PickerOption = {
  value: string;
  label: string;
  hint?: string;
  active?: boolean;
};

export function Picker(props: {
  label: string;
  value: string;
  options: PickerOption[];
  disabled?: boolean;
  onSelect: (value: string) => void;
}) {
  const [open, setOpen] = createSignal(false);
  let rootRef: HTMLDivElement | undefined;

  const onDocClick = (event: MouseEvent) => {
    if (rootRef && !rootRef.contains(event.target as Node)) {
      setOpen(false);
    }
  };
  const onDocKey = (event: KeyboardEvent) => {
    if (event.key === "Escape") setOpen(false);
  };
  document.addEventListener("click", onDocClick);
  document.addEventListener("keydown", onDocKey);
  onCleanup(() => {
    document.removeEventListener("click", onDocClick);
    document.removeEventListener("keydown", onDocKey);
  });

  return (
    <div ref={rootRef} class="relative">
      <button
        onClick={() => setOpen(!open())}
        disabled={props.disabled}
        class="flex max-w-[220px] items-center gap-1.5 rounded-lg border border-line bg-panel px-2 py-1.5 text-[11px] transition-colors hover:border-line-strong disabled:opacity-40"
        title={`${props.label}: ${props.value}`}
      >
        <span class="shrink-0 font-mono text-fg-faint">{props.label}</span>
        <span class="min-w-0 truncate font-medium text-fg">{props.value}</span>
        <ChevronDown size={12} class="shrink-0 text-fg-faint" />
      </button>
      <Show when={open()}>
        <div class="scroll-slim absolute bottom-full left-0 z-30 mb-1.5 max-h-72 min-w-[260px] overflow-y-auto rounded-xl border border-line-strong bg-raised p-1 shadow-[0_12px_40px_-12px_var(--shadow-color)]">
          <For each={props.options}>
            {(option) => (
              <button
                onClick={() => {
                  props.onSelect(option.value);
                  setOpen(false);
                }}
                class="flex w-full items-center gap-2 rounded-lg px-2.5 py-2 text-left text-xs transition-colors hover:bg-panel"
              >
                <span class="min-w-0 flex-1 truncate text-fg">
                  {option.label}
                </span>
                <Show when={option.hint}>
                  <span class="shrink-0 font-mono text-[10px] text-fg-faint">
                    {option.hint}
                  </span>
                </Show>
                <Show when={option.active}>
                  <Check size={13} class="shrink-0 text-accent" />
                </Show>
              </button>
            )}
          </For>
        </div>
      </Show>
    </div>
  );
}
