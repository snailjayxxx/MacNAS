"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),B=require("../dist/bridge-client.js"),D=require("../dist/directory-view.js"),C=require("../dist/file-copies.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const id=n=>"60000000-0000-0000-0000-"+n.toString(16).padStart(12,"0");
const intent=(name="copy.txt")=>({sourceLibraryID:"shared",sourcePath:"01-Welcome.txt",targetLibraryID:"shared",parentPath:"",name});
const preview=(n=1,p=intent(),state="ready",totalBytes=4)=>({copyVersion:1,copyID:id(n),intent:p,state,totalBytes,chunkBytes:32768,expiresInSeconds:state==="ready"?30:0});
const status=(state="copying",patch={})=>({copyVersion:1,copyID:id(1),state,intent:intent(),totalBytes:4,copiedBytes:0,chunkBytes:32768,sha256:null,error:null,...patch});
const info=patch=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",databaseSchema:3,physicalPool:"unbound",languages:["zh-CN","ja-JP"],active:0,completed:0,logicalReferenceBytes:0,taskTimestampsAvailable:false,libraries:[],...patch});
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
async function client(handler,patch={}){const calls=[],client=B.createDesktopClient({transport:async request=>{calls.push(request);const data=request.method==="overview"?info(patch):await handler(request);return data?.__error?{apiVersion:1,requestId:request.requestId,error:{code:data.__error}}:{apiVersion:1,requestId:request.requestId,data};}});await client.overview();return{client,calls};}
async function fixture(scenario="owner",options={}){const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(scenario),directory=await D.createFixtureDirectorySource(api,session,options);return{api,session,directory,source:directory.fileCopies,controller:C.createController(directory.fileCopies)};}
async function until(predicate){for(let n=0;n<1000;n++){if(predicate())return;await new Promise(r=>setImmediate(r));}assert.fail("deferred fixture did not reach its operation boundary");}
function borrowed(source,patch={}){return C.createSource(source.context,{preview:p=>source.preview(p),begin:id=>source.begin(id),chunk:(id,offset)=>source.chunk(id,offset),status:id=>source.status(id),cancel:id=>source.cancel(id),discard:id=>source.discard(id),isClosed:()=>source.closed,...patch});}

