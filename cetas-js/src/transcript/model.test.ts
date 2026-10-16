import { describe, expect, test } from "bun:test";
import { TranscriptHeightIndex, TranscriptStore } from "./model.ts";

describe("Gate 1 transcript model", () => {
  test("stable IDs, revisions and epochs never admit stale mutations", () => {
    const store=new TranscriptStore<string>();
    const a=store.append("user","hi"),b=store.append("assistant","");
    expect(store.update(b.id,"Hello")?.revision).toBe(1);
    expect(store.indexOf(a.id)).toBe(0);
    store.truncate(1);
    expect(store.update(b.id,"stale")).toBeUndefined();
    store.reset();
    expect(store.update(a.id,"stale")).toBeUndefined();
    expect(store.append("user","new").id).not.toBe(a.id);
  });
});
describe("Gate 1 Fenwick height index", () => {
  test("incremental append and update match naive prefix sums", () => {
    const heights:number[]=[];
    const index=new TranscriptHeightIndex();
    for(let i=0;i<1000;i++){
      const value=(i*71)%23+1;
      index.append(value);heights.push(value);
    }
    for(let i=0;i<1000;i+=19){
      const value=i%37+1;
      index.update(i,value);heights[i]=value;
    }
    for(let i=0;i<=1000;i++)expect(index.prefix(i)).toBe(heights.slice(0,i).reduce((a,b)=>a+b,0));
    const total=heights.reduce((a,b)=>a+b,0);
    for(let row=0;row<total;row+=31){
      let expected=0,sum=0;
      while(sum+heights[expected]<=row)sum+=heights[expected++];
      expect(index.rowToIndex(row)).toBe(expected);
    }
    expect(index.rowToIndex(total)).toBe(1000);
  });
  test("viewport, resize and height corrections preserve a stable anchor", () => {
    const store=new TranscriptStore<string>();
    for(let i=0;i<10000;i++)store.append("markdown",String(i));
    const index=new TranscriptHeightIndex();
    index.replace(new Array(10000).fill(3),80);
    const original=index.anchorAt(15010,store.items)!;
    index.update(3,50);index.update(11,9);
    expect(index.restoreAnchor(original,id=>store.indexOf(id))).toBe(15010+47+6);
    const range=index.range(15010,24,10);
    expect(range.endExclusive-range.first).toBeLessThan(25);
    index.replace(new Array(10000).fill(5),40);
    expect(index.restoreAnchor(original,id=>store.indexOf(id))).toBeDefined();
    index.truncate(3);
    expect(index.totalRows).toBe(15);
  });
  test("empty and zero-dimension viewport are safe",()=>{
    const index=new TranscriptHeightIndex();
    expect(index.range(0,0)).toEqual({first:0,endExclusive:0,firstRow:0,endRow:0});
    expect(index.rowToIndex(100)).toBe(0);
    expect(()=>index.append(0)).toThrow();
  });
});
