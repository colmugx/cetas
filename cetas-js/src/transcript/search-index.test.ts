import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";
import { TranscriptSearchIndex, transcriptTextRange, type SearchableComponent } from "./search-index.ts";

function docs(count:number, onRender:()=>void): SearchableComponent[] {
  return Array.from({length:count},(_,i)=>({
    render:()=>{onRender();throw new Error("search must never render!");},
    getSearchText:()=>i===9876?"banana asks main and main replies banana":"plain "+i,
    invalidate(){},
  }));
}
describe("Gate 5 source-indexed transcript search and copy",()=>{
  test("searches unmounted 10k document without a single render or Markdown parse",()=>{
    let renders=0;
    const entries=docs(10000,()=>renders++);
    const index=new TranscriptSearchIndex();
    const hits=index.search(entries,"BANANA");
    expect(hits.length).toBe(2);
    expect(hits[0]?.index).toBe(9876);
    expect(index.stats.inspected).toBe(10000);
    expect(renders).toBe(0);
    expect(index.next(1)).toBe(0);
    expect(index.next(0,true)).toBe(1);
    expect(index.next(0)).toBe(1);
    expect(index.next(-1)).toBe(0);
    expect(index.next(-1,true)).toBe(1);
  });
  test("looks up only matching message hits from a large sorted hit list", () => {
    const entries: SearchableComponent[] = Array.from({ length: 10_000 }, (_, i) => ({
      render: () => { throw new Error("lookup must not render"); },
      invalidate() {},
      getSearchText: () => i % 2 === 0 ? "banana banana" : "other",
    }));
    const index = new TranscriptSearchIndex();
    const all = index.search(entries, "banana");
    expect(all).toHaveLength(10_000);
    expect(index.hitsAt(0)).toEqual(all.slice(0, 2));
    expect(index.hitsAt(4000)).toEqual([
      { index: 4000, offset: 0, length: 6 },
      { index: 4000, offset: 7, length: 6 },
    ]);
    expect(index.hitsAt(4001)).toEqual([]);
    expect(index.hitsAt(9998)).toEqual(all.slice(-2));
    expect(index.hitsAt(10000)).toEqual([]);
    index.clear();
    expect(index.hitsAt(0)).toEqual([]);
  });

  test("empty query and no matches clear the result state",()=>{
    const idx=new TranscriptSearchIndex();
    expect(idx.search(docs(4,()=>{}),"")).toEqual([]);
    expect(idx.next(0)).toBe(-1);
    expect(idx.search(docs(4,()=>{}),"absent")).toEqual([]);
  });
  test("copies original CJK and multiline text across offscreen message boundaries",()=>{
    let paints=0;
    const blocks:SearchableComponent[]=[
      {render:()=>{paints++;return [];},getSearchText:()=>"你好，main\nmessage",invalidate(){}},
      {render:()=>{paints++;return [];},getSearchText:()=>"agent banana\n答复",invalidate(){}},
      {render:()=>{paints++;return [];},getSearchText:()=>"tool output",invalidate(){}},
    ];
    expect(transcriptTextRange(blocks,0,2)).toBe("你好，main\nmessage\n\nagent banana\n答复\n\ntool output");
    expect(paints).toBe(0);
    expect(()=>transcriptTextRange(blocks,0,3)).toThrow(RangeError);
    expect(()=>transcriptTextRange(blocks,0,2,10)).toThrow(RangeError);
  });
});

describe("search source from component objects",()=>{
  test("search uses immutable deferred text and mutable assistant text",async()=>{
    const { DeferredTranscriptComponent }=await import("./deferred-component.ts");
    const { AssistantMessage, UserMessage }=await import("./components.ts");
    let built=0;
    const lazy=new DeferredTranscriptComponent(()=>{built++;return new AssistantMessage("banana");},"banana asks main");
    const live=new AssistantMessage("main replies banana",{streaming:true});
    const user=new UserMessage("汉字 🍌 banana");
    const index=new TranscriptSearchIndex();
    expect(index.search([lazy,live,user],"banana").map(hit=>hit.index)).toEqual([0,1,2]);
    expect(built).toBe(0);
    live.updateContent("main replies orange");
    expect(index.search([lazy,live,user],"banana").map(hit=>hit.index)).toEqual([0,2]);
    expect(transcriptTextRange([lazy,live,user],0,2)).toContain("main replies orange");
    expect(built).toBe(0);
  });
});
