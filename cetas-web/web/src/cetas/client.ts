export type Health = {
  status: string;
  host: string;
  protocol: string;
};

export async function probeHealth(signal?: AbortSignal): Promise<Health> {
  const response = await fetch("/api/health", { signal });
  if (!response.ok) {
    throw new Error(`health probe failed: HTTP ${response.status}`);
  }
  return response.json() as Promise<Health>;
}

export function websocketUrl(path = "/ws"): string {
  const url = new URL(path, window.location.href);
  url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return url.toString();
}
