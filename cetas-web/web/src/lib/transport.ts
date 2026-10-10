/**
 * Transport seam between the console UI and its host.
 *
 * - cetas-web: the host is the Moonback server; commands ride HTTP and
 *   events ride the /ws broadcast (see api.ts / socket.ts web branches).
 * - cetas-desktop: the host is the Proton native app; commands ride the
 *   `window.__MoonBit__` bridge and events ride the `hub` bridge event.
 *
 * Command payloads and event frames are identical in both transports —
 * they are the cetas-console protocol shapes.
 */

type DesktopApp = {
  on: (event: string, handler: (delivery: { payload: unknown }) => void) => () => void;
  [command: string]: unknown;
};

export type DesktopBridge = {
  command: (name: string, args: Record<string, unknown>) => Promise<unknown>;
  on: (
    event: string,
    handler: (payload: unknown) => void,
  ) => () => void;
};

export function desktopBridge(): DesktopBridge | null {
  if (typeof window === "undefined") return null;
  const app = (window as { __MoonBit__?: { app?: DesktopApp } }).__MoonBit__
    ?.app;
  if (!app) return null;
  return {
    command(name, args) {
      const handler = app[name];
      if (typeof handler !== "function") {
        return Promise.reject(new Error(`unknown desktop command: ${name}`));
      }
      return (handler as (a: Record<string, unknown>) => Promise<unknown>).call(
        app,
        args,
      );
    },
    on(event, handler) {
      return app.on(event, (delivery) => handler(delivery?.payload ?? delivery));
    },
  };
}

/**
 * Run one console operation. On the desktop bridge the command name is the
 * registered contract name; in the browser the caller's HTTP fallback runs.
 * Bridge responses shaped `{ error }` reject like the HTTP branch does.
 */
export function consoleCommand<T>(
  name: string,
  args: Record<string, unknown>,
  http: () => Promise<T>,
): Promise<T> {
  const bridge = desktopBridge();
  if (!bridge) return http();
  return bridge.command(name, args).then((payload) => {
    if (payload && typeof payload === "object" && "error" in payload) {
      throw new Error(String((payload as { error: unknown }).error));
    }
    return payload as T;
  });
}
