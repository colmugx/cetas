import type { TriggerKind } from "./trigger";

export type SuggestionItem = {
  kind: TriggerKind;
  /** What the row renders — for commands this is the full `/id`. */
  label: string;
  detail?: string;
  /** What replaces the trigger span on apply. */
  insertText: string;
  /** Command routing id (kind === "command" only) — the adaptor binds
   *  these ids to actions, keeping the composer desktop-portable. */
  commandId?: string;
  /** Rendered remainder for command-with-args rows. */
  args?: string;
};

/** One local slash command. Argument completion is declarative: either a
 *  fixed choice list or a dynamic callback over the model catalog. */
export type CommandDef = {
  id: string;
  label: string;
  detail: string;
  argChoices?: (query: string) => SuggestionItem[];
};

export type ModelSlotLite = { id: string; label: string; efforts: string[] };

/** Local slash commands — cetas-js alignment minus terminal-only entries
 *  (/login /pi /exit live in native hosts). */
export const COMMANDS: CommandDef[] = [
  { id: "new", label: "/new", detail: "Start a new session" },
  {
    id: "compact",
    label: "/compact",
    detail: "Compact this session's context on the server",
  },
  {
    id: "model",
    label: "/model",
    detail: "Select a model slot and effort",
    argChoices: (query) => {
      // cetas-js arg-completion semantics: candidates are the declared arg
      // strings filtered by startsWith — so a fully-typed "slot effort"
      // stops matching and the command submits on the next Enter.
      const items: SuggestionItem[] = [];
      for (const slot of runtimeCatalog()) {
        const bare: SuggestionItem = {
          kind: "command",
          label: `/model ${slot.id}`,
          detail: slot.label,
          insertText: `/model ${slot.id} `,
          commandId: "model",
        };
        if (slot.id.startsWith(query)) items.push(bare);
        for (const effort of slot.efforts) {
          const args = `${slot.id} ${effort}`;
          if (args.startsWith(query)) {
            items.push({
              kind: "command",
              label: `/model ${args}`,
              detail: slot.label,
              insertText: `/model ${args}`,
              commandId: "model",
            });
          }
        }
      }
      return items;
    },
  },
  { id: "sessions", label: "/sessions", detail: "Pick a session from the sidebar" },
  { id: "skills", label: "/skills", detail: "Browse discovered agent skills ($name)" },
];

/** The model catalog is injected late (set by the page adaptor) so the
 *  command table stays decoupled from the runtime store. */
let catalogSlots: ModelSlotLite[] = [];
export function setModelCatalog(slots: ModelSlotLite[]): void {
  catalogSlots = slots;
}
function runtimeCatalog(): ModelSlotLite[] {
  return catalogSlots;
}

export function commandItems(query: string): SuggestionItem[] {
  const space = query.indexOf(" ");
  const cmd = space === -1 ? query : query.slice(0, space);
  const argPrefix = space === -1 ? "" : query.slice(space + 1);
  if (space !== -1) {
    const def = COMMANDS.find((candidate) => candidate.id === cmd);
    if (def?.argChoices) {
      return def.argChoices(argPrefix);
    }
    return [];
  }
  return COMMANDS.filter((def) => def.id.startsWith(cmd)).map((def) => ({
    kind: "command" as const,
    label: def.label,
    detail: def.detail,
    insertText: `${def.label} `,
    commandId: def.id,
  }));
}

export type FileEntry = { path: string; isDir: boolean };

export async function fetchFileSuggestions(
  query: string,
  signal: AbortSignal,
): Promise<SuggestionItem[]> {
  const params = new URLSearchParams({ q: query, limit: "50" });
  const response = await fetch(`/api/files/search?${params}`, { signal });
  if (!response.ok) return [];
  const payload = (await response.json()) as { entries?: FileEntry[] };
  return (payload.entries ?? []).map((entry) => ({
    kind: "file" as const,
    label: entry.path,
    detail: entry.isDir ? "directory" : "",
    insertText: entry.isDir ? `@${entry.path}` : `@${entry.path} `,
  }));
}

export type SkillInfo = { name: string; description: string };

let skillCache: { at: number; items: SuggestionItem[] } | null = null;
const SKILL_TTL_MS = 60_000;

export async function fetchSkillSuggestions(
  signal: AbortSignal,
): Promise<SuggestionItem[]> {
  if (skillCache && Date.now() - skillCache.at < SKILL_TTL_MS) {
    return skillCache.items;
  }
  const response = await fetch("/api/skills", { signal });
  if (!response.ok) return [];
  const payload = (await response.json()) as { skills?: SkillInfo[] };
  const items = (payload.skills ?? []).map((skill) => ({
    kind: "skill" as const,
    label: `$${skill.name}`,
    detail: skill.description,
    insertText: `$${skill.name} `,
  }));
  skillCache = { at: Date.now(), items };
  return items;
}
