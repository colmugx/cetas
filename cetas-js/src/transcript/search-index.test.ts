import { describe, expect, test } from "bun:test";
import type { Component } from "@earendil-works/pi-tui";
import { TranscriptSearchIndex, transcriptTextRange } from "./search-index.ts";

function docs(count:number, onRender:()=>void): Component[] {
  return Array.from({length:count},(_,i)=>({
    render:()=>{onRender();throw new Error("search must never render!");},
    getSearchText:()=>i===9876?"banana asks main and main replies banana":"plain "+i,
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
  });
  test("empty query and no matches clear the result state",()=>{
    const idx=new TranscriptSearchIndex();
    expect(idx.search(docs(4,()=>{}),"")).toEqual([]);
    expect(idx.next(0)).toBe(-1);
    expect(idx.search(docs(4,()=>{}),"absent")).toEqual([]);
  });
  test("copies original CJK and multiline text across offscreen message boundaries",()=>{
    let paints=0;
    const blocks:Component[]=[
      {render:()=>{paints++;return [];},getSearchText:()=>"你好，main\nmessage"},
      {render:()=>{paints++;return [];},getSearchText:()=>"agent banana\n答复"},
      {render:()=>{paints++;return [];},getSearchText:()=>"tool output"},
    ];
    expect(transcriptTextRange(blocks,0,2)).toBe("你好，main\nmessage\n\nagent banana\n答复\n\ntool output");
    expect(paints).toBe(0);
    expect(()=>transcriptTextRange(blocks,0,3)).toThrow(RangeError);
    expect(()=>transcriptTextRange(blocks,0,2,10)).toThrow(RangeError);
  });
});
