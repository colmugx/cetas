import {
  createContext,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
  useContext,
  type Accessor,
} from "solid-js";
import type { JSX } from "@solidjs/web";
import {
  probeHealth,
  probeRuntime,
  websocketUrl,
  type Health,
  type RuntimeSnapshot,
} from "./client";

export type ConnectionState = "checking" | "online" | "offline";

type RuntimeContextValue = {
  health: Accessor<Health | null>;
  runtime: Accessor<RuntimeSnapshot | null>;
  http: Accessor<ConnectionState>;
  socket: Accessor<ConnectionState>;
  core: Accessor<"checking" | "ready" | "needs_setup" | "offline">;
  refresh: () => Promise<void>;
};

const RuntimeContext = createContext<RuntimeContextValue>();

export function RuntimeProvider(props: { children: JSX.Element }) {
  const [health, setHealth] = createSignal<Health | null>(null);
  const [runtime, setRuntime] = createSignal<RuntimeSnapshot | null>(null);
  const [http, setHttp] = createSignal<ConnectionState>("checking");
  const [socket, setSocket] = createSignal<ConnectionState>("checking");

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

  onMount(() => {
    void refresh();

    const ws = new WebSocket(websocketUrl());
    ws.addEventListener("open", () => setSocket("online"));
    ws.addEventListener("close", () => setSocket("offline"));
    ws.addEventListener("error", () => setSocket("offline"));

    onCleanup(() => ws.close());
  });

  return (
    <RuntimeContext
      value={{ health, runtime, http, socket, core, refresh }}
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
