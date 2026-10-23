/**
 * Localhost presentation of the authoritative BoardWorkflows backend.
 *
 * The browser app is the same Rabbita build used by the native Board host;
 * this file is only the Bun transport adapter. It serves the app, relays the
 * Board wire protocol over WebSocket, and translates the shared backend's
 * snapshots and commands. No second task projection lives here.
 */
import { randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import type { CetasApplication } from "../src/app/application.ts";
import {
  BOARD_CSS,
  BOARD_HTML,
  BOARD_JS,
} from "./board-assets.generated.ts";

interface BoardSocketData {
  queue: Promise<void>;
}

interface BoardSocket {
  send(data: string): void;
  data: BoardSocketData;
}

interface BoardState {
  clients: Set<BoardSocket>;
  lastRevision: number | null;
  lastTickets: string | null;
  seenQuestions: Set<string>;
  seenResults: Set<string>;
  timer?: ReturnType<typeof setInterval>;
  ticketTimer?: ReturnType<typeof setInterval>;
}

interface BoardServer {
  server: ReturnType<typeof Bun.serve>;
  url: string;
  token: string;
  state: BoardState;
  closed: boolean;
}

const boards = new WeakMap<CetasApplication, BoardServer>();
const owners = new Set<BoardServer>();

const SECURITY_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Access-Control-Allow-Origin": "null",
};

const CSP =
  "default-src 'none'; " +
  "script-src 'self'; " +
  "style-src 'self' 'unsafe-inline'; " +
  "img-src 'self' data:; " +
  "connect-src 'self' ws://127.0.0.1:* ws://localhost:*; " +
  "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function respond(
  body: string,
  contentType: string,
  status = 200,
): Response {
  return new Response(body, {
    status,
    headers: { ...SECURITY_HEADERS, "Content-Type": contentType },
  });
}

function fail(res: number): Response {
  return respond("Request denied", "text/plain; charset=utf-8", res);
}

function isLoopbackHost(host: string | null, port: number): boolean {
  return host === "127.0.0.1:" + port || host === "localhost:" + port;
}

function openInBrowser(url: string): void {
  const platform = process.platform;
  const executable = platform === "win32" ? "cmd" : platform === "darwin" ? "open" : "xdg-open";
  const args = platform === "win32" ? ["/c", "start", "", url] : [url];
  const child = spawn(executable, args, { detached: true, stdio: "ignore", windowsHide: true });
  child.on("error", () => undefined); // The printed URL is a usable fallback.
  child.unref();
}

function parseStructured(raw: string): Record<string, unknown> {
  const outcome = JSON.parse(raw) as {
    type?: string;
    reason?: string;
    structured?: unknown;
  };
  if (outcome.type !== "success") {
    throw new Error(outcome.reason ?? "Board command failed");
  }
  if (
    typeof outcome.structured !== "object" ||
    outcome.structured === null ||
    Array.isArray(outcome.structured)
  ) {
    throw new Error("Board command returned no structured payload");
  }
  return outcome.structured as Record<string, unknown>;
}

async function invokeStructured(
  app: CetasApplication,
  id: string,
  args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return parseStructured(await app.invokeCommand(id, JSON.stringify(args)));
}

async function invokeSuccess(
  app: CetasApplication,
  id: string,
  args: Record<string, unknown>,
): Promise<void> {
  const outcome = JSON.parse(await app.invokeCommand(id, JSON.stringify(args))) as {
    type?: string;
    reason?: string;
  };
  if (outcome.type !== "success") {
    throw new Error(outcome.reason ?? "Board command failed");
  }
}

async function invokeFrame(
  app: CetasApplication,
  id: string,
  args: Record<string, unknown>,
): Promise<string> {
  const structured = await invokeStructured(app, id, args);
  const frame = structured.frame;
  if (typeof frame !== "string") {
    throw new Error("Board wire command returned no frame");
  }
  return frame;
}

async function readSnapshot(
  app: CetasApplication,
): Promise<{ frame: string; revision: number }> {
  const frame = await invokeFrame(app, "board.wire.snapshot", {});
  const parsed = JSON.parse(frame) as { board_revision?: unknown };
  return {
    frame,
    revision: typeof parsed.board_revision === "number" ? parsed.board_revision : 0,
  };
}

function failureFrame(raw: string, error: unknown): string {
  let commandId = "";
  try {
    const parsed = JSON.parse(raw) as { command_id?: unknown };
    if (typeof parsed.command_id === "string") commandId = parsed.command_id;
  } catch {
    // Keep the empty correlation id; the client ignores unmatched results.
  }
  return JSON.stringify({
    type: "command_result",
    command_id: commandId,
    accepted: false,
    error: "board_unavailable",
    current_revision: null,
    detail: error instanceof Error ? error.message : String(error),
  });
}

export interface WorkflowBoardOptions {
  onOpen?: (url: string) => void;
  /** One concise line for the host transcript when ticket work changes. */
  onTicketActivity?: (text: string) => void;
}

