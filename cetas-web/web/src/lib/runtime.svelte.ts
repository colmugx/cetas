import type { RealtimeClient, RealtimeState, ServerEvent } from "./socket";
import { createRealtimeClient } from "./socket";
import { probeHealth, probeRuntime, type Health, type RuntimeSnapshot } from "./api";

export type ConnectionState = "checking" | "online" | "offline";
export type CoreState = "checking" | "ready" | "needs_setup" | "offline";

class RuntimeStore {
  health = $state<Health | null>(null);
  runtime = $state<RuntimeSnapshot | null>(null);
  http = $state<ConnectionState>("checking");
  socketState = $state<RealtimeState>("connecting");
  realtime: RealtimeClient;

  constructor() {
    this.realtime = createRealtimeClient((state) => {
      this.socketState = state;
    });
    this.realtime.onEvent((event) => this.onRealtimeEvent(event));
    void this.refresh();
  }

  core: CoreState = $derived.by(() => {
    const snapshot = this.runtime;
    if (snapshot) return snapshot.status;
    return this.http === "offline" ? "offline" : "checking";
  });

  private onRealtimeEvent(event: ServerEvent) {
    if (event.type !== "session.snapshot") return;
    const current = this.runtime;
    this.runtime = {
      status: "ready",
      session_id:
        typeof event.session_id === "string"
          ? event.session_id
          : (current?.session_id ?? ""),
      model: typeof event.model === "string" ? event.model : (current?.model ?? ""),
      effort: typeof event.effort === "string" ? event.effort : (current?.effort ?? ""),
      cwd: typeof event.cwd === "string" ? event.cwd : (current?.cwd ?? ""),
      permission:
        typeof event.permission === "string"
          ? event.permission
          : (current?.permission ?? ""),
      detail: "",
    };
  }

  async refresh() {
    this.http = "checking";
    try {
      const [nextHealth, nextRuntime] = await Promise.all([
        probeHealth(),
        probeRuntime(),
      ]);
      this.health = nextHealth;
      this.runtime = nextRuntime;
      this.http = "online";
    } catch {
      this.http = "offline";
      this.runtime = null;
    }
  }
}

export const runtimeStore = new RuntimeStore();
