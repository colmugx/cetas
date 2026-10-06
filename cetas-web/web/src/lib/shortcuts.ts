/**
 * Central shortcut registry. `Mod` is Cmd on macOS and Ctrl elsewhere.
 * Single-key shortcuts are suppressed while typing in form fields.
 */
export type Shortcut = {
  keys: string;
  label: string;
  run: () => void;
};

export function isMac(): boolean {
  return /mac|iphone|ipad/i.test(navigator.platform || navigator.userAgent);
}

export function modKey(): "metaKey" | "ctrlKey" {
  return isMac() ? "metaKey" : "ctrlKey";
}

function matches(event: KeyboardEvent, keys: string): boolean {
  const parts = keys.split("+");
  const key = parts[parts.length - 1].toLowerCase();
  const wantMod = parts.includes("Mod");
  const wantShift = parts.includes("Shift");
  const wantAlt = parts.includes("Alt");
  const mod = wantMod ? event[modKey()] : true;
  const shift = wantShift ? event.shiftKey : !event.shiftKey;
  const alt = wantAlt ? event.altKey : !event.altKey;
  const pressed = event.key.toLowerCase();
  return mod && shift && alt && pressed === key;
}

function isTypingTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return (
    target.tagName === "INPUT" ||
    target.tagName === "TEXTAREA" ||
    target.isContentEditable
  );
}

export function bindShortcuts(
  shortcuts: Shortcut[],
  onUnhandledKey: (event: KeyboardEvent) => void = () => {},
): () => void {
  const handler = (event: KeyboardEvent) => {
    if (event.key === "Escape") {
      onUnhandledKey(event);
      return;
    }
    for (const shortcut of shortcuts) {
      const singleKey = !shortcut.keys.includes("+");
      if (singleKey && isTypingTarget(event.target)) continue;
      if (matches(event, shortcut.keys)) {
        event.preventDefault();
        shortcut.run();
        return;
      }
    }
    onUnhandledKey(event);
  };
  window.addEventListener("keydown", handler);
  return () => window.removeEventListener("keydown", handler);
}
