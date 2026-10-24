import { appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** Record recoverable background faults without writing into the live TUI. */
export function recordDiagnostic(context: string, error: unknown): void {
  try {
    const detail = error instanceof Error
      ? error.stack ?? `${error.name}: ${error.message}`
      : String(error);
    appendFileSync(
      join(tmpdir(), "cetas-js-diagnostics.log"),
      `[${new Date().toISOString()}] ${context}\n${detail}\n\n`,
    );
  } catch {
    // A diagnostic must never become another unhandled exception.
  }
}
