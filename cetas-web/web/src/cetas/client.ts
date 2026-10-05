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

export type ModelCatalog = {
  active: string;
  effort: string;
  permission: string;
  slots: ModelSlot[];
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

export function probeRuntime(signal?: AbortSignal): Promise<RuntimeSnapshot> {
  return readJson<RuntimeSnapshot>("/api/runtime", "runtime probe", signal);
}

export function listSessions(): Promise<SessionList> {
  return readJson<SessionList>("/api/sessions", "session list");
}

export function switchSession(id?: string): Promise<{ session_id: string }> {
  return postJson("/api/session", id === undefined ? {} : { id }, "session switch");
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