test("copy intents snapshot exact fields and reject accessors unsafe source and target paths",()=>{
 const omitted=intent();delete omitted.parentPath;assert.deepEqual(C.intent(omitted,true),intent());
 let read=0;const p=intent();Object.defineProperty(p,"sourcePath",{enumerable:true,get(){read++;return"bad";}});assert.throws(()=>C.intent(p,true),code("invalidInput"));assert.equal(read,0);
 for(const p of [{...intent(),sourcePath:"../bad"},{...intent(),parentPath:null},{...intent(),name:"bad/target"},{...intent(),root:"/tmp"}])assert.throws(()=>C.intent(p,true),code("invalidInput"));
});
test("copy DTO validation binds both ends size and publication state",()=>{
 C.preview(preview(),intent());C.status(status(),id(1),{intent:intent(),totalBytes:4});
 for(const p of [{...preview(),extra:true},{...preview(),intent:intent("other")},{...preview(),state:"unchanged",expiresInSeconds:0},{...preview(),totalBytes:16*1024*1024+1}])assert.throws(()=>C.preview(p,intent()),code("invalidResponse"));
 for(const p of [status("completed"),status("copying",{copiedBytes:5}),status("failed"),status("ready",{copiedBytes:1}),status("notVisible"),status("completed",{copiedBytes:4,sha256:"f".repeat(64),intent:intent("wrong")})])assert.throws(()=>C.status(p,id(1),{intent:intent(),totalBytes:4}),code("invalidResponse"));
 C.status(status("notVisible",{intent:null,totalBytes:null,copiedBytes:null,sha256:null,error:null}),id(1));
});
test("fixture copy confirms before publishing and retains exact source bytes",async()=>{
 const {directory,controller}=await fixture(),sourcePage=await directory.page({libraryID:"shared"});
 await controller.prepare(intent("copied.txt"));assert.equal(controller.snapshot().phase,"ready");assert.equal((await directory.page({libraryID:"shared"})).items.length,sourcePage.items.length);
 await controller.confirm();assert.equal(controller.snapshot().phase,"completed");assert.equal(controller.snapshot().result.copiedBytes,controller.snapshot().totalBytes);
 const page=await directory.page({libraryID:"shared"});assert.ok(page.items.some(x=>x.name==="01-Welcome.txt"));assert.equal(page.items.find(x=>x.name==="copied.txt").bytes,page.items.find(x=>x.name==="01-Welcome.txt").bytes);
 assert.equal((await directory.preview({libraryID:"shared",relativePath:"copied.txt"})).text,(await directory.preview({libraryID:"shared",relativePath:"01-Welcome.txt"})).text);
});
test("same target and conflicts cannot be confirmed or overwrite files",async()=>{
 const {controller,directory}=await fixture();await controller.prepare(intent("01-Welcome.txt"));assert.equal(controller.snapshot().phase,"unchanged");await assert.rejects(controller.confirm(),code("denied"));
 await controller.prepare(intent("notes"));assert.equal(controller.snapshot().phase,"conflict");await assert.rejects(controller.confirm(),code("denied"));assert.equal((await directory.page({libraryID:"shared"})).items.length,8);
});
test("typed copy status cannot adopt an unknown capability and metadata violations close transport",async()=>{
 const p=await client(()=>status());await p.client.fileCopyStatus(id(1));await assert.rejects(p.client.beginFileCopy(id(1)),code("denied"));await assert.rejects(p.client.copyFileChunk({copyID:id(1),offset:0}),code("denied"));await assert.rejects(p.client.cancelFileCopy(id(1)),code("denied"));assert.equal(p.calls.length,2);p.client.close();
 const bad=await client(()=>({...preview(),extra:true}));await assert.rejects(bad.client.previewFileCopy(intent()),code("invalidResponse"));assert.equal(bad.client.closed,true);
});
test("typed copy serializes an ID and blocks reissuing an uncertain chunk",async()=>{
 const gate=deferred(),p=await client(r=>r.method==="previewFileCopy"?preview():r.method==="beginFileCopy"?status():gate.promise);
 await p.client.previewFileCopy(intent());await p.client.beginFileCopy(id(1));const pending=p.client.copyFileChunk({copyID:id(1),offset:0});await assert.rejects(p.client.fileCopyStatus(id(1)),code("busy"));gate.resolve({__error:"budgetExceeded"});await assert.rejects(pending,code("budgetExceeded"));
 const count=p.calls.length;await assert.rejects(p.client.copyFileChunk({copyID:id(1),offset:0}),code("denied"));await assert.rejects(p.client.beginFileCopy(id(1)),code("denied"));assert.equal(p.calls.length,count);assert.equal(p.client.closed,false);p.client.close();
});
test("masked final copy reply remains uncertain until explicit check without chunk resubmission",async()=>{
 const completed=status("completed",{copiedBytes:4,sha256:"a".repeat(64)}),p=await client(r=>r.method==="previewFileCopy"?preview():r.method==="beginFileCopy"?status():r.method==="copyFileChunk"?{__error:"budgetExceeded"}:completed),controller=C.createController(await C.createClientSource(p.client));
 await controller.prepare(intent());await assert.rejects(controller.confirm(),code("budgetExceeded"));assert.equal(controller.snapshot().phase,"uncertain");await assert.rejects(controller.prepare(intent("again")),code("staleState"));await controller.check();assert.equal(controller.snapshot().phase,"completed");assert.equal(p.calls.filter(x=>x.method==="copyFileChunk").length,1);p.client.close();
});
test("copy source access enforces independent administrator write context",async()=>{
 for(const scenario of ["reader","recovery"]){const {source,controller}=await fixture(scenario);assert.equal(controller.canCopy,false);await assert.rejects(async()=>source.preview(intent()),code(scenario==="reader"?"denied":"readOnly"));}
 const p=await client(()=>null,{mode:"read_only_recovery"});await assert.rejects(p.client.previewFileCopy(intent()),code("readOnly"));assert.equal(p.calls.length,1);p.client.close();
});
test("closing or cancelling a late copy preview cancels and discards its acquired capability",async()=>{
 for(const close of [false,true]){const {source}=await fixture(),gate=deferred();let captured,cancels=0,discards=0;
  const wrapped=borrowed(source,{async preview(p){captured=await source.preview(p);await gate.promise;return captured;},cancel(id){cancels++;return source.cancel(id);},discard(id){discards++;return source.discard(id);}}),controller=C.createController(wrapped);
  const pending=controller.prepare(intent());await until(()=>captured);if(close)controller.dispose();else await controller.cancel();gate.resolve();await pending;
  assert.equal(controller.snapshot().phase,close?"closed":"cancelled");assert.equal(cancels,1);assert.equal(discards,1);assert.equal(source.closed,false);
 }
});
test("failed late-preview cancellation is uncertain and never claims success",async()=>{
 const {source}=await fixture(),gate=deferred();let captured;const wrapped=borrowed(source,{async preview(p){captured=await source.preview(p);await gate.promise;return captured;},async cancel(){throw new M.ServiceError("unavailable");}}),controller=C.createController(wrapped);
 const pending=controller.prepare(intent());await until(()=>captured);await controller.cancel();gate.resolve();await pending;assert.equal(controller.snapshot().phase,"uncertain");assert.equal(controller.snapshot().error,"unavailable");
});
test("copy client has an independent forty-record budget and explicit discards free it",async()=>{
 let sequence=0;const p=await client(r=>r.method==="previewFileCopy"?preview(++sequence,r.params):null);
 const ids=[];for(let n=0;n<40;n++)ids.push((await p.client.previewFileCopy(intent("file-"+n))).copyID);await assert.rejects(p.client.previewFileCopy(intent("overflow")),code("budgetExceeded"));assert.equal(sequence,40);
 assert.equal(p.client.discardFileCopy(ids[0]),true);await p.client.previewFileCopy(intent("replacement"));assert.equal(sequence,41);assert.equal(p.client.closed,false);p.client.close();
});
test("repeated windows release late copy preview heads without closing shared client",async()=>{
 const {source}=await fixture();let current;
 const p=await client(async r=>{if(r.method==="previewFileCopy"){const value=await source.preview(r.params);current.captured=value;await current.gate.promise;return value;}if(r.method==="cancelFileCopy")return source.cancel(r.params.copyID);throw Error("unexpected");});
 const shared=await C.createClientSource(p.client);
 for(let n=0;n<45;n++){current={gate:deferred()};const controller=C.createController(shared),pending=controller.prepare(intent("copy-"+n));await until(()=>current.captured);controller.dispose();current.gate.resolve();await pending;assert.equal(controller.snapshot().phase,"closed");}
 assert.equal(p.client.closed,false);assert.equal(p.calls.filter(r=>r.method==="cancelFileCopy").length,45);p.client.close();
});
test("pending preview heads share the forty-record client budget with ready copies",async()=>{
 let sequence=0;const gate=deferred(),p=await client(async r=>{const value=preview(++sequence,r.params);if(sequence>8)await gate.promise;return value;});
 for(let n=0;n<8;n++)await p.client.previewFileCopy(intent("ready-"+n));
 const pending=Array.from({length:32},(_,n)=>p.client.previewFileCopy(intent("pending-"+n)));await assert.rejects(p.client.previewFileCopy(intent("overflow")),code("budgetExceeded"));assert.equal(sequence,40);gate.resolve();await Promise.all(pending);assert.equal(p.client.closed,false);p.client.close();
});
test("an explicit previous-block copy replay accepts expiry without closing the shared connection",async()=>{
 let chunks=0;const p=await client(r=>r.method==="previewFileCopy"?preview(1,intent(),"ready",40000):r.method==="beginFileCopy"?status("copying",{totalBytes:40000}):status(chunks++===0?"copying":"failed",{totalBytes:40000,copiedBytes:32768,error:chunks===1?null:"expired"}));
 await p.client.previewFileCopy(intent());await p.client.beginFileCopy(id(1));assert.equal((await p.client.copyFileChunk({copyID:id(1),offset:0})).state,"copying");assert.equal((await p.client.copyFileChunk({copyID:id(1),offset:0})).state,"failed");assert.equal(p.client.closed,false);p.client.close();
});
test("disposing a copy source reclaims its late preview without closing the shared client",async()=>{
 const {source:host}=await fixture();let current;const p=await client(async r=>{if(r.method==="previewFileCopy"){const value=await host.preview(r.params);current.captured=value;await current.gate.promise;return value;}if(r.method==="cancelFileCopy")return host.cancel(r.params.copyID);throw Error("unexpected operation");});
 for(let n=0;n<45;n++){
  current={gate:deferred()};const source=await C.createClientSource(p.client),controller=C.createController(source),pending=controller.prepare(intent("source-dispose-"+n));await until(()=>current.captured);source.dispose();controller.dispose();current.gate.resolve();await assert.rejects(pending,code("unavailable"));
  assert.equal((await host.status(current.captured.copyID)).state,"cancelled");await assert.rejects(p.client.beginFileCopy(current.captured.copyID),code("denied"));assert.equal(p.client.closed,false);assert.equal(controller.snapshot().phase,"closed");
 }
 assert.equal(p.calls.filter(r=>r.method==="cancelFileCopy").length,45);p.client.close();
});
test("disposing a copy source cancels ready IDs and never adopts status-only observations",async()=>{
 const {source:host}=await fixture(),p=await client(r=>r.method==="previewFileCopy"?host.preview(r.params):r.method==="fileCopyStatus"?host.status(r.params.copyID):r.method==="cancelFileCopy"?host.cancel(r.params.copyID):host.begin(r.params.copyID)),source=await C.createClientSource(p.client);
 const owned=await source.preview(intent("owned.txt")),foreign=await p.client.previewFileCopy(intent("foreign.txt"));await source.status(foreign.copyID);source.dispose();await new Promise(r=>setImmediate(r));
 assert.equal((await host.status(owned.copyID)).state,"cancelled");assert.equal((await host.status(foreign.copyID)).state,"ready");await assert.rejects(p.client.beginFileCopy(owned.copyID),code("denied"));assert.equal((await p.client.beginFileCopy(foreign.copyID)).state,"copying");assert.equal(p.client.closed,false);await p.client.cancelFileCopy(foreign.copyID);p.client.discardFileCopy(foreign.copyID);p.client.close();
});
test("disposing during an in-flight copy chunk defers cancellation until that ID is idle",async()=>{
 const {directory,source:host}=await fixture(),T=require("../dist/file-transfers.js"),upload=T.createController(directory.fileTransfers),data=new Uint8Array(70001);await upload.prepareUpload({libraryID:"shared",name:"large.bin",totalBytes:data.length},new Blob([data]));await upload.startUpload();
 const gate=deferred();let captured,cancels=0;const p=await client(async r=>{if(r.method==="previewFileCopy")return host.preview(r.params);if(r.method==="beginFileCopy")return host.begin(r.params.copyID);if(r.method==="copyFileChunk"){captured=await host.chunk(r.params.copyID,r.params.offset);await gate.promise;return captured;}if(r.method==="cancelFileCopy"){cancels++;return host.cancel(r.params.copyID);}throw Error("unexpected operation");}),source=await C.createClientSource(p.client),head=await source.preview({...intent("partial.bin"),sourcePath:"large.bin"});await source.begin(head.copyID);
 const pending=source.chunk(head.copyID,0);await until(()=>captured);source.dispose();assert.equal(cancels,0);gate.resolve();await assert.rejects(pending,code("unavailable"));assert.equal(cancels,1);assert.equal((await host.status(head.copyID)).state,"cancelled");await assert.rejects(p.client.copyFileChunk({copyID:head.copyID,offset:32768}),code("denied"));assert.ok(!(await directory.page({libraryID:"shared"})).items.some(x=>x.name==="partial.bin"));assert.equal(p.client.closed,false);p.client.close();
});
test("copy sources bound owned and pending heads to forty and discard releases local tracking",async()=>{
 let sequence=0;const source=C.createSource({source:"fixture-host",userID:"owner",role:"administrator",mode:"synthetic_development"},{preview:async p=>preview(++sequence,p),cancel:async copyID=>status("cancelled",{copyID}),discard:()=>true,status:async copyID=>status("notVisible",{copyID,intent:null,totalBytes:null,copiedBytes:null,sha256:null,error:null})});
 for(let n=0;n<50;n++)await source.status(id(100+n));const heads=[];for(let n=0;n<40;n++)heads.push(await source.preview(intent("own-"+n)));await assert.rejects(source.preview(intent("overflow")),code("budgetExceeded"));assert.equal(sequence,40);source.discard(heads[0].copyID);await source.preview(intent("replacement"));assert.equal(sequence,41);source.dispose();
});
