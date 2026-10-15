import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

export type ModelManagerChoice = "providers" | "magpie";

export interface ManagerSettingsSnapshot {
  manager: ModelManagerChoice;
  original: string | undefined;
}

function parseSettings(raw: string | undefined): Record<string, unknown> {
  if (raw === undefined) return {};
  const parsed: unknown = JSON.parse(raw);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("settings.json must contain an object");
  }
  return parsed as Record<string, unknown>;
}

export async function readManagerSettings(home: string): Promise<ManagerSettingsSnapshot> {
  let original: string | undefined;
  try {
    original = await readFile(join(home, ".cetas", "settings.json"), "utf8");
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  const value = parseSettings(original).model_manager;
  if (value !== undefined && value !== "providers" && value !== "magpie") {
    throw new Error("settings.model_manager must be providers or magpie");
  }
  return { manager: value ?? "providers", original };
}

async function writeSettings(home: string, text: string | undefined): Promise<void> {
  const dir = join(home, ".cetas");
  const path = join(dir, "settings.json");
  if (text === undefined) {
    await rm(path, { force: true });
    return;
  }
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const temp = join(dir, `.settings-${process.pid}-${randomUUID()}.tmp`);
  try {
    await writeFile(temp, text, { encoding: "utf8", mode: 0o600, flag: "wx" });
    await rename(temp, path);
  } finally {
    await rm(temp, { force: true });
  }
}

/** Only Host settings change; credentials remain in the separate credential store. */
export async function writeManagerChoice(
  home: string,
  choice: ModelManagerChoice,
  snapshot: ManagerSettingsSnapshot,
): Promise<void> {
  const settings = parseSettings(snapshot.original);
  const rawSelections = settings.manager_selections;
  const selections: Record<string, unknown> =
    typeof rawSelections === "object" && rawSelections !== null && !Array.isArray(rawSelections)
      ? { ...rawSelections as Record<string, unknown> }
      : {};
  const source = selections[snapshot.manager];
  const sourceEntry: Record<string, unknown> =
    typeof source === "object" && source !== null && !Array.isArray(source)
      ? { ...source as Record<string, unknown> }
      : {};
  if (typeof settings.model === "string") sourceEntry.model = settings.model;
  if (typeof settings.reasoning_effort === "string") sourceEntry.reasoning_effort = settings.reasoning_effort;
  selections[snapshot.manager] = sourceEntry;
  const target = selections[choice];
  const targetEntry =
    typeof target === "object" && target !== null && !Array.isArray(target)
      ? target as Record<string, unknown>
      : {};
  delete settings.model;
  delete settings.reasoning_effort;
  if (typeof targetEntry.model === "string") {
    settings.model = targetEntry.model;
    if (typeof targetEntry.reasoning_effort === "string") {
      settings.reasoning_effort = targetEntry.reasoning_effort;
    }
  }
  settings.manager_selections = selections;
  settings.model_manager = choice;
  await writeSettings(home, JSON.stringify(settings, null, 2) + "\n");
}

export async function restoreManagerSettings(
  home: string,
  snapshot: ManagerSettingsSnapshot,
): Promise<void> {
  await writeSettings(home, snapshot.original);
}
