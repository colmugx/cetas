/**
 * Run background Board polling without overlapping async work.
 *
 * If the backend stalls, setInterval normally accumulates one new promise
 * every tick. This single-flight gate bounds pending work to one request per
 * channel. Unref the timer so a UI-only listener cannot keep Cetas alive.
 * Callers own clearing the returned timer during shutdown.
 */
export function scheduleSingleFlightPoll(
  intervalMs: number,
  poll: () => Promise<void>,
  schedule: (
    callback: () => void,
    delay: number,
  ) => ReturnType<typeof setInterval> = setInterval,
): ReturnType<typeof setInterval> {
  let pending = false;
  const timer = schedule(() => {
    if (pending) return;
    pending = true;
    void Promise.resolve()
      .then(poll)
      .catch(() => undefined) // Periodic errors must not stop future polls.
      .finally(() => { pending = false; });
  }, intervalMs);
  timer.unref?.();
  return timer;
}
