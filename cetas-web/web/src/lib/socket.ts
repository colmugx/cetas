import { websocketUrl } from "./api";
import { desktopBridge, type DesktopBridge } from "./transport";

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
  const bridge = desktopBridge();
  return bridge ? createDesktopClient(bridge, onStateChange) : createSocketClient(onStateChange);
}

/**
 * Desktop transport: the console core broadcasts protocol frames over the
 * bridge's `hub` event; client messages are routed to registered commands.
 */
function createDesktopClient(
  bridge: DesktopBridge,
  onStateChange: (state: RealtimeState) => void,
): RealtimeClient {
  const handlers = new Set<(event: ServerEvent) => void>();
  // The bridge only exists inside a live Proton window, so presence = online.
  onStateChange("online");

  bridge.on("hub", (payload) => {
    try {
      const event = (
        typeof payload === "string" ? JSON.parse(payload) : payload
      ) as ServerEvent;
      handlers.forEach((handler) => handler(event));
    } catch {
      // One malformed frame must not kill the app shell.
    }
  });

  return {
    get state(): RealtimeState {
      return "online";
    },
    send(message) {
      const [name, args] = commandForMessage(message);
      bridge
        .command(name, args)
        .then((payload) => {
          if (payload && typeof payload === "object" && "error" in payload) {
            handlers.forEach((handler) =>
              handler({
                type: "protocol.error",
                message: String((payload as { error: unknown }).error),
              }),
            );
          }
        })
        .catch((error) => {
          // Command rejections play the same role WS protocol errors do on
          // the web: surfaced in the transcript, never thrown at the caller.
          handlers.forEach((handler) =>
            handler({ type: "protocol.error", message: String(error) }),
          );
        });
      return true;
    },
    onEvent(handler) {
      handlers.add(handler);
      return () => handlers.delete(handler);
    },
  };
}

/**
 * MoonBit option fields decode missing keys as None but reject explicit
 * null, so the bridge boundary strips absent values before they serialize.
 */
function compact(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    if (value !== undefined && value !== null) out[key] = value;
  }
  return out;
}

function commandForMessage(
  message: Record<string, unknown>,
): [string, Record<string, unknown>] {
  switch (message.type) {
    case "session.attach":
      return ["attach", {}];
    case "turn.start":
      return [
        "turn_start",
        compact({ prompt: message.prompt, session_id: message.session_id }),
      ];
    case "turn.abort":
      return ["turn_abort", compact({ session_id: message.session_id })];
    case "session.compact":
      return ["session_compact", {}];
    case "status.refresh":
      return ["status_refresh", compact({ session_id: message.session_id })];
    case "ui.response": {
      const { type: _type, request_id, ...rest } = message;
      return ["ui_response", compact({ request_id, ...rest })];
    }
    default:
      return ["unsupported", { requested: String(message.type) }];
  }
}

/** Web transport: one WebSocket carrying both directions. */
function createSocketClient(
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
