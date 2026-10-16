import { describe, expect, test } from "bun:test";
import { DeferredTranscriptComponent } from "./deferred-component.ts";

describe("lazy session replay components", () => {
  test("10k descriptors allocate zero actual components until visible", () => {
    let mounts = 0;
    const blocks = Array.from({length:10000}, () => new DeferredTranscriptComponent(() => {
      mounts++;
      return {render:() => ["hello"],invalidate(){}};
    }));
    expect(mounts).toBe(0);
    expect(blocks.slice(9900,9925).flatMap(block => block.render(80))).toHaveLength(25);
    expect(mounts).toBe(25);
    blocks[9900]!.invalidate();
    blocks[9900]!.render(80);
    expect(mounts).toBe(25);
    expect(blocks[0]!.isMaterialized).toBe(false);
  });
});
