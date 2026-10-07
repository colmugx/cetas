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

  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  let attempts = 0;

  const connect = () => {
    setState("connecting");
    socket = new WebSocket(websocketUrl());

    socket.addEventListener("open", () => {
      attempts = 0;
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

    const scheduleReconnect = () => {
      setState("offline");
      const delay = Math.min(500 * 2 ** attempts, 8000);
      attempts += 1;
      reconnectTimer = setTimeout(connect, delay);
    };
    socket.addEventListener("close", scheduleReconnect);
    socket.addEventListener("error", scheduleReconnect);
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
