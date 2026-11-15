/**
 * pi-tui 1.3.0 OSC 7501 reporting is a one-root terminal integration,
 * not a multi-agent status dashboard. Keep status wording constant and
 * free of prompts, secrets, paths, model names and extension identifiers.
 */
import { t } from "../src/i18n/index.ts";
import type { ProgramStatus } from "@earendil-works/pi-tui";
import type { AppState } from "../src/app/types.ts";

export interface ProgramStatusSource {
  readonly appState?: AppState;
  readonly operationBusy: boolean;
  readonly commandBusy: boolean;
  readonly turnActive: boolean;
  readonly pendingQuestions: number;
  readonly pendingAuth: number;
  readonly boardPresence?: {
    readonly state: "idle" | "working" | "blocked";
    readonly running: number;
    readonly waiting_input: number;
    readonly message?: string;
  };
  readonly stopping: boolean;
}

export function projectProgramStatus(source: ProgramStatusSource): ProgramStatus {
  if (source.stopping || source.appState === "shutting_down") {
    return { state: "clear" };
  }
  if (source.pendingAuth > 0) {
    return { state: "blocked", app: "cetas", kind: "auth", message: t("status.waiting_auth") };
  }
  if (source.pendingQuestions > 0) {
    return { state: "blocked", app: "cetas", kind: "question", message: t("status.waiting_response") };
  }
  if (source.boardPresence?.state === "blocked") {
    return {
      state: "blocked",
      app: "cetas",
      kind: "question",
      message: source.boardPresence.message ?? "Board: waiting for your response",
    };
  }
  if (source.appState === "needs_setup") {
    return { state: "blocked", app: "cetas", kind: "auth", message: t("status.connect_provider") };
  }
  if (source.commandBusy || source.operationBusy || source.turnActive || source.appState === "running") {
    return { state: "working", app: "cetas", message: t("status.working") };
  }
  if (source.boardPresence?.state === "working") {
    return {
      state: "working",
      app: "cetas",
      message: source.boardPresence.message ??
        `Board: ${source.boardPresence.running} running`,
    };
  }
  if (source.appState === "ready") return { state: "idle", app: "cetas" };
  return { state: "working", app: "cetas", message: t("status.starting") };
}

/** Only use the protocol discriminator. Never forward the payload. */
export function classifyRequestStatus(json: string): "auth" | "question" {
  try {
    const value: unknown = JSON.parse(json);
    if (value !== null && typeof value === "object" && !Array.isArray(value) &&
        (value as Record<string, unknown>).type === "auth_prompt") {
      return "auth";
    }
  } catch {
    // Malformed requests are answered by the existing guarded request path.
  }
  return "question";
}
