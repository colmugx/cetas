import { appendFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cetas_js_herdr_release } from "mbt:colmugx/cetas-js/lib";

import { disposeSharedPiModuleMirror } from "./app/pi-module-mirror.ts";
import { cetasVersion, detectChannel } from "./app/version.ts";

function isBrokenPipe(error: unknown): boolean {
  try {
    return typeof error === "object" && error !== null && "code" in error && error.code === "EPIPE";
  } catch {
    return false;
  }
}

function reportUnhandledFault(kind: string, error: unknown): string {
  const detail =
    error instanceof Error
      ? `${error.stack ?? `${error.name}: ${error.message}`}\n${error.cause === undefined ? "" : "cause: " + (error.cause instanceof Error ? error.cause.stack ?? String(error.cause) : String(error.cause))}`
      : String(error);
  const crashPath = join(tmpdir(), "cetas-js-crash.log");
  appendFileSync(
    crashPath,
    `[${new Date().toISOString()}] ${kind} pid=${process.pid} cetas=${cetasVersion()} channel=${detectChannel()} runtime=${process.version} bun=${process.versions.bun ?? "unknown"}\n${detail}\n\n`,
  );
  return `cetas: fatal host fault (${kind}) logged to ${crashPath}`;
}

/** An escaped JS exception may have interrupted the MoonBit scheduler itself. */
export function installHostFaultHandler(
  stopSurface?: (outputBroken: boolean) => void,
): (kind: string, error: unknown) => void {
  const initialRawMode = process.stdin.isRaw ?? false;
  let handling = false;

  const handle = (kind: string, error: unknown) => {
    if (handling) return;
    handling = true;
    let outputBroken = isBrokenPipe(error);
    let notice = `cetas: fatal host fault (${kind}); crash logging failed`;
    try {
      notice = reportUnhandledFault(kind, error);
    } catch (loggingError) {
      try {
        notice += `: ${String(loggingError)}\n${String(error)}`;
      } catch {
        // Even formatting an arbitrary JS rejection may fail.
      }
    }

    const attempt = (name: string, action: () => void) => {
      try {
        action();
      } catch (cleanupError) {
        outputBroken ||= isBrokenPipe(cleanupError);
        try {
          reportUnhandledFault(`fatal cleanup: ${name}`, cleanupError);
        } catch {
          // Never feed a secondary failure back through the surface.
        }
      }
    };
    attempt("surface", () => stopSurface?.(outputBroken));
    // ProcessTerminal.stop writes to stdout before restoring raw mode. Restore
    // input separately even if stdout is broken or surface teardown throws.
    attempt("terminal", () => {
      try {
        process.stdin.setRawMode?.(initialRawMode);
      } finally {
        process.stdin.pause();
      }
    });
    attempt("pi module mirror", disposeSharedPiModuleMirror);
    attempt("herdr release", cetas_js_herdr_release);
    if (!outputBroken) {
      attempt("diagnostic", () => {
        writeSync(2, `${notice}\ncetas: exiting; restart to recover the persisted session.\n`);
      });
    }
    process.exit(1);
  };

  process.on("unhandledRejection", (reason) => handle("unhandled rejection", reason));
  process.on("uncaughtException", (error) => handle("uncaught exception", error));
  return handle;
}
