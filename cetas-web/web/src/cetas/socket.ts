import { createEffect, createSignal, onCleanup } from "solid-js";
import { websocketUrl } from "./client";

export type ServerEvent = {
  type: string;
  seq?: number;
  event_id?: string;
  session_id?: string;
  turn_id?: string;
  [key: string]: unknown;
};

export type RealtimeClient = {
  state: () => "connecting" | "online" | "offline";
  send: (message: Record<string, unknown>) => boolean;
  onEvent: (handler: (event: ServerEvent) => void) => () => void;
};

export function createRealtimeClient(): RealtimeClient {
  const [state, setState] = createSignal<"connecting" | "online" | "offline">(
    "connecting",
  );
  const handlers = new Set<(event: ServerEvent) => void>();
  let socket: WebSocket | undefined;

  const connect = () => {
    setState("connecting");
    socket = new WebSocket(websocketUrl());

    socket.addEventListener("open", () => {
      setState("online");
      socket?.send(JSON.stringify({ type: "session.attach" }));
    });

    socket.addEventListener("message", (message) => {
      try {
        const event = JSON.parse(String(message.data)) as ServerEvent;
        handlers.forEach((handler) => handler(event));
      } catch {
        // Protocol parse errors are surfaced by the server. Ignore malformed
        // network payloads rather than letting one frame kill the app shell.
      }
    });

    socket.addEventListener("close", () => setState("offline"));
    socket.addEventListener("error", () => setState("offline"));
  };

  createEffect(() => null, () => connect());
  onCleanup(() => socket?.close());

  const api: RealtimeClient = {
    state,
    send(message) {
      if (!socket || socket.readyState !== WebSocket.OPEN) return false;
      socket.send(JSON.stringify(message));
      return true;
    },
    onEvent(handler) {
      handlers.add(handler);
      return () => handlers.delete(handler);
    },
  };

  return api;
}
