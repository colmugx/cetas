import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  cetas_js_session_catalog,
  cetas_js_session_titles,
  cetas_js_sessions_dir,
} from "mbt:colmugx/cetas-js/lib";

const cleanup: string[] = [];

afterEach(async () => {
  for (const path of cleanup.splice(0)) {
    await rm(path, { recursive: true });
  }
});

/**
 * The MoonBit titles export is the /sessions picker's source of truth: the
 * metadata name wins, the first user message prefixes otherwise, and a
 * corrupt transcript is skipped rather than blanking the list. Files are
 * laid out exactly as the store persists them (JSONL: metadata line first,
 * then one line per message).
 */
describe("cetas_js_session_titles wire format", () => {
  test("names beat first messages; bare sessions fall back to the message prefix", async () => {
    const dir = await mkdtemp(join(tmpdir(), "cetas-js-titles-"));
    cleanup.push(dir);
    await writeFile(
      join(dir, "2026-09-08T10-00-00-000Z_named.jsonl"),
      [
        JSON.stringify({ name: "Fix the login bug" }),
        JSON.stringify({
          role: "user",
          content: [{ type: "text", text: "first message text" }],
        }),
      ].join("\n") + "\n",
    );
    await writeFile(
      join(dir, "2026-09-08T11-00-00-000Z_plain.jsonl"),
      [
        JSON.stringify({}),
        JSON.stringify({
          role: "user",
          content: [{ type: "text", text: "  what does   collapse..." }],
        }),
        JSON.stringify({
          role: "assistant",
          content: [{ type: "text", text: "ignored" }],
        }),
      ].join("\n") + "\n",
    );
    await writeFile(
      join(dir, "2026-09-08T12-00-00-000Z_broken.jsonl"),
      "{}\n{\"role\":\"junk\"\n",
    );

    const titles = JSON.parse(
      await cetas_js_session_titles(dir),
    ) as Array<{ id: string; title: string }>;
    const byId = new Map(titles.map((t) => [t.id, t.title]));
    expect(byId.get("2026-09-08T10-00-00-000Z_named")).toBe("Fix the login bug");
    // The first user message is collapsed and truncated at 50 chars.
    expect(byId.get("2026-09-08T11-00-00-000Z_plain")).toBe("what does collapse...");
    expect(byId.has("2026-09-08T12-00-00-000Z_broken")).toBe(false);
    expect(titles).toHaveLength(2);
  });

  test("cetas_js_sessions_dir resolves the per-project bucket", async () => {
    const home = await mkdtemp(join(tmpdir(), "cetas-js-titles-home-"));
    cleanup.push(home);
    const dir = cetas_js_sessions_dir(home, "/some/project dir");
    expect(dir.startsWith(`${home}/.cetas/sessions/session_`)).toBe(true);
    // Sibling paths a slug alone would collide get distinct buckets.
    expect(dir).not.toBe(cetas_js_sessions_dir(home, "/some/project/dir"));
  });
});

/**
 * The catalog export is the `/sessions` "All" view's source of truth: it walks
 * every project bucket under `home`, reports the folder each session recorded
 * (`cetas.cwd`) and the bucket slug that stands in for legacy journals.
 */
describe("cetas_js_session_catalog wire format", () => {
  test("walks every bucket and reports the recorded cwd, or null for legacy rows", async () => {
    const home = await mkdtemp(join(tmpdir(), "cetas-js-catalog-home-"));
    cleanup.push(home);
    const bucketA = cetas_js_sessions_dir(home, "/work/project-a").split("/").at(-1)!;
    const bucketB = cetas_js_sessions_dir(home, "/work/project-b").split("/").at(-1)!;
    const dirA = join(home, ".cetas", "sessions", bucketA);
    const dirB = join(home, ".cetas", "sessions", bucketB);
    await mkdir(dirA, { recursive: true });
    await mkdir(dirB, { recursive: true });
    await writeFile(
      join(dirA, "2026-09-10T10-00-00-000Z_new.jsonl"),
      [
        JSON.stringify({ "posoco.title": "Project A work", "cetas.cwd": "/work/project-a" }),
        JSON.stringify({ role: "user", content: [{ type: "text", text: "hello" }] }),
      ].join("\n") + "\n",
    );
    // Legacy journal: no cwd recorded, so the bucket slug is all there is.
    await writeFile(
      join(dirB, "2026-09-11T10-00-00-000Z_old.jsonl"),
      [
        JSON.stringify({ "posoco.title": "Legacy work" }),
        JSON.stringify({ role: "user", content: [{ type: "text", text: "old" }] }),
      ].join("\n") + "\n",
    );

    const rows = JSON.parse(await cetas_js_session_catalog(home)) as Array<{
      id: string;
      title: string;
      bucket: string;
      dir: string;
      folder: string;
      cwd: string | null;
    }>;
    expect(rows).toHaveLength(2);
    const byId = new Map(rows.map((row) => [row.id, row]));
    const fresh = byId.get("2026-09-10T10-00-00-000Z_new");
    expect(fresh?.cwd).toBe("/work/project-a");
    expect(fresh?.dir).toBe(dirA);
    expect(fresh?.bucket).toBe(bucketA);
    expect(fresh?.title).toBe("Project A work");
    const legacy = byId.get("2026-09-11T10-00-00-000Z_old");
    expect(legacy?.cwd).toBeNull();
    expect(legacy?.folder).toBe("project-b");
    expect(legacy?.dir).toBe(dirB);
  });

  test("a missing sessions root is an empty catalog", async () => {
    const home = await mkdtemp(join(tmpdir(), "cetas-js-catalog-empty-"));
    cleanup.push(home);
    expect(JSON.parse(await cetas_js_session_catalog(home))).toEqual([]);
  });
});
