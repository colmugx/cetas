import { describe, expect, test } from "bun:test";
import { Container, type Component } from "@earendil-works/pi-tui";
import { VirtualTranscriptDocument, TranscriptScrollView, highlightLiteralRows } from "./virtual-document.ts";
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

describe("transcript text selection and clipboard", () => {
  test("drag within one message highlights selected characters, copies them, and clears on release", () => {
    const source = new Container();
    const item: SearchableComponent = {
      render: () => ["\x1b[32mhello world\x1b[0m"],
      invalidate() {},
      getSearchText: () => "hello world",
    };
    source.addChild(item);
    const document = new VirtualTranscriptDocument(source, () => 40, () => 8,
      () => ({ top: 0, followEnd: false }));
    const copied: string[] = [];
    document.attachCopy(text => { copied.push(text); });
    const layout = () => (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    layout();
    document.handleMouse({ type: "press", button: "left", x: 1, y: 0 } as never);
    expect(document.handleMouse({ type: "drag", button: "left", x: 3, y: 0 } as never)?.render).toBe(true);
    layout();
    expect(document.render(40)[0]).toContain("\x1b[7m");
    expect(document.getSelectedSourceText()).toBe("ell");
    // SGR mouse release code 3 decodes to "none", not "left".
    expect(document.handleMouse({ type: "release", button: "none", x: 3, y: 0 } as never)?.render).toBe(true);
    expect(copied).toEqual(["ell"]);
    expect(document.getSelectedSourceText()).toBeUndefined();
    layout();
    expect(document.render(40)[0]).not.toContain("\x1b[7m");
  });

  test("a plain click neither copies nor leaves persistent inversion", () => {
    const source = new Container();
    source.addChild({ render: () => ["some text"], invalidate() {} });
    const doc = new VirtualTranscriptDocument(source, () => 40, () => 8,
      () => ({ top: 0, followEnd: false }));
    const copied: string[] = [];
    doc.attachCopy(text => { copied.push(text); });
    const layout = () => (doc as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    layout();
    doc.handleMouse({ type: "press", button: "left", x: 3, y: 0 } as never);
    expect(doc.handleMouse({ type: "release", button: "none", x: 3, y: 0 } as never)?.render).toBe(true);
    layout();
    expect(doc.render(40)[0]).not.toContain("\x1b[7m");
    expect(copied).toEqual([]);
  });

  test("reverse drag and multiline drag copy only the selected text", () => {
    const source = new Container();
    source.addChild({ render: () => ["abcdef", "uvwxyz"], invalidate() {} });
    const doc = new VirtualTranscriptDocument(source, () => 40, () => 8,
      () => ({ top: 0, followEnd: false }));
    const copied: string[] = [];
    doc.attachCopy(text => { copied.push(text); });
    (doc as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    doc.handleMouse({ type: "press", button: "left", x: 4, y: 0 } as never);
    doc.handleMouse({ type: "drag", button: "left", x: 1, y: 0 } as never);
    doc.handleMouse({ type: "release", button: "none", x: 1, y: 0 } as never);
    expect(copied).toEqual(["bcde"]);
    doc.handleMouse({ type: "press", button: "left", x: 3, y: 0 } as never);
    doc.handleMouse({ type: "drag", button: "left", x: 2, y: 1 } as never);
    doc.handleMouse({ type: "release", button: "none", x: 2, y: 1 } as never);
    expect(copied[1]).toBe("def\nuvw");
  });

  test("viewport forwards SGR generic-button release and repaints the selection", () => {
    const source = new Container();
    source.addChild({ render: () => ["abcdef"], invalidate() {} });
    const doc = new VirtualTranscriptDocument(source, () => 40, () => 8,
      () => ({ top: 0, followEnd: false }));
    const copied: string[] = [];
    doc.attachCopy(text => { copied.push(text); });
    (doc as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    const view = new TranscriptScrollView(doc);
    const mouse = (type: string, button: string, x: number) =>
      ({ type, button, x, y: 0, screenX: x, screenY: 0, width: 40, height: 8 }) as never;
    view.handleMouse(mouse("press", "left", 1));
    expect(view.handleMouse(mouse("drag", "left", 3))?.render).toBe(true);
    expect(view.handleMouse(mouse("release", "none", 3))?.render).toBe(true);
    expect(copied).toEqual(["bcd"]);
    expect(doc.getSelectedSourceText()).toBeUndefined();
  });
});

describe("AltScreen native selection fallback prevention", () => {
  test("viewport consumes clicks without starting inverse-video text selection", () => {
    const source = new Container();
    for (let i = 0; i < 100; i++) {
      source.addChild({ render: () => ["message " + i], invalidate() {} });
    }
    const document = new VirtualTranscriptDocument(source, () => 80, () => 20,
      () => ({top: 0, followEnd: false}));
    (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    const view = new TranscriptScrollView(document);

    const press = view.handleMouse({type:"press",button:"left",x:4,y:8,screenX:4,screenY:8,width:80,height:20} as never);
    expect(press?.handled).toBe(true);
    expect(press?.capture).toBe(true);
    expect(press?.target.component).toBe(view);
    expect(press?.target.originY).toBe(0);
    expect(press?.render).toBe(false);
    const release = view.handleMouse({type:"release",button:"left",x:4,y:8,screenX:4,screenY:8,width:80,height:20} as never);
    expect(release?.handled).toBe(true);
    expect(release?.render).toBe(true);
    expect(document.getSelectedSourceText()).toBeUndefined();

    const click = view.handleMouse({type:"click",button:"left",x:4,y:8,screenX:4,screenY:8,width:80,height:20} as never);
    expect(click?.handled).toBe(true);
    expect(view.handleMouse({type:"wheel",button:"none",x:4,y:8,screenX:4,screenY:8,width:80,height:20} as never)).toBeUndefined();
  });

  test("scroll view sends viewport-relative gestures to document coordinates", () => {
    const source = new Container();
    let copied = "";
    for (let i = 0; i < 100; i++) {
      const item: SearchableComponent = {
        render: () => ["message " + i], invalidate() {},
        getSearchText: () => "message " + i,
      };
      source.addChild(item);
    }
    const document = new VirtualTranscriptDocument(source, () => 80, () => 20,
      () => ({top: 0, followEnd: false}));
    document.attachCopy(text => {copied = text;});
    (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
    const view = new TranscriptScrollView(document);
    view.updateLayout(document.stats.logicalRows, 20, () => {});
    view.scrollTo(60, {disableFollow:true});
    view.handleMouse({type:"press",button:"left",x:3,y:0,screenX:3,screenY:0,width:80,height:20} as never);
    view.handleMouse({type:"drag",button:"left",x:3,y:12,screenX:3,screenY:12,width:80,height:20} as never);
    view.handleMouse({type:"release",button:"left",x:3,y:12,screenX:3,screenY:12,width:80,height:20} as never);
    // The first virtual layout measures visible blocks and corrects the
    // height estimates. A scrollTop of 60 is a logical ROW, not item 20.
    const measured = (document as any).heights as import("./model.ts").TranscriptHeightIndex;
    const startItem = measured.rowToIndex(view.scrollTop);
    const endItem = measured.rowToIndex(view.scrollTop + 12);
    expect(copied.split("\n\n")).toEqual(
      Array.from({ length: endItem - startItem + 1 }, (_, i) => "message " + (startItem + i)),
    );
    expect(document.getSelectedSourceText()).toBeUndefined();
  });
});
