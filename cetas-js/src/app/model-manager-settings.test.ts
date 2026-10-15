import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  readManagerSettings,
  restoreManagerSettings,
  writeManagerChoice,
  writeMagpieAddress,
} from "./model-manager-settings.ts";

describe("model manager settings", () => {
  test("persists manager without retaining provider-specific model selection or touching secrets", async () => {
    const home = await mkdtemp(join(tmpdir(), "cetas-manager-"));
    await mkdir(join(home, ".cetas"));
    const original = JSON.stringify({
      model: "provider/model",
      reasoning_effort: "high",
      magpie: { base_url: "http://127.0.0.1:3425" },
      custom: { enabled: true },
    });
    await writeFile(join(home, ".cetas", "settings.json"), original);
    const previous = await readManagerSettings(home);
    expect(previous.manager).toBe("providers");
    await writeManagerChoice(home, "magpie", previous);
    const updated = JSON.parse(await readFile(join(home, ".cetas", "settings.json"), "utf8"));
    expect(updated.model_manager).toBe("magpie");
    expect(updated.model).toBeUndefined();
    expect(updated.reasoning_effort).toBeUndefined();
    expect(updated.manager_selections.providers).toEqual({ model: "provider/model", reasoning_effort: "high" });
    expect(updated.magpie.base_url).toBe("http://127.0.0.1:3425");
    expect(updated.custom.enabled).toBe(true);
    await restoreManagerSettings(home, previous);
    expect(await readFile(join(home, ".cetas", "settings.json"), "utf8")).toBe(original);
  });

  test("requires HTTPS for remote gateways and retains manager choice", async () => {
    const home = await mkdtemp(join(tmpdir(), "cetas-manager-"));
    await expect(writeMagpieAddress(home, "http://remote.example:3425")).rejects.toThrow("HTTPS");
    await expect(writeMagpieAddress(home, "https://user:pass@remote.example")).rejects.toThrow("HTTPS");
    await expect(writeMagpieAddress(home, "https://remote.example/v1/models")).rejects.toThrow("HTTPS");
    await writeMagpieAddress(home, "https://remote.example:3443/");
    const settings = JSON.parse(await readFile(join(home, ".cetas", "settings.json"), "utf8"));
    expect(settings.model_manager).toBeUndefined();
    expect(settings.magpie).toEqual({ base_url: "https://remote.example:3443", enabled: true });
  });

  test("rejects an invalid manager instead of silently selecting providers", async () => {
    const home = await mkdtemp(join(tmpdir(), "cetas-manager-"));
    await mkdir(join(home, ".cetas"));
    await writeFile(join(home, ".cetas", "settings.json"), '{"model_manager":"unexpected"}');
    await expect(readManagerSettings(home)).rejects.toThrow("model_manager");
  });
});
