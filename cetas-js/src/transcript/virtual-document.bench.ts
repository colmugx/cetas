/**
 * Gate 5 regression probe.
 * Run: cd cetas-js && bun --preload ./moonbit-preload.ts src/transcript/virtual-document.bench.ts
 */
import { performance } from "node:perf_hooks";
import { Container } from "@earendil-works/pi-tui";
import { VirtualTranscriptDocument } from "./virtual-document.ts";
import { TranscriptSearchIndex, type SearchableComponent } from "./search-index.ts";

const messages = 10_000;
let paintCount = 0;
const source = new Container();
for(let index=0;index<messages;index++){
  const label = `message ${index} · stable content in Cetas session`;
  const item: SearchableComponent = {
    getSearchText:()=>label,
    render:(_width:number)=>{paintCount++;return [label];},
    invalidate(){},
  };
  source.addChild(item);
}
let top=0;
const document=new VirtualTranscriptDocument(source,()=>100,()=>30,()=>({top,followEnd:false}));
const start=performance.now();
const layouts=300;
let mountedMax=0;
for(let i=0;i<layouts;i++){
  top=i*101;
  (document as any)[Symbol.for("@earendil-works/pi-tui/layout-node")]();
  mountedMax=Math.max(mountedMax,document.stats.mountedItems);
}
const layoutMs=performance.now()-start;
const search=new TranscriptSearchIndex();
const searchStart=performance.now();
const hits=search.search(source.children,"message 9876");
const searchMs=performance.now()-searchStart;
if(hits.length!==1 || paintCount>=messages ||
   document.stats.totalItems!==messages || mountedMax>=100){
  throw new Error(JSON.stringify({hits:hits.length,paintCount,mountedMax,stats:document.stats}));
}
console.log(JSON.stringify({
  messages,layouts,layoutMs,searchMs,renderCalls:paintCount,
  maxMounted:mountedMax,searchHits:hits.length,
  note:"No timing threshold: compare runs on the same machine and inspect RSS/heap separately",
},null,2));
