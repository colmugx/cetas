import { describe, expect, test } from "bun:test";
import { classifyProviderQuota, quickPickGroups, isQuotaExhausted } from "./model-quota.ts";
import type { ModelCatalogEntry } from "./model-catalog.ts";

describe("provider quota projection", () => {
  test("5h window is primary and exhausted providers are disabled", () => {
    const quota = classifyProviderQuota([
      {window:"weekly",usedPercent:1,fetchedAtMs:1},
      {window:"5h",usedPercent:100,fetchedAtMs:1},
    ]);
    expect(quota?.kind).toBe("limit");
    if (quota?.kind !== "limit") throw new Error("expected limit");
    expect(quota.primaryWindow).toBe("5h");
    expect(isQuotaExhausted(quota)).toBe(true);
  });
  test("provider entries stay adjacent and rank by remaining quota", () => {
    const entry=(provider:string,id:string,usedPercent:number):ModelCatalogEntry=>({
      provider,id,label:id,active:false,efforts:[],
      quotaReadings:[{window:"5h",usedPercent,fetchedAtMs:1}],
    });
    const groups=quickPickGroups([entry("a","a1",80),entry("b","b1",20),entry("a","a2",80)]);
    expect(groups.map(g=>g.kind)).toEqual(["limit"]);
    expect(groups[0]?.entries.map(e=>e.id)).toEqual(["b1","a1","a2"]);
  });
});
