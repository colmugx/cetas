import {
  createContext,
  createEffect,
  createSignal,
  onCleanup,
  useContext,
} from "solid-js";
import type { JSX } from "@solidjs/web";

export type ThemeChoice = "system" | "light" | "dark";

const STORAGE_KEY = "cetas.theme";

type ThemeContextValue = {
  choice: () => ThemeChoice;
  setChoice: (choice: ThemeChoice) => void;
  isDark: () => boolean;
};

const ThemeContext = createContext<ThemeContextValue>();

function systemPrefersDark(): boolean {
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

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

export function ThemeProvider(props: { children: JSX.Element }) {
  const [choice, setChoice] = createSignal<ThemeChoice>(loadChoice());
  const [darkPreference, setDarkPreference] = createSignal(systemPrefersDark());

  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const onMediaChange = (event: MediaQueryListEvent) =>
    setDarkPreference(event.matches);
  media.addEventListener("change", onMediaChange);
  onCleanup(() => media.removeEventListener("change", onMediaChange));

  const isDark = () =>
    choice() === "system" ? darkPreference() : choice() === "dark";

  createEffect(
    () => isDark(),
    (dark) => {
      document.documentElement.classList.toggle("dark", dark);
    },
  );

  createEffect(
    () => choice(),
    (value) => {
      try {
        if (value === "system") {
          localStorage.removeItem(STORAGE_KEY);
        } else {
          localStorage.setItem(STORAGE_KEY, value);
        }
      } catch {
        // Persisting the choice is best-effort.
      }
    },
  );

  return (
    <ThemeContext
      value={{
        choice,
        setChoice,
        isDark,
      }}
    >
      {props.children}
    </ThemeContext>
  );
}

export function useTheme(): ThemeContextValue {
  const value = useContext(ThemeContext);
  if (!value) {
    throw new Error("useTheme must be used inside ThemeProvider");
  }
  return value;
}
