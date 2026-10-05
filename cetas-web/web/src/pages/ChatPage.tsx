import {
  Brain,
  Cable,
  Cpu,
  GitBranch,
  Send,
  Square,
  TerminalSquare,
  Wrench,
} from "@lucide/solid";
import { For, Show, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import type { JSX } from "@solidjs/web";
import { useCetasRuntime } from "../cetas/runtime";
import type { ServerEvent } from "../cetas/socket";
import { StatusPill } from "../ui/StatusPill";

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

export default function ChatPage() {
  const runtime = useCetasRuntime();
  const snapshot = () => runtime.runtime();
  const [prompt, setPrompt] = createSignal("");
  const [items, setItems] = createSignal<TranscriptItem[]>([]);
  const [busy, setBusy] = createSignal(false);
  const [lastSeq, setLastSeq] = createSignal(0);

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

  onMount(() => {
    const dispose = runtime.onEvent(onEvent);
    onCleanup(dispose);
  });

  const send = () => {
    const text = prompt().trim();
    if (!text || busy() || runtime.core() !== "ready") return;
    const sent = runtime.realtime.send({ type: "turn.start", prompt: text });
    if (sent) setPrompt("");
  };

  const abort = () => {
    runtime.realtime.send({ type: "turn.abort" });
  };

  const onKeyDown: JSX.EventHandler<HTMLTextAreaElement, KeyboardEvent> = (
    event,
  ) => {
    if (event.key !== "Enter" || event.shiftKey) return;
    event.preventDefault();
    send();
  };

  return (
    <div class="mx-auto flex min-h-[calc(100vh-3.5rem)] w-full max-w-6xl flex-col px-4 py-5 md:px-6">
      <section class="grid gap-3 xl:grid-cols-[minmax(0,1fr)_310px]">
        <div class="rounded-2xl border border-zinc-800 bg-zinc-900/35 p-5 md:p-7">
          <div class="mb-8 flex items-center justify-between gap-3">
            <StatusPill tone={runtime.core() === "ready" ? "good" : "warn"}>
              cetas-core {runtime.core()}
            </StatusPill>
            <span class="font-mono text-[10px] uppercase tracking-[0.16em] text-zinc-600">
              realtime v0.1
            </span>
          </div>

          <div class="max-w-2xl">
            <h1 class="text-3xl font-semibold tracking-[-0.035em] text-zinc-50 md:text-4xl">
              The same Cetas, now live in the browser.
            </h1>
            <p class="mt-3 max-w-xl text-sm leading-6 text-zinc-400">
              Turns run inside the MoonBit host. The browser receives typed
              lifecycle, reasoning, text, and tool events over WebSocket.
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
            <Inspector label="last seq" value={String(lastSeq())} />
          </dl>
        </aside>
      </section>

      <section class="mt-3 flex min-h-[360px] flex-1 flex-col rounded-2xl border border-zinc-800 bg-zinc-950/35 px-4 py-5 md:px-6">
        <Show
          when={items().length > 0}
          fallback={
            <div class="flex flex-1 flex-col items-center justify-center text-center">
              <div class="grid size-11 place-items-center rounded-xl border border-zinc-800 bg-zinc-900 text-zinc-300">
                <Brain size={19} />
              </div>
              <h2 class="mt-4 text-sm font-medium text-zinc-200">
                Start the first Web turn
              </h2>
              <p class="mt-1 max-w-md text-xs leading-5 text-zinc-500">
                Shift+Enter adds a newline. Enter submits to cetas-core.
              </p>
            </div>
          }
        >
          <div class="space-y-5">
            <For each={items()}>
              {(item) => <TranscriptItemView item={item} />}
            </For>
          </div>
        </Show>
      </section>

      <section class="sticky bottom-0 mt-3 pb-3 pt-2">
        <div class="rounded-2xl border border-zinc-700/80 bg-zinc-900/95 p-2 shadow-2xl shadow-black/30 backdrop-blur">
          <textarea
            value={prompt()}
            onInput={(event) => setPrompt(event.currentTarget.value)}
            onKeyDown={onKeyDown}
            rows={3}
            disabled={runtime.core() !== "ready"}
            placeholder={
              runtime.core() === "ready"
                ? "Ask Cetas to change something…"
                : "Finish Cetas setup before starting a turn…"
            }
            class="w-full resize-none bg-transparent px-3 py-2 text-sm leading-6 text-zinc-200 outline-none placeholder:text-zinc-600 disabled:opacity-50"
          />
          <div class="flex items-center justify-between gap-3 px-2 pb-1">
            <span class="font-mono text-[10px] text-zinc-600">
              {busy()
                ? "turn running · streamed from MoonBit"
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
                  class="grid size-8 place-items-center rounded-lg bg-zinc-100 text-zinc-950 disabled:opacity-30"
                  title="Send"
                >
                  <Send size={15} />
                </button>
              }
            >
              <button
                onClick={abort}
                class="grid size-8 place-items-center rounded-lg border border-rose-500/30 bg-rose-500/10 text-rose-300"
                title="Abort turn"
              >
                <Square size={13} fill="currentColor" />
              </button>
            </Show>
          </div>
        </div>
      </section>
    </div>
  );
}

function TranscriptItemView(props: { item: TranscriptItem }) {
  const item = () => props.item;

  return (
    <Show
      when={item().kind !== "user"}
      fallback={
        <div class="flex justify-end">
          <div class="max-w-[82%] rounded-2xl rounded-br-md bg-zinc-100 px-4 py-3 text-sm leading-6 text-zinc-950">
            {(item() as Extract<TranscriptItem, { kind: "user" }>).text}
          </div>
        </div>
      }
    >
      <Show
        when={item().kind === "assistant"}
        fallback={
          <Show
            when={item().kind === "reasoning"}
            fallback={
              <Show
                when={item().kind === "tool"}
                fallback={
                  <div class="rounded-xl border border-rose-500/20 bg-rose-500/5 px-4 py-3 font-mono text-xs leading-5 text-rose-300">
                    {(item() as Extract<TranscriptItem, { kind: "error" }>).text}
                  </div>
                }
              >
                <ToolView item={item() as Extract<TranscriptItem, { kind: "tool" }>} />
              </Show>
            }
          >
            <div class="rounded-xl border border-zinc-800 bg-zinc-900/40 px-4 py-3 text-xs leading-5 text-zinc-500">
              <div class="mb-2 flex items-center gap-2 font-medium text-zinc-400">
                <Brain size={14} />
                Reasoning
              </div>
              <div class="whitespace-pre-wrap">
                {(item() as Extract<TranscriptItem, { kind: "reasoning" }>).text}
              </div>
            </div>
          </Show>
        }
      >
        <div class="max-w-3xl whitespace-pre-wrap text-sm leading-7 text-zinc-200">
          {(item() as Extract<TranscriptItem, { kind: "assistant" }>).text}
          {(item() as Extract<TranscriptItem, { kind: "assistant" }>).streaming && (
            <span class="ml-1 inline-block h-4 w-1 animate-pulse bg-zinc-500 align-middle" />
          )}
        </div>
      </Show>
    </Show>
  );
}

function ToolView(props: {
  item: Extract<TranscriptItem, { kind: "tool" }>;
}) {
  return (
    <div class="overflow-hidden rounded-xl border border-zinc-800 bg-zinc-900/45">
      <div class="flex items-center justify-between gap-3 border-b border-zinc-800 px-4 py-2.5">
        <div class="flex items-center gap-2 text-xs font-medium text-zinc-300">
          <Wrench size={14} />
          {props.item.name}
        </div>
        <StatusPill
          tone={
            props.item.status === "done"
              ? "good"
              : props.item.status === "error"
                ? "bad"
                : "neutral"
          }
        >
          {props.item.status}
        </StatusPill>
      </div>
      <pre class="max-h-64 overflow-auto whitespace-pre-wrap px-4 py-3 font-mono text-[11px] leading-5 text-zinc-500">
        {props.item.detail || "waiting for result…"}
      </pre>
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
