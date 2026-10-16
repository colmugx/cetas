import { describe, expect, test } from "bun:test";
import { Container, type Component } from "@earendil-works/pi-tui";
import { VirtualTranscriptDocument, highlightLiteralRows } from "./virtual-document.ts";
import type { SearchableComponent } from "./search-index.ts";

describe("Gate 2 logical-height virtual layout", () => {
  test("ten thousand messages only render a bounded visible window", () => {
    const source = new Container();
    let rendered = 0;
    for(let i=0;i<10000;i++) {
      const component: Component = {render:() => {rendered++;return [String(i)];},invalidate(){}};
      source.addChild(component);
    }
    const document = new VirtualTranscriptDocument(source,()=>80,()=>24,()=>({top:0,followEnd:true}));
    const layout = (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    expect(layout.entries).toHaveLength(3);
    expect(layout.entries.reduce((n:number,e:{basis:number})=>n+e.basis,0)).toBe(document.stats.logicalRows);
    expect(document.stats.totalItems).toBe(10000);
    expect(document.stats.mountedItems).toBeLessThan(35);
    expect(rendered).toBeLessThan(35);
    expect(document.render(80)).toHaveLength(document.stats.renderedLines);
    expect(document.render(80).length).toBeLessThan(35);
  });
  test("scroll follows a stable logical row, resize invalidates heights", () => {
    const source=new Container();
    let width=80,top=70, followEnd=false;
    for(let i=0;i<100;i++) source.addChild({
      render: (w:number)=>Array.from({length:w<50?4:2},()=>String(i)),
      invalidate(){},
    });
    const document=new VirtualTranscriptDocument(source,()=>width,()=>12,()=>({top,followEnd}));
    (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    expect(document.stats.mountedItems).toBeLessThan(20);
    expect(document.stats.logicalRows).toBeGreaterThan(100);
    top=120;width=40;
    (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    expect(document.stats.mountedItems).toBeLessThan(20);
    followEnd=true;
    (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    expect(document.stats.endExclusive).toBe(100);
    source.clear();
    document.reset();
    (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    expect(document.stats.logicalRows).toBe(0);
  });
});

describe("Gate 5 measured height scroll anchor", () => {
  test("reconciles visible rows before an unfollowed viewport", () => {
    const source = new Container();
    for (let i = 0; i < 100; i++) source.addChild({
      render: () => Array.from({length: i===20 ? 8 : 1},()=>String(i)),
      invalidate() {},
    });
    const document = new VirtualTranscriptDocument(source,()=>80,()=>15,()=>({top:65,followEnd:false}));
    const corrected:number[] = [];
    document.attachNavigation(row=>corrected.push(row));
    (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    expect(corrected.every(n=>Number.isFinite(n) && n>=0)).toBe(true);
    expect(document.stats.mountedItems).toBeLessThan(30);
  });
});

describe("visible source match highlighting",()=>{
  test("highlights literal text without changing visible width",()=>{
    const original=["\x1b[33mbanana asked main\x1b[0m"];
    const result=highlightLiteralRows(original,"banana asked main",[{offset:0,length:6}],80);
    expect(result[0]).toContain("\x1b[4m");
    expect(result[0]).toContain("banana");
    expect(result[0]).not.toBe(original[0]);
  });
  test("avoids uncertain Markdown and image payloads",()=>{
    expect(highlightLiteralRows(["shown"],"**banana**",[{offset:2,length:6}],80)).toEqual(["shown"]);
    const image="\x1b_Ga=T;payload\x1b\\";
    expect(highlightLiteralRows([image],"banana",[{offset:0,length:6}],80)).toEqual([image]);
  });
});

describe("virtual message-range mouse selection", () => {
  test("drag across unmounted history copies source without painting skipped items", async () => {
    const source = new Container();
    let renders = 0;
    for (let i=0;i<10000;i++) {
      const item: SearchableComponent = {
        getSearchText: () => "message " + i,
        render: () => {renders++;return ["message " + i];},
        invalidate() {},
      };
      source.addChild(item);
    }
    const document = new VirtualTranscriptDocument(source,()=>80,()=>20,()=>({top:0,followEnd:false}));
    const copied:string[]=[];
    document.attachCopy(text=>{copied.push(text);});
    (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    const before=renders;
    document.handleMouse({type:"press",button:"left",x:0,y:100,width:80,height:10000} as never);
    document.handleMouse({type:"drag",button:"left",x:0,y:4500,width:80,height:10000} as never);
    document.handleMouse({type:"release",button:"left",x:0,y:4500,width:80,height:10000} as never);
    expect(copied).toHaveLength(1);
    expect(copied[0]).toContain("message 33");
    expect(copied[0]).toContain("message 1500");
    expect(renders).toBe(before);
  });
});

describe("click selection appearance", () => {
  test("single clicks do not invert a transcript block", () => {
    const source = new Container();
    source.addChild({ render:()=>["plain"], invalidate(){} });
    const doc = new VirtualTranscriptDocument(source,()=>40,()=>6,()=>({top:0,followEnd:false}));
    (doc as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    doc.handleMouse({type:"press",button:"left",x:0,y:0} as never);
    doc.handleMouse({type:"release",button:"left",x:0,y:0} as never);
    (doc as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    expect(doc.render(40).join("\n")).not.toContain("\x1b[7m");
    expect(doc.getSelectedSourceText()).toBeUndefined();
  });
});
