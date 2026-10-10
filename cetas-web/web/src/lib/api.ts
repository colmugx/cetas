import { consoleCommand } from "./transport";
import type { TranscriptItem } from "./transcript";

export type Health = {
  status: string;
  host: string;
  protocol: string;
};

export type RuntimeSnapshot = {
  status: "ready" | "needs_setup";
  session_id: string;
  model: string;
  effort: string;
  cwd: string;
  permission: string;
  detail: string;
};

export type SessionSummary = {
  id: string;
  title: string;
  active: boolean;
};

export type SessionList = {
  active: string;
  cwd: string;
  sessions: SessionSummary[];
};

export type WorkspaceInfo = {
  cwd: string;
  name: string;
  active: boolean;
  active_session: string;
};

export type WorkspaceList = {
  active: string;
  workspaces: WorkspaceInfo[];
};

export type ModelSlot = {
  id: string;
  label: string;
  provider: string;
  model: string;
  active: boolean;
  efforts: string[];
  default_effort: string | null;
  group: string | null;
  context_window: number | null;
};

export type ContextState = {
  measured: number | null;
  window: number | null;
  threshold: number;
  messages: number;
};

export type TranscriptReplay = {
  items: TranscriptItem[];
  context: ContextState | null;
};

export type ModelCatalog = {
  active: string;
  effort: string;
  permission: string;
  slots: ModelSlot[];
};

export type ExtRoleItem = {
  label: string;
  detail: string | null;
};

export type ExtRole = {
  role: string;
  count: number;
  items: ExtRoleItem[];
};

export type ExtInfo = {
  id: string;
  roles: ExtRole[];
};

export type ExtZoo = {
  extensions: ExtInfo[];
};

export type TraceEvent = {
  type: string;
  seq: number;
  event_id: string;
  ts?: number;
  session_id?: string;
  turn_id?: string;
  [key: string]: unknown;
};

export type TraceTurn = {
  turn_id: string;
  session_id: string;
  events: TraceEvent[];
};

export type TracePage = {
  turns: TraceTurn[];
  orphans: TraceEvent[];
};

export type Versions = {
  posoco: string;
  cetas: string;
  web: string;
};

async function readJson<T>(
  path: string,
  label: string,
  signal?: AbortSignal,
): Promise<T> {
  const response = await fetch(path, { signal });
  if (!response.ok) {
    throw new Error(`${label} failed: HTTP ${response.status}`);
  }
  return response.json() as Promise<T>;
}

async function postJson<T>(
  path: string,
  body: Record<string, unknown>,
  label: string,
): Promise<T> {
  const response = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const payload = (await response.json().catch(() => null)) as
    | (T & { error?: string })
    | null;
  if (!response.ok) {
    const detail = payload?.error ?? `HTTP ${response.status}`;
    throw new Error(`${label}: ${detail}`);
  }
  return payload as T;
}

export function probeHealth(signal?: AbortSignal): Promise<Health> {
  return consoleCommand("health", {}, () =>
    readJson<Health>("/api/health", "health probe", signal),
  );
}

export function listExts(): Promise<ExtZoo> {
  return consoleCommand("extensions", {}, () =>
    readJson<ExtZoo>("/api/exts", "ext zoo"),
  );
}

export function fetchTrace(
  filters: {
    type?: string;
    session?: string;
    turn?: string;
    limit?: number;
  } = {},
): Promise<TracePage> {
  const args: Record<string, unknown> = {};
  if (filters.session) args.session = filters.session;
  if (filters.turn) args.turn = filters.turn;
  return consoleCommand("trace", args, () => {
    const params = new URLSearchParams();
    if (filters.session) params.set("session", filters.session);
    if (filters.turn) params.set("turn", filters.turn);
    const qs = params.toString();
    return readJson<TracePage>(`/api/trace${qs ? `?${qs}` : ""}`, "trace");
  });
}

export function probeVersions(): Promise<Versions> {
  return consoleCommand("versions", {}, () =>
    readJson<Versions>("/api/versions", "version probe"),
  );
}

export function probeRuntime(signal?: AbortSignal): Promise<RuntimeSnapshot> {
  return consoleCommand("runtime_state", {}, () =>
    readJson<RuntimeSnapshot>("/api/runtime", "runtime probe", signal),
  );
}

export function listSessions(): Promise<SessionList> {
  return consoleCommand("sessions", {}, () =>
    readJson<SessionList>("/api/sessions", "session list"),
  );
}

export function listWorkspaces(): Promise<WorkspaceList> {
  return consoleCommand("workspaces", {}, () =>
    readJson<WorkspaceList>("/api/workspaces", "workspace list"),
  );
}

export function addWorkspace(cwd: string): Promise<WorkspaceList> {
  return consoleCommand("switch_workspace", { cwd }, () =>
    postJson<WorkspaceList>("/api/workspaces", { cwd }, "workspace add"),
  );
}

export function switchSession(id?: string): Promise<{ session_id: string }> {
  return consoleCommand(
    "switch_session",
    id === undefined ? {} : { id },
    () => postJson("/api/session", id === undefined ? {} : { id }, "session switch"),
  );
}

export function fetchTranscript(id: string): Promise<TranscriptReplay> {
  return consoleCommand("session_transcript", { id }, () =>
    readJson<TranscriptReplay>(
      `/api/sessions/${encodeURIComponent(id)}/transcript`,
      "transcript replay",
    ),
  );
}

export function renameSession(id: string, name: string): Promise<unknown> {
  return consoleCommand("session_rename", { id, name }, () =>
    postJson(
      `/api/sessions/${encodeURIComponent(id)}/rename`,
      { name },
      "session rename",
    ),
  );
}

export function listModels(): Promise<ModelCatalog> {
  return consoleCommand("models", {}, () =>
    readJson<ModelCatalog>("/api/models", "model catalog"),
  );
}

export function setModel(slotId: string): Promise<RuntimeSnapshot> {
  return consoleCommand("switch_model", { slot_id: slotId }, () =>
    postJson<RuntimeSnapshot>("/api/model", { slot_id: slotId }, "model switch"),
  );
}

export function setEffort(effort: string): Promise<RuntimeSnapshot> {
  return consoleCommand("select_effort", { effort }, () =>
    postJson<RuntimeSnapshot>("/api/effort", { effort }, "effort switch"),
  );
}

export function setPermission(mode: string): Promise<RuntimeSnapshot> {
  return consoleCommand("set_permission", { mode }, () =>
    postJson<RuntimeSnapshot>("/api/permission", { mode }, "permission switch"),
  );
}

export function websocketUrl(path = "/ws"): string {
  const url = new URL(path, window.location.href);
  url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}
