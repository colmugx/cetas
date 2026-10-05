import {
  Brain,
  ChevronDown,
  Send,
  Square,
  TriangleAlert,
  Waves,
  Wrench,
} from "@lucide/solid";
import {
  For,
  Match,
  Show,
  Switch,
  createEffect,
  createMemo,
  createSignal,
  onCleanup,
} from "solid-js";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";
import type { ServerEvent } from "../cetas/socket";

type TranscriptItem =
  | { kind: "user"; turnId: string; text: string }
  | { kind: "assistant"; turnId: string; text: string; streaming: boolean }
  | { kind: "reasoning"; turnId: string; text: string }
  | {
      kind: "tool";
      turnId: string;
      callId: string;
      name: string;
      status: "running" | "done" | "error";
      detail: string;
    }
  | { kind: "error"; turnId: string; text: string };

const suggestions = [
  "Map this workspace and summarize what it does",
  "Review the latest changes and flag risky ones",
  "Draft a release checklist for this repository",
];

export default function ChatPage() {
  const runtime = useCetasRuntime();
  const snapshot = () => runtime.runtime();
  const [prompt, setPrompt] = createSignal("");
  const [items, setItems] = createSignal<TranscriptItem[]>([]);
  const [busy, setBusy] = createSignal(false);
  const [lastSeq, setLastSeq] = createSignal(0);
  const [atBottom, setAtBottom] = createSignal(true);

  let scrollRef: HTMLDivElement | undefined;
  let composerRef: HTMLTextAreaElement | undefined;

  const currentTurn = createMemo(() => {
    const active = items().findLast(
      (item) => item.kind === "assistant" && item.streaming,
    );
    return active?.turnId ?? "";
  });

  const patchTurn = (
    turnId: string,
    updater: (items: TranscriptItem[]) => TranscriptItem[],
  ) => {
    setItems((current) => updater(current));
  };

  const onEvent = (event: ServerEvent) => {
    if (typeof event.seq === "number") {
      if (event.seq <= lastSeq()) return;
      setLastSeq(event.seq);
    }

    const turnId =
      typeof event.turn_id === "string" && event.turn_id.length > 0
        ? event.turn_id
        : currentTurn();

    switch (event.type) {
      case "session.snapshot":
        setBusy(Boolean(event.busy));
        return;

      case "turn.accepted":
        if (!turnId) return;
        setBusy(true);
        setItems((current) => [
          ...current,
          {
            kind: "user",
            turnId,
            text: typeof event.prompt === "string" ? event.prompt : "",
          },
          { kind: "assistant", turnId, text: "", streaming: true },
        ]);
        return;

      case "assistant.text_delta":
        if (!turnId || typeof event.delta !== "string") return;
        patchTurn(turnId, (current) =>
          current.map((item) =>
            item.kind === "assistant" && item.turnId === turnId
              ? { ...item, text: item.text + event.delta }
              : item,
          ),
        );
        return;

      case "assistant.reasoning_delta":
        if (!turnId || typeof event.delta !== "string") return;
        patchTurn(turnId, (current) => {
          const index = current.findIndex(
            (item) => item.kind === "reasoning" && item.turnId === turnId,
          );
          if (index < 0) {
            return [
              ...current,
              { kind: "reasoning", turnId, text: event.delta as string },
            ];
          }
          return current.map((item, itemIndex) =>
            itemIndex === index && item.kind === "reasoning"
              ? { ...item, text: item.text + (event.delta as string) }
              : item,
          );
        });
        return;

      case "tool.started":
        if (
          !turnId ||
          typeof event.tool_call_id !== "string" ||
          typeof event.tool_name !== "string"
        )
          return;
        setItems((current) => [
          ...current,
          {
            kind: "tool",
            turnId,
            callId: event.tool_call_id as string,
            name: event.tool_name as string,
            status: "running",
            detail:
              event.arguments === undefined
                ? ""
                : JSON.stringify(event.arguments, null, 2),
          },
        ]);
        return;

      case "tool.completed":
        if (typeof event.tool_call_id !== "string") return;
        setItems((current) =>
          current.map((item) =>
            item.kind === "tool" && item.callId === event.tool_call_id
              ? {
                  ...item,
                  status: event.is_error ? "error" : "done",
                  detail:
                    typeof event.result === "string"
                      ? event.result
                      : item.detail,
                }
              : item,
          ),
        );
        return;

      case "turn.completed":
        if (!turnId) return;
        setBusy(false);
        patchTurn(turnId, (current) =>
          current.map((item) =>
            item.kind === "assistant" && item.turnId === turnId
              ? {
                  ...item,
                  text:
                    item.text ||
                    (typeof event.text === "string" ? event.text : ""),
                  streaming: false,
                }
              : item,
          ),
        );
        return;

      case "turn.failed":
        setBusy(false);
        setItems((current) => [
          ...current.map((item) =>
            item.kind === "assistant" && item.turnId === turnId
              ? { ...item, streaming: false }
              : item,
          ),
          {
            kind: "error",
            turnId,
            text:
              typeof event.message === "string"
                ? event.message
                : "Turn failed",
          },
        ]);
        return;

      case "protocol.error":
        setItems((current) => [
          ...current,
          {
            kind: "error",
            turnId,
            text:
              typeof event.message === "string"
                ? event.message
                : "Protocol error",
          },
        ]);
        return;
    }
  };

  const dispose = runtime.onEvent(onEvent);
  onCleanup(dispose);

  const textVolume = () =>
    items().reduce(
      (total, item) =>
        total +
        ("text" in item ? item.text.length : 0) +
        ("detail" in item ? item.detail.length : 0),
      0,
    );

  createEffect(
    () => textVolume(),
    () => {
      if (atBottom() && scrollRef) {
        scrollRef.scrollTo({ top: scrollRef.scrollHeight });
      }
    },
  );

  const send = () => {
    const text = prompt().trim();
    if (!text || busy() || runtime.core() !== "ready") return;
    const sent = runtime.realtime.send({ type: "turn.start", prompt: text });
    if (sent) {
      setPrompt("");
      if (composerRef) composerRef.style.height = "auto";
    }
  };

  const abort = () => {
    runtime.realtime.send({ type: "turn.abort" });
  };

  const onInput: JSX.EventHandler<HTMLTextAreaElement, InputEvent> = (event) => {
    setPrompt(event.currentTarget.value);
    const el = event.currentTarget;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 208)}px`;
  };

  const onKeyDown: JSX.EventHandler<HTMLTextAreaElement, KeyboardEvent> = (
    event,
  ) => {
    if (event.key !== "Enter" || event.shiftKey) return;
    event.preventDefault();
    send();
  };

  const onScroll = () => {
    if (!scrollRef) return;
    setAtBottom(
      scrollRef.scrollHeight - scrollRef.scrollTop - scrollRef.clientHeight <
        80,
    );
  };

  return (
    <div class="flex h-full min-h-0 flex-col">
      <div
        ref={scrollRef}
        onScroll={onScroll}
        class="scroll-slim min-h-0 flex-1 overflow-y-auto"
      >
        <div class="mx-auto w-full max-w-3xl px-5 py-6">
          <Show
            when={items().length > 0}
            fallback={
              <EmptyState
                ready={runtime.core() === "ready"}
                onPick={(text) => {
                  setPrompt(text);
                  composerRef?.focus();
                }}
              />
            }
          >
            <div class="space-y-4 pb-2">
              <For each={items()}>
                {(item) => <TranscriptItemView item={item} />}
              </For>
            </div>
          </Show>
        </div>
      </div>

      <div class="shrink-0 border-t border-line bg-panel/50 backdrop-blur">
        <div class="mx-auto w-full max-w-3xl px-5 pb-4 pt-3">
          <div class="rounded-2xl border border-line-strong bg-raised shadow-lg shadow-black/25 transition-colors focus-within:border-accent/40">
            <textarea
              ref={composerRef}
              value={prompt()}
              onInput={onInput}
              onKeyDown={onKeyDown}
              rows={1}
              disabled={runtime.core() !== "ready"}
              placeholder={
                runtime.core() === "ready"
                  ? "Ask Cetas to change something…"
                  : "Finish Cetas setup before starting a turn…"
              }
              class="scroll-slim block max-h-52 w-full resize-none bg-transparent px-4 py-3.5 text-sm leading-6 text-fg outline-none placeholder:text-fg-faint disabled:opacity-50"
            />
            <div class="flex items-center justify-between gap-3 px-3 pb-2.5">
              <span class="font-mono text-[11px] text-fg-faint">
                {busy()
                  ? "turn running · streamed from the MoonBit host"
                  : "Enter to send · Shift+Enter for newline"}
              </span>
              <Show
                when={busy()}
                fallback={
                  <button
                    onClick={send}
                    disabled={
                      !prompt().trim() ||
                      runtime.core() !== "ready" ||
                      runtime.socket() !== "online"
                    }
                    class="grid size-8 place-items-center rounded-xl bg-accent text-canvas transition hover:bg-accent-strong disabled:opacity-30"
                    title="Send"
                  >
                    <Send size={15} />
                  </button>
                }
              >
                <button
                  onClick={abort}
                  class="grid size-8 place-items-center rounded-xl border border-bad/30 bg-bad/10 text-bad transition hover:bg-bad/20"
                  title="Abort turn"
                >
                  <Square size={12} fill="currentColor" />
                </button>
              </Show>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function EmptyState(props: { ready: boolean; onPick: (text: string) => void }) {
  return (
    <div class="flex min-h-[52vh] flex-col items-center justify-center text-center">
      <div class="grid size-12 place-items-center rounded-2xl border border-accent/20 bg-accent-dim text-accent">
        <Waves size={22} />
      </div>
      <h1 class="mt-5 text-2xl font-semibold tracking-[-0.02em] text-fg">
        What should Cetas work on?
      </h1>
      <p class="mt-2 max-w-md text-sm leading-6 text-fg-muted">
        Turns run in the MoonBit host. Reasoning, tool calls, and replies
        stream back over the realtime channel.
      </p>
      <Show when={props.ready}>
        <div class="mt-7 flex flex-wrap justify-center gap-2">
          {suggestions.map((text) => (
            <button
              onClick={() => props.onPick(text)}
              class="rounded-full border border-line bg-panel px-3.5 py-2 text-xs text-fg-muted transition-colors hover:border-line-strong hover:bg-raised hover:text-fg"
            >
              {text}
            </button>
          ))}
        </div>
      </Show>
      <p class="mt-7 font-mono text-[11px] text-fg-faint">
        {props.ready
          ? "Enter to send · Shift+Enter for newline"
          : "Finish Cetas setup before starting a turn"}
      </p>
    </div>
  );
}

function TranscriptItemView(props: { item: TranscriptItem }) {
  return (
    <div class="animate-rise">
      <Switch>
        <Match when={props.item.kind === "user"}>
          <div class="flex justify-end">
            <div class="max-w-[82%] rounded-2xl rounded-br-md border border-line bg-raised px-4 py-2.5 text-sm leading-6 text-fg">
              {(props.item as Extract<TranscriptItem, { kind: "user" }>).text}
            </div>
          </div>
        </Match>
        <Match when={props.item.kind === "assistant"}>
          <div class="max-w-3xl whitespace-pre-wrap text-[15px] leading-7 text-fg">
            {(props.item as Extract<TranscriptItem, { kind: "assistant" }>)
              .text}
            <Show
              when={
                (props.item as Extract<TranscriptItem, { kind: "assistant" }>)
                  .streaming
              }
            >
              <span class="ml-1 inline-block h-4 w-[3px] translate-y-0.5 animate-caret rounded-full bg-accent align-middle" />
            </Show>
          </div>
        </Match>
        <Match when={props.item.kind === "reasoning"}>
          <details class="group rounded-xl border border-line bg-panel/60">
            <summary class="flex cursor-pointer select-none items-center gap-2 px-3.5 py-2.5 text-xs font-medium text-fg-muted [&::-webkit-details-marker]:hidden">
              <Brain size={13} class="text-fg-faint" />
              Reasoning
              <ChevronDown
                size={13}
                class="ml-auto text-fg-faint transition-transform group-open:rotate-180"
              />
            </summary>
            <div class="whitespace-pre-wrap border-t border-line px-3.5 py-3 text-xs leading-5 text-fg-muted">
              {(props.item as Extract<TranscriptItem, { kind: "reasoning" }>)
                .text}
            </div>
          </details>
        </Match>
        <Match when={props.item.kind === "tool"}>
          <ToolView
            item={props.item as Extract<TranscriptItem, { kind: "tool" }>}
          />
        </Match>
        <Match when={props.item.kind === "error"}>
          <div class="flex items-start gap-2.5 rounded-xl border border-bad/25 bg-bad/10 px-4 py-3 text-xs leading-5 text-bad">
            <TriangleAlert size={14} class="mt-0.5 shrink-0" />
            <span class="min-w-0 whitespace-pre-wrap">
              {(props.item as Extract<TranscriptItem, { kind: "error" }>).text}
            </span>
          </div>
        </Match>
      </Switch>
    </div>
  );
}

function ToolView(props: {
  item: Extract<TranscriptItem, { kind: "tool" }>;
}) {
  const statusTone = () =>
    props.item.status === "done"
      ? "text-accent"
      : props.item.status === "error"
        ? "text-bad"
        : "text-fg-muted";

  return (
    <div class="overflow-hidden rounded-xl border border-line bg-panel/60">
      <div class="flex items-center gap-2.5 border-b border-line px-3.5 py-2.5">
        <span class="grid size-6 shrink-0 place-items-center rounded-md bg-raised text-fg-muted">
          <Wrench size={12} />
        </span>
        <span class="min-w-0 truncate font-mono text-xs text-fg">
          {props.item.name}
        </span>
        <span
          class={`ml-auto flex shrink-0 items-center gap-1.5 text-[11px] font-medium ${statusTone()}`}
        >
          <span
            class={`size-1.5 rounded-full bg-current ${props.item.status === "running" ? "animate-breathe" : "opacity-80"}`}
          />
          {props.item.status}
        </span>
      </div>
      <pre class="scroll-slim max-h-56 overflow-auto whitespace-pre-wrap px-3.5 py-3 font-mono text-[11px] leading-5 text-fg-muted">
        {props.item.detail || "waiting for result…"}
      </pre>
    </div>
  );
}
