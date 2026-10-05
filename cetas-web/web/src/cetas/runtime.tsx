import {
  createContext,
  createEffect,
  createMemo,
  createSignal,
  onCleanup,
  useContext,
  type Accessor,
} from "solid-js";
import type { JSX } from "@solidjs/web";
import {
  probeHealth,
  probeRuntime,
  type Health,
  type RuntimeSnapshot,
} from "./client";
import {
  createRealtimeClient,
  type RealtimeClient,
  type ServerEvent,
} from "./socket";

export type ConnectionState = "checking" | "online" | "offline";

type RuntimeContextValue = {
  health: Accessor<Health | null>;
  runtime: Accessor<RuntimeSnapshot | null>;
  http: Accessor<ConnectionState>;
  socket: Accessor<"connecting" | "online" | "offline">;
  core: Accessor<"checking" | "ready" | "needs_setup" | "offline">;
  realtime: RealtimeClient;
  refresh: () => Promise<void>;
  onEvent: (handler: (event: ServerEvent) => void) => () => void;
};

const RuntimeContext = createContext<RuntimeContextValue>();

export function RuntimeProvider(props: { children: JSX.Element }) {
  const [health, setHealth] = createSignal<Health | null>(null);
  const [runtime, setRuntime] = createSignal<RuntimeSnapshot | null>(null);
  const [http, setHttp] = createSignal<ConnectionState>("checking");
  const realtime = createRealtimeClient();

  const core = createMemo<"checking" | "ready" | "needs_setup" | "offline">(
    () => {
      const snapshot = runtime();
      if (snapshot) return snapshot.status;
      return http() === "offline" ? "offline" : "checking";
    },
  );

  const refresh = async () => {
    setHttp("checking");
    const controller = new AbortController();
    try {
      const [nextHealth, nextRuntime] = await Promise.all([
        probeHealth(controller.signal),
        probeRuntime(controller.signal),
      ]);
      setHealth(nextHealth);
      setRuntime(nextRuntime);
      setHttp("online");
    } catch {
      setHttp("offline");
      setRuntime(null);
    }
  };

  const dispose = realtime.onEvent((event) => {
    if (event.type !== "session.snapshot") return;
    setRuntime((current) => ({
      status: "ready",
      session_id:
        typeof event.session_id === "string"
          ? event.session_id
          : current?.session_id ?? "",
      model: typeof event.model === "string" ? event.model : current?.model ?? "",
      effort:
        typeof event.effort === "string" ? event.effort : current?.effort ?? "",
      cwd: typeof event.cwd === "string" ? event.cwd : current?.cwd ?? "",
      detail: "",
    }));
  });
  onCleanup(dispose);
  createEffect(
    () => null,
    () => {
      void refresh();
    },
  );

  return (
    <RuntimeContext
      value={{
        health,
        runtime,
        http,
        socket: realtime.state,
        core,
        realtime,
        refresh,
        onEvent: realtime.onEvent,
      }}
    >
      {props.children}
    </RuntimeContext>
  );
}

export function useCetasRuntime(): RuntimeContextValue {
  const value = useContext(RuntimeContext);
  if (!value) {
    throw new Error("useCetasRuntime must be used inside RuntimeProvider");
  }
  return value;
}
