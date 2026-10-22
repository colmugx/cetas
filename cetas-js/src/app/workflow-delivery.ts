import { randomUUID } from "node:crypto";
import { lstat, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";

/** Settings opt-in is separate from every workflow execution approval. */
export async function workflowsEnabled(home: string): Promise<boolean> {
  const path = join(home, ".cetas", "settings.json");
  try {
    const json: unknown = JSON.parse(await readFile(path, "utf8"));
    return isRecord(json) && isRecord(json.workflow) && json.workflow.enabled === true;
  } catch {
    return false;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Preserve every existing settings field; never create permissions or credentials. */
export async function enableCetasWorkflows(home: string): Promise<void> {
  const dir = join(home, ".cetas");
  const path = join(dir, "settings.json");
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error("settings.json must be a regular file");
  }
  const source = await readFile(path, "utf8");
  let decoded: unknown;
  try { decoded = JSON.parse(source); }
  catch { throw new Error("Invalid settings.json: repair it before enabling workflows"); }
  if (!isRecord(decoded) || (decoded.workflow !== undefined && !isRecord(decoded.workflow))) {
    throw new Error("Invalid workflow settings object");
  }
  if (isRecord(decoded.workflow) && decoded.workflow.enabled === true) return;
  const updated = { ...decoded, workflow: { ...(isRecord(decoded.workflow) ? decoded.workflow : {}), enabled: true } };
  const temporary = join(dir, ".workflow-enable-" + randomUUID());
  const file = await open(temporary, "wx", 0o600);
  try {
    try {
      await file.writeFile(JSON.stringify(updated, null, 2) + "\n");
      await file.sync();
    } finally {
      await file.close();
    }
    // Fail rather than overwriting a concurrent settings editor's modifications.
    if (await readFile(path, "utf8") !== source) throw new Error("Settings changed; retry after inspecting them");
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}
