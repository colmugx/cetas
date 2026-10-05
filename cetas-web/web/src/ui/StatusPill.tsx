import type { JSX } from "@solidjs/web";

type Tone = "neutral" | "good" | "warn" | "bad";

const toneClass: Record<Tone, string> = {
  neutral: "border-line bg-raised/70 text-fg-muted",
  good: "border-accent/25 bg-accent-dim text-accent",
  warn: "border-warn/25 bg-warn/10 text-warn",
  bad: "border-bad/25 bg-bad/10 text-bad",
};

export function StatusPill(props: {
  children: JSX.Element;
  tone?: Tone;
  pulse?: boolean;
  dot?: boolean;
}) {
  return (
    <span
      class={`inline-flex h-6 items-center gap-1.5 rounded-full border px-2.5 text-[11px] font-medium ${toneClass[props.tone ?? "neutral"]}`}
    >
      {props.dot !== false && (
        <span
          class={`size-1.5 rounded-full bg-current ${props.pulse ? "animate-breathe" : "opacity-80"}`}
        />
      )}
      {props.children}
    </span>
  );
}
