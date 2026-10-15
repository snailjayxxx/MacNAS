"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),C=require("../dist/bridge-client.js"),D=require("../dist/directory-view.js"),O=require("../dist/file-operations.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const id=n=>"40000000-0000-0000-0000-"+n.toString(16).padStart(12,"0");
const intent=(name="new",patch={})=>({libraryID:"library",parentPath:"",kind:"createDirectory",sourceName:null,name,...patch});
const preview=(p=intent(),state="ready")=>({previewVersion:1,operationID:id(1),intent:p,state,expiresInSeconds:state==="ready"?30:0});
const result=(state="completed",p=intent(),error=null)=>({resultVersion:1,operationID:id(1),state,intent:p,error});
const info=patch=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",databaseSchema:3,physicalPool:"unbound",languages:["zh-CN","ja-JP"],active:0,completed:0,logicalReferenceBytes:0,taskTimestampsAvailable:false,libraries:[],...patch});
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
async function client(handler,patch={},config={}){
 const calls=[],value=C.createDesktopClient({transport:async r=>{calls.push(r);const data=r.method==="overview"?info(patch):await handler(r);return data?.__error?{apiVersion:1,requestId:r.requestId,error:{code:data.__error}}:{apiVersion:1,requestId:r.requestId,data};},...config});await value.overview();return{client:value,calls};
}
async function fixture(scenario="owner",options={}){const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(scenario),source=await D.createFixtureDirectorySource(api,session,options);return{api,session,source,operations:source.fileOperations,controller:O.createController(source.fileOperations)};}
test("fixture creates directories only after confirmation and reread sees the actual memory mutation",async()=>{
 const {source,controller}=await fixture();assert.equal((await source.page({libraryID:"shared"})).items.length,8);
 await controller.prepare({libraryID:"shared",kind:"createDirectory",name:"新目录"});assert.equal(controller.snapshot().phase,"ready");
 assert.equal((await source.page({libraryID:"shared"})).items.length,8);await controller.commit();assert.equal(controller.snapshot().phase,"completed");
 assert.equal((await source.page({libraryID:"shared"})).items.length,9);assert.deepEqual((await source.page({libraryID:"shared",relativePath:"新目录"})).items,[]);
 await assert.rejects(controller.commit(),code("denied"));
});
test("renaming a directory preserves nested text and old paths stop working",async()=>{
 const {source,controller}=await fixture();await controller.prepare({libraryID:"shared",kind:"rename",sourceName:"Notes",name:"メモ"});await controller.commit();
 assert.equal((await source.page({libraryID:"shared",relativePath:"メモ"})).items[0].relativePath,"メモ/Readme.txt");
 assert.match((await source.preview({libraryID:"shared",relativePath:"メモ/Readme.txt"})).text,/合成/);
 await assert.rejects(source.page({libraryID:"shared",relativePath:"Notes"}),code("denied"));
});
test("conflicts and unchanged names never grant a commit or overwrite content",async()=>{
 const {controller,source}=await fixture();await controller.prepare({libraryID:"shared",kind:"createDirectory",name:"notes"});assert.equal(controller.snapshot().phase,"conflict");
 await assert.rejects(controller.commit(),code("denied"));await controller.prepare({libraryID:"shared",kind:"rename",sourceName:"Notes",name:"Notes"});assert.equal(controller.snapshot().phase,"unchanged");
 assert.equal((await source.page({libraryID:"shared"})).items.length,8);
});
test("directory mutation invalidates previously issued continuations and other previews",async()=>{
 const {source,operations}=await fixture(),page=await source.page({libraryID:"shared",pageSize:2});
 const first=await operations.preview({libraryID:"shared",kind:"createDirectory",name:"first"}),second=await operations.preview({libraryID:"shared",kind:"createDirectory",name:"second"});
 assert.equal((await operations.commit(first.operationID)).state,"completed");assert.equal((await operations.commit(second.operationID)).error,"staleState");
 await assert.rejects(source.page({libraryID:"shared",pageSize:2,cursor:page.nextCursor}),code("staleState"));
 assert.equal((await source.page({libraryID:"shared"})).items.length,9);
});
test("concurrent duplicate fixture submissions retain one successful result without overwriting the receipt",async()=>{
 const {source,operations}=await fixture(),p=await operations.preview({libraryID:"shared",kind:"createDirectory",name:"once"});
 const results=await Promise.all([operations.commit(p.operationID),operations.commit(p.operationID)]);
 assert.deepEqual(results.map(value=>value.state),["completed","completed"]);
 assert.equal((await operations.status(p.operationID)).state,"completed");assert.equal((await source.page({libraryID:"shared"})).items.length,9);
});
test("reader and recovery sources expose no writable capability",async()=>{
 for(const scenario of ["reader","recovery"]){const {operations}=await fixture(scenario);assert.equal(operations.canWrite,false);await assert.rejects(async()=>operations.preview({libraryID:"shared",kind:"createDirectory",name:"no"}),code(scenario==="reader"?"denied":"readOnly"));}
});
test("expired fixture previews return failed results without writing and receipts are bounded",async()=>{
 let time=0;const {operations,source}=await fixture("owner",{monotonicNow:()=>time});const p=await operations.preview({libraryID:"shared",kind:"createDirectory",name:"late"});time=30000;
 const r=await operations.commit(p.operationID);assert.equal(r.state,"failed");assert.equal(r.error,"expired");assert.equal((await source.page({libraryID:"shared"})).items.length,8);
 time=330001;assert.equal((await operations.status(p.operationID)).state,"notVisible");await assert.rejects(operations.commit(p.operationID),code("replay"));
});
test("input validation captures data without invoking accessors or accepting arbitrary paths",()=>{
 let calls=0;const bad={libraryID:"library",kind:"createDirectory"};Object.defineProperty(bad,"name",{enumerable:true,get(){calls++;return"bad";}});
 assert.throws(()=>O.intent(bad,true),code("invalidInput"));assert.equal(calls,0);
 for(const name of ["../x","a/b","a\\b","C:x","\0x",".","..","", "x".repeat(256)])assert.throws(()=>O.intent({libraryID:"x",kind:"createDirectory",name},true));
 assert.throws(()=>O.intent({libraryID:"x",kind:"createDirectory",name:"ok",sourceName:"other"},true),code("invalidInput"));
});
test("typed client requires its own ready preview and does not gain commit authority from a status query",async()=>{
 const p=await client(r=>r.method==="previewFileOperation"?preview():result());await p.client.fileOperationStatus(id(1));
 await assert.rejects(p.client.commitFileOperation(id(1)),code("denied"));await p.client.previewFileOperation(intent());await p.client.commitFileOperation(id(1));
 await assert.rejects(p.client.commitFileOperation(id(1)),code("denied"));assert.deepEqual(p.calls.at(-1).params,{operationID:id(1),confirmed:true});
 p.client.close();
});
test("typed DTOs reject wrong targets fields versions and inconsistent result states",async()=>{
 for(const bad of [{...preview(),extra:true},{...preview(),intent:intent("other")},{...preview(),previewVersion:2},{...preview(),expiresInSeconds:0}]){
  const p=await client(()=>bad);await assert.rejects(p.client.previewFileOperation(intent()),code("invalidResponse"));assert.equal(p.client.closed,true);
 }
 for(const bad of [{...result(),operationID:id(9)},{...result(),state:"notVisible"},{...result(),state:"completed",error:"denied"}])assert.throws(()=>O.result(bad,id(1)),code("invalidResponse"));
});
test("a commit reply masked by a fixed business error stays uncertain until an explicit observation",async()=>{
 const p=await client(r=>r.method==="previewFileOperation"?preview():r.method==="commitFileOperation"?{__error:"budgetExceeded"}:result());
 const source=await O.createClientSource(p.client),controller=O.createController(source);await controller.prepare(intent());
 await assert.rejects(controller.commit(),code("budgetExceeded"));assert.equal(controller.snapshot().phase,"uncertain");
 await assert.rejects(controller.prepare(intent("different")),code("staleState"));const before=p.calls.length;
 await controller.check();assert.equal(p.calls.length,before+1);assert.equal(p.calls.at(-1).method,"fileOperationStatus");assert.equal(controller.snapshot().phase,"completed");
 controller.dispose();assert.equal(p.client.closed,false);p.client.close();
});
test("unknown ready and uncertain observations never imply that a filesystem write completed",async()=>{
 for(const state of ["notVisible","ready","uncertain"]){const p=await client(r=>r.method==="previewFileOperation"?preview():r.method==="commitFileOperation"?{__error:"budgetExceeded"}:result(state,state==="notVisible"?null:intent(),state==="uncertain"?"staleState":null));
  const controller=O.createController(await O.createClientSource(p.client));await controller.prepare(intent());await assert.rejects(controller.commit());await controller.check();assert.equal(controller.snapshot().phase,"uncertain");controller.dispose();p.client.close();}
});
test("a genuine transport failure closes the client and cannot be repaired by an automatic reconnect",async()=>{
 const p=await client(r=>r.method==="previewFileOperation"?preview():Promise.reject(Error("offline"))),controller=O.createController(await O.createClientSource(p.client));
 await controller.prepare(intent());await assert.rejects(controller.commit(),code("unavailable"));assert.equal(p.client.closed,true);
 const count=p.calls.length;await assert.rejects(controller.check(),code("unavailable"));assert.equal(controller.snapshot().phase,"uncertain");assert.equal(p.calls.length,count);controller.dispose();
});
test("close during a committed operation drops late UI success without pretending to undo it",async()=>{
 const wait=deferred(),p=await client(r=>r.method==="previewFileOperation"?preview():wait.promise),source=await O.createClientSource(p.client),controller=O.createController(source);
 await controller.prepare(intent());const pending=controller.commit();controller.dispose();wait.resolve(result());await pending;
 assert.equal(controller.snapshot().phase,"closed");assert.equal(controller.snapshot().result,null);assert.equal(p.client.closed,false);p.client.close();
});
test("concurrent commit/status operations are serialized and controller blocks a second write",async()=>{
 const wait=deferred(),p=await client(r=>r.method==="previewFileOperation"?preview():wait.promise),controller=O.createController(await O.createClientSource(p.client));
 await controller.prepare(intent());const pending=controller.commit();await assert.rejects(controller.commit(),code("busy"));await assert.rejects(p.client.fileOperationStatus(id(1)),code("busy"));
 wait.resolve(result());await pending;controller.dispose();p.client.close();
});
test("caller mutation after prepare cannot change the captured operation",async()=>{
 const wait=deferred(),request=intent(),p=await client(()=>wait.promise),controller=O.createController(await O.createClientSource(p.client));
 const pending=controller.prepare(request);request.name="different";wait.resolve(preview());await pending;
 assert.equal(controller.snapshot().preview.intent.name,"new");assert.equal(p.calls.at(-1).params.name,"new");controller.dispose();p.client.close();
});
test("source and controller disposal do not close shared providers and ended sessions cannot write",async()=>{
 const {api,session,source,operations,controller}=await fixture();controller.dispose();assert.equal(source.closed,false);
 const p=await operations.preview({libraryID:"shared",kind:"createDirectory",name:"no"});await api.endSession(session);await assert.rejects(operations.commit(p.operationID),code("denied"));source.dispose();assert.equal(operations.closed,true);
});