export async function openWorkflowBoard(
  app: CetasApplication,
  options?: WorkflowBoardOptions,
): Promise<string> {
  const previous = boards.get(app);
  if (previous !== undefined && !previous.closed) {
    if (options?.onOpen) options.onOpen(previous.url);
    else openInBrowser(previous.url);
    return previous.url.split("?")[0]!;
  }

  // Attach the shared backend before the first snapshot is requested. This is
  // the same backend the planner and execution owner use; the dashboard is a
  // view, never a second authority.
  await invokeSuccess(app, "board.wire.ready", {});

  const token = randomBytes(32).toString("hex");
  const state: BoardState = {
    clients: new Set(),
    lastRevision: null,
    lastTickets: null,
    seenQuestions: new Set(),
    seenResults: new Set(),
  };

  function activity(text: string): void {
    options?.onTicketActivity?.(text);
  }

  function shorten(text: string, max = 140): string {
    const oneLine = text.replace(/\s+/g, " ").trim();
    return oneLine.length <= max ? oneLine : oneLine.slice(0, max - 1) + "…";
  }

  function observeTicketState(raw: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return;
    }
    if (typeof parsed !== "object" || parsed === null) return;
    const record = parsed as Record<string, unknown>;
    const questions = record.questions;
    if (Array.isArray(questions)) {
      for (const item of questions) {
        if (typeof item !== "object" || item === null) continue;
        const question = item as Record<string, unknown>;
        const id = typeof question.id === "string" ? question.id : "";
        if (!id || state.seenQuestions.has(id)) continue;
        state.seenQuestions.add(id);
        const taskId = typeof question.task_id === "string" ? question.task_id : "ticket";
        const prompt = typeof question.question === "string" ? question.question : "needs your answer";
        activity(`Worker needs your answer on ${taskId}: ${shorten(prompt)}`);
      }
    }
    const runs = record.runs;
    if (Array.isArray(runs)) {
      for (const item of runs) {
        if (typeof item !== "object" || item === null) continue;
        const run = item as Record<string, unknown>;
        const taskId = typeof run.task_id === "string" ? run.task_id : "ticket";
        const phase = typeof run.phase === "string" ? run.phase : "work";
        const status = typeof run.status === "string" ? run.status : "";
        const result = typeof run.result === "string" ? run.result : "";
        if (result !== "") {
          const key = `${taskId}:${phase}:${result}`;
          if (!state.seenResults.has(key)) {
            state.seenResults.add(key);
            activity(
              phase === "shape"
                ? result.startsWith("Split into ")
                  ? `Shaping split ${taskId} into independent Ready tickets: ${shorten(result)}`
                  : `Shaping finished for ${taskId}; the ticket is Ready. Review it in Board.`
                : `Worker finished ${taskId}; the ticket is In review. Review it in Board.`,
            );
          }
        }
        const error = typeof run.error === "string" ? run.error : "";
        if (status === "failed" && error !== "") {
          const key = `${taskId}:${phase}:failed:${error}`;
          if (!state.seenResults.has(key)) {
            state.seenResults.add(key);
            activity(`${phase === "shape" ? "Shaping" : "Worker"} failed for ${taskId}: ${shorten(error)}`);
          }
        }
      }
    }
  }

  async function sendSnapshot(ws: BoardSocket, force: boolean): Promise<void> {
    const snapshot = await readSnapshot(app);
    if (!force && snapshot.revision === state.lastRevision) return;
    state.lastRevision = snapshot.revision;
    ws.send(snapshot.frame);
  }

  async function broadcastSnapshot(force: boolean): Promise<void> {
    if (state.clients.size === 0) return;
    const snapshot = await readSnapshot(app);
    if (!force && snapshot.revision === state.lastRevision) return;
    state.lastRevision = snapshot.revision;
    for (const client of state.clients) client.send(snapshot.frame);
  }

  async function readTicketState(): Promise<string> {
    const structured = await invokeStructured(app, "board.ticket.state", {});
    const ticketState = JSON.stringify(structured);
    observeTicketState(ticketState);
    return ticketState;
  }

  async function sendTickets(ws: BoardSocket, force: boolean): Promise<void> {
    const ticketState = await readTicketState();
    if (!force && ticketState === state.lastTickets) return;
    state.lastTickets = ticketState;
    ws.send(
      JSON.stringify({
        type: "ticket_state",
        state: JSON.parse(ticketState) as unknown,
      }),
    );
  }

  async function broadcastTickets(force: boolean): Promise<void> {
    const ticketState = await readTicketState();
    if (state.clients.size === 0) return;
    if (!force && ticketState === state.lastTickets) return;
    state.lastTickets = ticketState;
    const frame = JSON.stringify({
      type: "ticket_state",
      state: JSON.parse(ticketState) as unknown,
    });
    for (const client of state.clients) client.send(frame);
  }

  const server = Bun.serve<BoardSocketData>({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req, server) {
      const port = server.port ?? 0;
      if (!isLoopbackHost(req.headers.get("host"), port)) {
        return fail(403);
      }
      const url = new URL(req.url);
      if (url.pathname === "/ws") {
        if (url.searchParams.get("token") !== token) return fail(403);
        if (server.upgrade(req, { data: { queue: Promise.resolve() } })) {
          return;
        }
        return fail(400);
      }
      if (url.pathname === "/" || url.pathname === "/index.html") {
        if (url.searchParams.get("token") !== token) return fail(403);
        return new Response(BOARD_HTML, {
          headers: {
            ...SECURITY_HEADERS,
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": CSP,
          },
        });
      }
      // The document is token-gated; its static code is public behind the
      // exact loopback Host gate, exactly like the native Board host.
      if (url.pathname === "/index.js") {
        return respond(BOARD_JS, "text/javascript; charset=utf-8");
      }
      if (url.pathname === "/board.css") {
        return respond(BOARD_CSS, "text/css; charset=utf-8");
      }
      if (url.pathname === "/health") {
        return respond("ok", "text/plain; charset=utf-8");
      }
      return fail(404);
    },
    websocket: {
      open(ws) {
        state.clients.add(ws);
      },
      message(ws, message) {
        const text =
          typeof message === "string" ? message : new TextDecoder().decode(message);
        ws.data.queue = ws.data.queue
          .then(async () => {
            let frame: unknown;
            try {
              frame = JSON.parse(text);
            } catch {
              ws.send(
                JSON.stringify({
                  type: "error",
                  code: "invalid_json",
                  message: "Invalid frame",
                }),
              );
              return;
            }
            if (
              typeof frame === "object" &&
              frame !== null &&
              (frame as { type?: unknown }).type === "hello"
            ) {
              await sendSnapshot(ws, true);
              await sendTickets(ws, true).catch(() => undefined);
              return;
            }
            if (
              typeof frame === "object" &&
              frame !== null &&
              (frame as { type?: unknown }).type === "ticket_command"
            ) {
              const ticket = frame as {
                name?: unknown;
                args?: unknown;
              };
              if (
                typeof ticket.name !== "string" ||
                !ticket.name.startsWith("board.ticket.")
              ) {
                ws.send(
                  JSON.stringify({
                    type: "ticket_result",
                    ok: false,
                    reason: "invalid_ticket_command",
                  }),
                );
                return;
              }
              try {
                const commandArgs =
                  typeof ticket.args === "object" &&
                  ticket.args !== null &&
                  !Array.isArray(ticket.args)
                    ? (ticket.args as Record<string, unknown>)
                    : {};
                const ticketState = await invokeStructured(
                  app,
                  ticket.name,
                  commandArgs,
                );
                ws.send(
                  JSON.stringify({
                    type: "ticket_result",
                    ok: true,
                    state: ticketState,
                  }),
                );
                const taskId =
                  typeof commandArgs.task_id === "string"
                    ? commandArgs.task_id
                    : "";
                if (ticket.name === "board.ticket.shape") {
                  activity(
                    `Shaping started for ${taskId || "ticket"}; questions will appear in the Board inbox.`,
                  );
                } else if (ticket.name === "board.ticket.run") {
                  activity(
                    `Worker started for ${taskId || "ticket"}; it runs in the background.`,
                  );
                } else if (ticket.name === "board.ticket.run_ready") {
                  activity("Worker started for the next Ready ticket; it runs in the background.");
                } else if (ticket.name === "board.ticket.answer") {
                  activity("Answer sent to the waiting worker.");
                }
                await broadcastTickets(true);
              } catch (error) {
                ws.send(
                  JSON.stringify({
                    type: "ticket_result",
                    ok: false,
                    reason:
                      error instanceof Error ? error.message : String(error),
                  }),
                );
              }
              return;
            }
            const encoded = await invokeFrame(app, "board.wire.command", {
              frame: text,
            });
            ws.send(encoded);
            // Commands commit through the shared backend; refresh every
            // connected dashboard so all tabs converge on the same revision.
            await broadcastSnapshot(true);
          })
          .catch((error: unknown) => {
            ws.send(failureFrame(text, error));
          });
      },
      close(ws) {
        state.clients.delete(ws);
      },
    },
  });

  const url = "http://127.0.0.1:" + server.port + "/?token=" + token;
  const owner: BoardServer = { server, url, token, state, closed: false };
  state.timer = setInterval(() => {
    broadcastSnapshot(false).catch(() => undefined);
  }, 1500);
  state.ticketTimer = setInterval(() => {
    broadcastTickets(false).catch(() => undefined);
  }, 1000);
  // A presentation surface must never keep Cetas alive by itself.
  (server as { unref?: () => void }).unref?.();
  boards.set(app, owner);
  owners.add(owner);
  if (options?.onOpen) options.onOpen(url);
  else openInBrowser(url);
  return "http://127.0.0.1:" + server.port + "/";
}

export async function closeWorkflowBoards(): Promise<void> {
  const all = [...owners];
  owners.clear();
  await Promise.all(
    all.map(async (owner) => {
      owner.closed = true;
      if (owner.state.timer !== undefined) clearInterval(owner.state.timer);
      if (owner.state.ticketTimer !== undefined) {
        clearInterval(owner.state.ticketTimer);
      }
      owner.state.clients.clear();
      try {
        await owner.server.stop(true);
      } catch {
        // A already-closed server is still a stopped server.
      }
    }),
  );
}
