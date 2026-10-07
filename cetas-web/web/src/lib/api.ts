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

import type { TranscriptItem } from "./transcript";

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
  return readJson<Health>("/api/health", "health probe", signal);
}

export function listExts(): Promise<ExtZoo> {
  return readJson<ExtZoo>("/api/exts", "ext zoo");
}

export function fetchTrace(
  filters: {
    type?: string;
    session?: string;
    turn?: string;
    limit?: number;
  } = {},
): Promise<TracePage> {
  const params = new URLSearchParams();
  if (filters.type) params.set("type", filters.type);
  if (filters.session) params.set("session", filters.session);
  if (filters.turn) params.set("turn", filters.turn);
  if (filters.limit) params.set("limit", String(filters.limit));
  const qs = params.toString();
  return readJson<TracePage>(`/api/trace${qs ? `?${qs}` : ""}`, "trace");
}

export function probeVersions(): Promise<Versions> {
  return readJson<Versions>("/api/versions", "version probe");
}

export function probeRuntime(signal?: AbortSignal): Promise<RuntimeSnapshot> {
  return readJson<RuntimeSnapshot>("/api/runtime", "runtime probe", signal);
}

export function listSessions(): Promise<SessionList> {
  return readJson<SessionList>("/api/sessions", "session list");
}

export function listWorkspaces(): Promise<WorkspaceList> {
  return readJson<WorkspaceList>("/api/workspaces", "workspace list");
}

export function addWorkspace(cwd: string): Promise<WorkspaceList> {
  return postJson("/api/workspaces", { cwd }, "workspace add");
}

export function switchSession(id?: string): Promise<{ session_id: string }> {
  return postJson("/api/session", id === undefined ? {} : { id }, "session switch");
}

export function fetchTranscript(id: string): Promise<TranscriptReplay> {
  return readJson<TranscriptReplay>(
    `/api/sessions/${encodeURIComponent(id)}/transcript`,
    "transcript replay",
  );
}

export function renameSession(id: string, name: string): Promise<unknown> {
  return postJson(
    `/api/sessions/${encodeURIComponent(id)}/rename`,
    { name },
    "session rename",
  );
}

export function listModels(): Promise<ModelCatalog> {
  return readJson<ModelCatalog>("/api/models", "model catalog");
}

export function setModel(slotId: string): Promise<RuntimeSnapshot> {
  return postJson("/api/model", { slot_id: slotId }, "model switch");
}

export function setEffort(effort: string): Promise<RuntimeSnapshot> {
  return postJson("/api/effort", { effort }, "effort switch");
}

export function setPermission(mode: string): Promise<RuntimeSnapshot> {
  return postJson("/api/permission", { mode }, "permission switch");
}

export function websocketUrl(path = "/ws"): string {
  const url = new URL(path, window.location.href);
  url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}
