type Tone = "neutral" | "good" | "warn" | "bad";

const toneClass: Record<Tone, string> = {
  neutral: "border-zinc-700 bg-zinc-900 text-zinc-400",
  good: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300",
  warn: "border-amber-500/25 bg-amber-500/10 text-amber-300",
  bad: "border-rose-500/25 bg-rose-500/10 text-rose-300",
};

export function StatusPill(props: {
  children: string;
  tone?: Tone;
  dot?: boolean;
}) {
  return (
    <span
      class={`inline-flex items-center gap-1.5 rounded-full border px-2 py-1 text-[11px] font-medium ${toneClass[props.tone ?? "neutral"]}`}
    >
      {props.dot !== false && (
        <span class="size-1.5 rounded-full bg-current opacity-80" />
      )}
      {props.children}
    </span>
  );
}
