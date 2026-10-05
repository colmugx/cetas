import { websocketUrl } from "./api";

export type ServerEvent = {
  type: string;
  seq?: number;
  event_id?: string;
  session_id?: string;
  turn_id?: string;
  [key: string]: unknown;
};

export type RealtimeState = "connecting" | "online" | "offline";

export type RealtimeClient = {
  readonly state: RealtimeState;
  send: (message: Record<string, unknown>) => boolean;
  onEvent: (handler: (event: ServerEvent) => void) => () => void;
};

export function createRealtimeClient(
  onStateChange: (state: RealtimeState) => void,
): RealtimeClient {
  const handlers = new Set<(event: ServerEvent) => void>();
  let state: RealtimeState = "connecting";
  let socket: WebSocket | undefined;

  const setState = (next: RealtimeState) => {
    if (state === next) return;
    state = next;
    onStateChange(next);
  };

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
        // One malformed frame must not kill the app shell.
      }
    });

    socket.addEventListener("close", () => setState("offline"));
    socket.addEventListener("error", () => setState("offline"));
  };

  connect();

  return {
    get state() {
      return state;
    },
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
}
