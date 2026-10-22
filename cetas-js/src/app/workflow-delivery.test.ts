import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { enableCetasWorkflows, workflowsEnabled } from "./workflow-delivery.ts";

const homes: string[] = [];
async function home(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "cetas-workflow-delivery-"));
  homes.push(dir);
  await mkdir(join(dir, ".cetas"));
  return dir;
}
afterEach(async () => {
  for (const dir of homes) await rm(dir, { recursive: true, force: true });
  homes.length = 0;
});
describe("Workflow product opt-in", () => {
  test("preserves existing provider, credentials and custom fields", async () => {
    const dir = await home();
    const settings = { providers: { demo: { enabled: true } }, unrelated: { x: 1 }, workflow: { max_concurrency: 3 } };
    const path = join(dir, ".cetas", "settings.json");
    await writeFile(path, JSON.stringify(settings));
    expect(await workflowsEnabled(dir)).toBe(false);
    await enableCetasWorkflows(dir);
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
      ...settings, workflow: { max_concurrency: 3, enabled: true },
    });
    expect(await workflowsEnabled(dir)).toBe(true);
    await enableCetasWorkflows(dir);
    expect(JSON.parse(await readFile(path, "utf8")).workflow.enabled).toBe(true);
  });
  test("refuses invalid existing settings without overwriting", async () => {
    const dir = await home();
    const path = join(dir, ".cetas", "settings.json");
    await writeFile(path, "{invalid");
    await expect(enableCetasWorkflows(dir)).rejects.toThrow("Invalid settings.json");
    expect(await readFile(path, "utf8")).toBe("{invalid");
  });
  test("does not silently create an empty settings file", async () => {
    const dir = await home();
    await expect(enableCetasWorkflows(dir)).rejects.toThrow();
    expect(await workflowsEnabled(dir)).toBe(false);
  });
});
