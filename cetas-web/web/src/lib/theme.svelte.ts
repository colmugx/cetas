export type ThemeChoice = "system" | "light" | "dark";

const STORAGE_KEY = "cetas.theme";

function loadChoice(): ThemeChoice {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "light" || stored === "dark" || stored === "system") {
      return stored;
    }
  } catch {
    // Storage can be unavailable (private mode); fall back to system.
  }
  return "system";
}

class ThemeStore {
  choice = $state<ThemeChoice>(loadChoice());
  systemDark = $state(
    typeof window !== "undefined" &&
      window.matchMedia("(prefers-color-scheme: dark)").matches,
  );

  isDark = $derived.by(() =>
    this.choice === "system" ? this.systemDark : this.choice === "dark",
  );

  constructor() {
    if (typeof window === "undefined") return;
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    media.addEventListener("change", (event) => {
      this.systemDark = event.matches;
    });
  }

  setChoice(choice: ThemeChoice) {
    this.choice = choice;
    try {
      if (choice === "system") {
        localStorage.removeItem(STORAGE_KEY);
      } else {
        localStorage.setItem(STORAGE_KEY, choice);
      }
    } catch {
      // Persisting the choice is best-effort.
    }
  }

  cycle() {
    const order: ThemeChoice[] = ["system", "light", "dark"];
    this.setChoice(order[(order.indexOf(this.choice) + 1) % order.length]);
  }
}

export const themeStore = new ThemeStore();
