function isBrokenPipe(error: unknown): boolean {
  try {
    return typeof error === "object" && error !== null && "code" in error && error.code === "EPIPE";
  } catch {
    return false;
  }
}

export interface UnhandledFaultHooks {
  report(kind: string, error: unknown): string;
  stopSurface(outputBroken: boolean): void;
  releaseResources(): void;
  writeDiagnostic(notice: string): void;
  exitFatal(): void;
}

/** An escaped JS exception may have interrupted the MoonBit scheduler itself. */
export function makeUnhandledFaultHandler(
  hooks: UnhandledFaultHooks,
): (kind: string, error: unknown) => void {
  let handling = false;
  return (kind, error) => {
    if (handling) return;
    handling = true;
    let outputBroken = isBrokenPipe(error);
    let notice = `cetas: fatal host fault (${kind}); crash logging failed`;
    try {
      notice = hooks.report(kind, error);
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
          hooks.report(`fatal cleanup: ${name}`, cleanupError);
        } catch {
          // Never feed a secondary failure back through the surface.
        }
      }
    };
    attempt("surface", () => hooks.stopSurface(outputBroken));
    attempt("resources", () => hooks.releaseResources());
    if (!outputBroken) attempt("diagnostic", () => hooks.writeDiagnostic(notice));
    hooks.exitFatal();
  };
}
