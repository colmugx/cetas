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
  detail: string;
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

export function probeHealth(signal?: AbortSignal): Promise<Health> {
  return readJson<Health>("/api/health", "health probe", signal);
}

export function probeRuntime(signal?: AbortSignal): Promise<RuntimeSnapshot> {
  return readJson<RuntimeSnapshot>("/api/runtime", "runtime probe", signal);
}

export function websocketUrl(path = "/ws"): string {
  const url = new URL(path, window.location.href);
  url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}
