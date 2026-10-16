"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),crypto=require("node:crypto");
const M=require("../dist/model.js"),C=require("../dist/bridge-client.js"),D=require("../dist/directory-view.js"),T=require("../dist/file-transfers.js"),H=require("../dist/sha256.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const id=n=>"50000000-0000-0000-0000-"+n.toString(16).padStart(12,"0");
const bytes=n=>Uint8Array.from({length:n},(_,i)=>i%251),digest=bytes=>crypto.createHash("sha256").update(bytes).digest("hex");
const info=patch=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",databaseSchema:3,physicalPool:"unbound",languages:["zh-CN","ja-JP"],active:0,completed:0,logicalReferenceBytes:0,taskTimestampsAvailable:false,libraries:[],...patch});
const input=(name="new.bin",n=4)=>({libraryID:"shared",parentPath:"",name,totalBytes:n});
const preview=(p=input(),state="ready")=>({transferVersion:1,transferID:id(1),intent:p,state,chunkBytes:32768,expiresInSeconds:state==="ready"?30:0});
const status=(state="uploading",patch={})=>({transferVersion:1,transferID:id(1),state,direction:"upload",libraryID:"shared",relativePath:"new.bin",totalBytes:4,transferredBytes:0,chunkBytes:32768,sha256:null,lastChunkSHA256:null,error:null,...patch});
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
async function fixture(scenario="owner",options={}){const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(scenario),directory=await D.createFixtureDirectorySource(api,session,options);return{api,session,directory,source:directory.fileTransfers,controller:T.createController(directory.fileTransfers)};}
function sink(){const blocks=[],state={finished:0,aborted:0};return{blocks,state,async write(bytes){blocks.push(bytes);},async finish(){state.finished++;},async abort(){blocks.length=0;state.aborted++;}};}
async function client(handler,patch={}){const calls=[],client=C.createDesktopClient({transport:async request=>{calls.push(request);const data=request.method==="overview"?info(patch):await handler(request);return data?.__error?{apiVersion:1,requestId:request.requestId,error:{code:data.__error}}:{apiVersion:1,requestId:request.requestId,data};}});await client.overview();return{client,calls};}

test("incremental SHA-256 matches independent Node crypto across padding and chunk boundaries",()=>{
 for(const size of [0,1,55,56,63,64,65,127,128,32767,32768,70001,1000000]){const data=bytes(size),hash=new H.SHA256();for(let i=0;i<size;i+=997)hash.update(data.subarray(i,i+997));assert.equal(hash.hex(),digest(data));assert.equal(hash.hex(),digest(data));hash.update(Uint8Array.of(3));assert.equal(hash.hex(),digest(Buffer.concat([data,Buffer.of(3)])));}
 assert.equal(H.digest(new TextEncoder().encode("abc")),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});
test("canonical bounded parts fit the original bridge budgets without increasing string limits",()=>{
 const data=bytes(32768),parts=T.parts(data);assert.equal(parts.length,16);assert.ok(parts.every(p=>p.length<=2732));assert.deepEqual(T.decodeParts(parts),data);
 assert.ok(Buffer.byteLength(JSON.stringify({apiVersion:1,requestId:"x",method:"appendUpload",params:{transferID:id(1),offset:0,parts}}))<65536);
 for(const bad of [[],[""],["AA"],["AB=="],["YQ==","Yg=="],Array(17).fill("AA==")])assert.throws(()=>T.decodeParts(bad));
});
test("input snapshots reject accessors null paths unsafe names and oversized files before reading blobs",()=>{
 let calls=0;const p=input();Object.defineProperty(p,"name",{enumerable:true,get(){calls++;return"bad";}});assert.throws(()=>T.uploadIntent(p,true),code("invalidInput"));assert.equal(calls,0);
 for(const patch of [{parentPath:null},{name:"../bad"},{name:"a/b"},{totalBytes:16*1024*1024+1},{root:"/tmp"}])assert.throws(()=>T.uploadIntent({...input(),...patch},true),code("invalidInput"));
 const array=["YQ=="];Object.defineProperty(array,0,{enumerable:true,get(){calls++;return"YQ==";}});assert.throws(()=>T.decodeParts(array));assert.equal(calls,0);
});
test("fixture upload is invisible until confirmed publication and the same directory exposes binary bytes",async()=>{
 const {directory,controller}=await fixture(),data=bytes(70001),before=await directory.page({libraryID:"shared",pageSize:2});
 await controller.prepareUpload(input("中日.bin",data.length),new Blob([data]));assert.equal(controller.snapshot().phase,"ready");assert.equal((await directory.page({libraryID:"shared"})).items.length,8);
 await controller.startUpload();assert.equal(controller.snapshot().result.sha256,digest(data));assert.equal(controller.snapshot().transferredBytes,data.length);
 await assert.rejects(directory.page({libraryID:"shared",pageSize:2,cursor:before.nextCursor}),code("staleState"));
 assert.equal((await directory.page({libraryID:"shared"})).items.find(x=>x.name==="中日.bin").bytes,data.length);
 const out=sink();await controller.download({libraryID:"shared",relativePath:"中日.bin"},out);assert.deepEqual(Buffer.concat(out.blocks),Buffer.from(data));assert.equal(out.state.finished,1);assert.equal(controller.snapshot().phase,"completed");
});
test("empty files finish without append and download emits an empty verified block",async()=>{
 const {controller}=await fixture();await controller.prepareUpload(input("empty.bin",0),new Blob([]));await controller.startUpload();assert.equal(controller.snapshot().result.sha256,digest(Buffer.alloc(0)));
 const out=sink();await controller.download({libraryID:"shared",relativePath:"empty.bin"},out);assert.equal(out.blocks.length,1);assert.equal(out.blocks[0].length,0);assert.equal(out.state.finished,1);
});
test("conflicts never overwrite and cancellation never creates a library entry",async()=>{
 const {directory,controller,source}=await fixture();await controller.prepareUpload(input("notes",1),new Blob(["x"]));assert.equal(controller.snapshot().phase,"conflict");await assert.rejects(controller.startUpload(),code("denied"));
 const p=await source.previewUpload(input());await source.beginUpload(p.transferID);await source.appendUpload(p.transferID,0,T.parts(new TextEncoder().encode("data")));assert.equal((await source.cancel(p.transferID)).state,"cancelled");
 assert.equal((await directory.page({libraryID:"shared"})).items.length,8);
});
test("upload digest mismatch offsets and changed duplicate blocks do not publish",async()=>{
 const {source,directory}=await fixture(),p=await source.previewUpload(input());await source.beginUpload(p.transferID);
 await assert.rejects(source.appendUpload(p.transferID,1,T.parts(bytes(4))),code("replay"));await source.appendUpload(p.transferID,0,T.parts(bytes(4)));
 assert.equal((await source.appendUpload(p.transferID,0,T.parts(bytes(4)))).transferredBytes,4);
 await assert.rejects(source.appendUpload(p.transferID,0,T.parts(Uint8Array.of(9,8,7,6))),code("collision"));
 const r=await source.finishUpload(p.transferID,"0".repeat(64));assert.equal(r.state,"failed");assert.equal(r.error,"integrity");assert.equal((await directory.page({libraryID:"shared"})).items.length,8);
});
test("parent revisions invalidate previews and pinned downloads do not reopen renamed source paths",async()=>{
 const {source,directory}=await fixture(),p=await source.previewUpload(input());
 const rename=await directory.fileOperations.preview({libraryID:"shared",kind:"rename",sourceName:"01-Welcome.txt",name:"renamed.txt"});
 const d=await source.beginDownload({libraryID:"shared",relativePath:"01-Welcome.txt"});await directory.fileOperations.commit(rename.operationID);
 await assert.rejects(source.readDownloadChunk(d.transferID,0),code("staleState"));assert.equal((await source.beginUpload(p.transferID)).error,"staleState");
});
test("eight active streams and 64 MiB upload reservations are reclaimed by cancel and expiry",async()=>{
 let time=0;const {source}=await fixture("owner",{monotonicNow:()=>time}),ids=[];
 for(let n=0;n<8;n++)ids.push((await source.previewUpload(input("file"+n,16*1024*1024))).transferID);
 await assert.rejects(source.previewUpload(input("ninth")),code("budgetExceeded"));
 for(const id of ids.slice(0,4))assert.equal((await source.beginUpload(id)).state,"uploading");assert.equal((await source.beginUpload(ids[4])).error,"budgetExceeded");
 await source.cancel(ids[0]);assert.equal((await source.beginUpload(ids[5])).state,"uploading");time=60000;
 assert.equal((await source.status(ids[1])).error,"expired");time=360001;assert.equal((await source.status(ids[1])).state,"notVisible");
});
test("reader can download shared files while recovery and readers cannot upload or access private files",async()=>{
 for(const scenario of ["reader","recovery"]){const {source,controller}=await fixture(scenario);assert.equal(controller.canUpload,false);await assert.rejects(async()=>source.previewUpload(input()),code(scenario==="reader"?"denied":"readOnly"));const out=sink();await controller.download({libraryID:"shared",relativePath:"01-Welcome.txt"},out);assert.equal(out.state.finished,1);if(scenario==="reader")await assert.rejects(source.beginDownload({libraryID:"personal",relativePath:"Private.txt"}),code("denied"));}
});
test("download backpressure waits for the sink and cancellation cleans partial bytes before finishing",async()=>{
 const {controller}=await fixture(),data=bytes(70001);await controller.prepareUpload(input("large",data.length),new Blob([data]));await controller.startUpload();
 const wait=deferred(),out=sink();let writes=0;out.write=async value=>{writes++;out.blocks.push(value);await wait.promise;};
 const pending=controller.download({libraryID:"shared",relativePath:"large"},out);while(!writes)await new Promise(r=>setImmediate(r));assert.equal(writes,1);
 await controller.cancel();assert.equal(controller.snapshot().phase,"cancelling");wait.resolve();await pending;assert.equal(writes,1);assert.equal(out.state.finished,0);assert.equal(out.state.aborted,1);assert.equal(controller.snapshot().phase,"cancelled");
});
test("ended fixture sessions reject even unknown status and source disposal drops outstanding handles",async()=>{
 const {api,session,source,directory}=await fixture();const p=await source.previewUpload(input());await source.beginUpload(p.transferID);await api.endSession(session);
 await assert.rejects(source.status(id(99)),code("denied"));await assert.rejects(source.finishUpload(p.transferID,"0".repeat(64)),code("denied"));directory.dispose();assert.equal(source.closed,true);
});
test("strict DTOs reject extra fields mismatched targets invalid progress and malformed final hashes",()=>{
 for(const bad of [{...preview(),chunkBytes:65536},{...preview(),extra:true},{...preview(),intent:input("other")},{...preview(),expiresInSeconds:0}])assert.throws(()=>T.preview(bad,input()),code("invalidResponse"));
 for(const bad of [status("completed"),status("uploading",{transferredBytes:5}),status("ready",{transferredBytes:1}),status("uncertain",{direction:"download"}),status("notVisible")])assert.throws(()=>T.status(bad,id(1)),code("invalidResponse"));
});
test("typed status observation never creates write cancel or read capabilities",async()=>{
 const p=await client(()=>status());await p.client.transferStatus(id(1));await assert.rejects(p.client.beginUpload(id(1)),code("denied"));await assert.rejects(p.client.cancelTransfer(id(1)),code("denied"));await assert.rejects(p.client.readDownloadChunk({transferID:id(1),offset:0}),code("denied"));assert.equal(p.calls.length,2);p.client.close();
});
test("typed client validates progress and serializes writes without automatically replaying uncertain append",async()=>{
 const wait=deferred(),p=await client(r=>r.method==="previewUpload"?preview():r.method==="beginUpload"?status():wait.promise);
 await p.client.previewUpload(input());await p.client.beginUpload(id(1));const pending=p.client.appendUpload({transferID:id(1),offset:0,parts:T.parts(bytes(4))});
 await assert.rejects(p.client.transferStatus(id(1)),code("busy"));wait.resolve({__error:"budgetExceeded"});await assert.rejects(pending,code("budgetExceeded"));const count=p.calls.length;
 await assert.rejects(p.client.appendUpload({transferID:id(1),offset:0,parts:T.parts(bytes(4))}),code("denied"));assert.equal(p.calls.length,count);assert.equal(p.client.closed,false);p.client.close();
});
test("typed malformed response closes the connection and readonly rejection happens before transport",async()=>{
 const p=await client(()=>({...preview(),extra:true}));await assert.rejects(p.client.previewUpload(input()),code("invalidResponse"));assert.equal(p.client.closed,true);
 const readonly=await client(()=>null,{mode:"read_only_recovery"});await assert.rejects(readonly.client.previewUpload(input()),code("readOnly"));assert.equal(readonly.calls.length,1);readonly.client.close();
});
test("a masked publication reply stays uncertain until an explicit receipt check and never repeats finish",async()=>{
 const data=new TextEncoder().encode("data"),p=await client(r=>r.method==="previewUpload"?preview():r.method==="beginUpload"?status():r.method==="appendUpload"?status("uploading",{transferredBytes:4,lastChunkSHA256:digest(data)}):r.method==="finishUpload"?{__error:"budgetExceeded"}:status("completed",{transferredBytes:4,lastChunkSHA256:digest(data),sha256:digest(data)}));
 const controller=T.createController(await T.createClientSource(p.client));await controller.prepareUpload(input(),new Blob([data]));await assert.rejects(controller.startUpload(),code("budgetExceeded"));assert.equal(controller.snapshot().phase,"uncertain");await controller.check();assert.equal(controller.snapshot().phase,"completed");assert.equal(p.calls.filter(x=>x.method==="finishUpload").length,1);p.client.close();
});
test("transport closure cannot reconnect or turn an unknown publication result into success",async()=>{
 const p=await client(r=>r.method==="previewUpload"?preview():Promise.reject(Error("offline"))),controller=T.createController(await T.createClientSource(p.client));await controller.prepareUpload(input(),new Blob(["data"]));
 await assert.rejects(controller.startUpload(),code("unavailable"));assert.equal(controller.snapshot().phase,"uncertain");const count=p.calls.length;await assert.rejects(controller.check(),code("unavailable"));assert.equal(p.calls.length,count);assert.equal(p.client.closed,true);
});
function borrowed(source,patch={}){return T.createSource(source.context,{previewUpload:p=>source.previewUpload(p),beginUpload:id=>source.beginUpload(id),appendUpload:(id,offset,parts)=>source.appendUpload(id,offset,parts),finishUpload:(id,hash)=>source.finishUpload(id,hash),beginDownload:p=>source.beginDownload(p),readDownloadChunk:(id,offset)=>source.readDownloadChunk(id,offset),status:id=>source.status(id),cancel:id=>source.cancel(id),isClosed:()=>source.closed,...patch});}
test("upload cancellation at a yielded block boundary leaves no published target",async()=>{
 const {source,directory}=await fixture();let controller;controller=T.createController(source,{onChange:view=>{if(view.phase==="uploading"&&view.transferredBytes===32768)void controller.cancel();}});
 const data=bytes(70001);await controller.prepareUpload(input("cancel-boundary.bin",data.length),new Blob([data]));await controller.startUpload();assert.equal(controller.snapshot().phase,"cancelled");assert.equal(controller.snapshot().transferredBytes,32768);assert.equal((await source.status(controller.snapshot().transferID)).state,"cancelled");assert.equal((await directory.page({libraryID:"shared"})).items.length,8);
});
test("cancel during an in-flight preview disposes its eventual capability without making it ready",async()=>{
 const {source}=await fixture(),gate=deferred();let captured;const wrapped=borrowed(source,{async previewUpload(p){captured=await source.previewUpload(p);await gate.promise;return captured;}}),controller=T.createController(wrapped);
 const pending=controller.prepareUpload(input(),new Blob(["data"]));while(!captured)await new Promise(r=>setImmediate(r));await controller.cancel();gate.resolve();await pending;
 assert.equal(controller.snapshot().phase,"cancelled");assert.equal((await source.status(captured.transferID)).state,"cancelled");
});
test("a corrupted whole-file download digest aborts the sink and never offers a finished Blob",async()=>{
 const {source}=await fixture(),wrapped=borrowed(source,{async readDownloadChunk(id,offset){return{...await source.readDownloadChunk(id,offset),sha256:"0".repeat(64)};}}),controller=T.createController(wrapped),out=sink();
 await assert.rejects(controller.download({libraryID:"shared",relativePath:"01-Welcome.txt"},out),code("integrity"));assert.equal(out.state.finished,0);assert.equal(out.state.aborted,1);assert.equal(out.blocks.length,0);assert.equal(controller.snapshot().phase,"failed");
});
test("closing during a published finish drops late UI success and preserves the existing file",async()=>{
 const {source,directory}=await fixture(),gate=deferred();let captured;
 const wrapped=borrowed(source,{async finishUpload(id,hash){captured=await source.finishUpload(id,hash);await gate.promise;return captured;}}),controller=T.createController(wrapped);
 await controller.prepareUpload(input(),new Blob(["data"]));const pending=controller.startUpload();while(!captured)await new Promise(r=>setImmediate(r));controller.dispose();gate.resolve();await pending;
 assert.equal(controller.snapshot().phase,"closed");assert.equal(controller.snapshot().result,null);assert.equal((await directory.page({libraryID:"shared"})).items.find(x=>x.name==="new.bin").bytes,4);assert.equal(source.closed,false);
});
test("a long-lived typed controller releases old local capabilities instead of exhausting its forty-slot budget",async()=>{
 const {source}=await fixture(),p=await client(r=>{
  if(r.method==="previewUpload")return source.previewUpload(r.params);
  if(r.method==="beginUpload")return source.beginUpload(r.params.transferID);
  if(r.method==="finishUpload")return source.finishUpload(r.params.transferID,r.params.sha256);
  if(r.method==="transferStatus")return source.status(r.params.transferID);
  throw Error("unexpected operation");
 }),controller=T.createController(await T.createClientSource(p.client));
 for(let i=0;i<45;i++){await controller.prepareUpload(input("empty-"+i,0),new Blob([]));await controller.startUpload();assert.equal(controller.snapshot().phase,"completed");}
 assert.equal(p.client.closed,false);assert.equal((await p.client.transferStatus(controller.snapshot().transferID)).state,"completed");controller.dispose();p.client.close();
});
