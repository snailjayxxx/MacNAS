"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const C=require("../dist/bridge-client.js"),M=require("../dist/model.js");
const scopeID="aaaaaaaa-0000-4000-8000-000000000001",sourceID="a".repeat(64);
const info=patch=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN"],databaseSchema:6,active:0,completed:0,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[],...patch});
const context=patch=>({contextVersion:1,source:"fixture-host",scopeID,sourceID,userID:"fixture-owner",role:"administrator",mode:"synthetic_development",...patch});
const list=patch=>({listVersion:1,scopeID,ownerUserHex:Buffer.from("fixture-owner").toString("hex"),sourceID,evidence:"ledgerOnly",limitBytes:67108864,items:[],totals:{reservedBytes:0,unresolvedBytes:0,ownedBytes:0,allocatedBytes:0,historyCount:0,unresolvedCount:0},...patch});
const reply=(r,data)=>({apiVersion:1,requestId:r.requestId,data});
const code=c=>e=>e instanceof M.ServiceError&&e.code===c;
const gate=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function clientFor(handler){return C.createDesktopClient({transport:async r=>reply(r,await handler(r))});}

test("adapter handshakes an approved context then explicitly refreshes a complete immutable list",async()=>{
  const requests=[],client=clientFor(r=>{requests.push(r);return r.method==="overview"?info({mode:"read_only_recovery"}):r.method==="capacityLedgerContext"?context({mode:"read_only_recovery"}):list();});
  const model=await C.createCapacityLedgerModel(client);assert.deepEqual(requests.map(r=>r.method),["overview","capacityLedgerContext"]);
  await model.refresh();assert.deepEqual(requests[2].params,{scopeID,sourceID});assert.equal(model.snapshot().list.items.length,0);assert.equal(Object.isFrozen(model.snapshot().list.totals),true);
  for(const name of ["authorizeFixtureCapacityLedgerRead","receiveCapacityFile","cancelCapacityAllocation","settleRecycleOperation"])assert.equal(client[name],undefined);
  model.dispose();assert.equal(client.closed,false);client.close();
});
test("list needs an initialized Schema6 administrator and context before transport",async()=>{
  for(const [patch,error]of [[{databaseSchema:5},"unsupported"],[{role:"reader"},"denied"]]){
    let sends=0;const client=clientFor(()=>{sends++;return info(patch);});await client.overview();await assert.rejects(client.capacityLedgerContext(),code(error));assert.equal(sends,1);client.close();
  }
  let sends=0;const client=clientFor(r=>{sends++;return r.method==="overview"?info():context();});await client.overview();
  await assert.rejects(client.listCapacityLedger(scopeID),code("denied"));await client.capacityLedgerContext();
  for(const id of [scopeID.toUpperCase(),"/root",null])await assert.rejects(client.listCapacityLedger(id),code("invalidInput"));
  await assert.rejects(client.listCapacityLedger("bbbbbbbb-0000-4000-8000-000000000002"),code("denied"));assert.equal(sends,2);client.close();
});
test("source renewal in the same scope cannot replace a pinned context",async()=>{
  let renewed=false;const client=clientFor(r=>r.method==="overview"?info():context({sourceID:renewed?"b".repeat(64):sourceID}));await client.overview();await client.capacityLedgerContext();renewed=true;
  await assert.rejects(client.capacityLedgerContext(),code("denied"));assert.equal(client.closed,true);
});
test("context rejects extra fields, accessors, malformed markers and mismatched raw subjects",async()=>{
  for(const transform of [v=>({...v,path:"private"}),v=>({...v,sourceID:"x"}),v=>({...v,userID:"other"}),v=>({...v,mode:"read_only_recovery"}),v=>Object.defineProperty(v,"scopeID",{enumerable:true,get(){throw Error("getter");}})]){
    const client=clientFor(r=>r.method==="overview"?info():transform(context()));await client.overview();await assert.rejects(client.capacityLedgerContext(),e=>["denied","invalidResponse"].includes(e.code));assert.equal(client.closed,true);
  }
});
test("lists reject wrong source or scope, filesystem claims, partial totals and omitted nulls",async()=>{
  for(const transform of [v=>({...v,sourceID:"b".repeat(64)}),v=>({...v,scopeID:"bbbbbbbb-0000-4000-8000-000000000002"}),v=>({...v,filesystemVerified:true}),v=>({...v,totals:{...v.totals,historyCount:1}}),v=>({...v,items:[{allocationID:scopeID,origin:"upload",intentSHA256:sourceID,declaredBytes:0,state:"reserved",revision:1}]})]){
    const client=clientFor(r=>r.method==="overview"?info():r.method==="capacityLedgerContext"?context():transform(list()));const model=await C.createCapacityLedgerModel(client);
    await assert.rejects(model.refresh(),code("invalidResponse"));assert.equal(client.closed,true);model.dispose();
  }
});
test("context and list share a one-read in-flight budget",async()=>{
  const delayed=gate();let wait=false,sends=0;const client=clientFor(async r=>{sends++;if(r.method==="overview")return info();if(wait)await delayed.promise;return r.method==="capacityLedgerContext"?context():list();});await client.overview();await client.capacityLedgerContext();wait=true;
  const pending=client.listCapacityLedger(scopeID);await assert.rejects(client.listCapacityLedger(scopeID),code("busy"));await assert.rejects(client.capacityLedgerContext(),code("busy"));assert.equal(sends,3);delayed.resolve();await pending;client.close();
});
test("denied or expired host reads keep the previous list stale without retry or reconnect",async()=>{
  let error;const requests=[];const client=C.createDesktopClient({transport:async r=>{requests.push(r.method);return error&&r.method==="listCapacityLedger"?{apiVersion:1,requestId:r.requestId,error:{code:error}}:reply(r,r.method==="overview"?info():r.method==="capacityLedgerContext"?context():list());}});
  const model=await C.createCapacityLedgerModel(client);await model.refresh();const prior=model.snapshot().list;
  for(error of ["denied","expired"]){await assert.rejects(model.refresh(),code(error));assert.equal(model.snapshot().list,prior);assert.equal(model.snapshot().stale,true);assert.equal(client.closed,false);}
  assert.equal(requests.filter(m=>m==="listCapacityLedger").length,3);model.dispose();client.close();
});
test("dispose ignores a late success and retains the borrowed connection",async()=>{
  const delayed=gate();const client=clientFor(async r=>r.method==="overview"?info():r.method==="capacityLedgerContext"?context():(await delayed.promise,list()));const model=await C.createCapacityLedgerModel(client),pending=model.refresh();model.dispose();delayed.resolve();await pending;
  assert.equal(model.snapshot().phase,"closed");assert.equal(model.snapshot().list,null);assert.equal(client.closed,false);client.close();
});
test("dispose ignores a late failure and never sends a new request",async()=>{
  const delayed=gate();let reads=0;const client=C.createDesktopClient({transport:async r=>r.method==="overview"?reply(r,info()):r.method==="capacityLedgerContext"?reply(r,context()):(reads++,await delayed.promise,{apiVersion:1,requestId:r.requestId,error:{code:"denied"}})});const model=await C.createCapacityLedgerModel(client),pending=model.refresh();model.dispose();delayed.resolve();await pending;
  assert.equal(model.snapshot().phase,"closed");assert.equal(model.snapshot().error,null);assert.equal(reads,1);assert.equal(client.closed,false);client.close();
});
test("a captured adapter never follows an external client selection change",async()=>{
  let firstReads=0,secondReads=0;const first=clientFor(r=>r.method==="overview"?info():r.method==="capacityLedgerContext"?context():(firstReads++,list()));
  const second=clientFor(r=>{secondReads++;return info();});let selected=first;const model=await C.createCapacityLedgerModel(selected);selected=second;await model.refresh();assert.equal(firstReads,1);assert.equal(secondReads,0);assert.equal(selected,second);model.dispose();first.close();second.close();
});
test("abort and timeout keep the existing close policy without retry or approval",async()=>{
  for(const action of ["abort","timeout"]){let reads=0;const client=C.createDesktopClient({timeoutMs:action==="timeout"?10:30000,transport:r=>r.method==="overview"?Promise.resolve(reply(r,info())):r.method==="capacityLedgerContext"?Promise.resolve(reply(r,context())):(reads++,new Promise(()=>{}))});await client.overview();await client.capacityLedgerContext();
    const controller=new AbortController(),pending=client.listCapacityLedger(scopeID,{signal:controller.signal});if(action==="abort")controller.abort();await assert.rejects(pending,code(action==="abort"?"cancelled":"timedOut"));assert.equal(reads,1);assert.equal(client.closed,true);
  }
});

test("capacity context enforces raw subject controls independently of generic overview",async()=>{
  for(const userID of ["owner\n","owner\r"]){
    const client=clientFor(r=>r.method==="overview"?info({userID}):context({userID}));await client.overview();
    await assert.rejects(client.capacityLedgerContext(),code("invalidResponse"));assert.equal(client.closed,true);
  }
  const client=clientFor(r=>r.method==="overview"?info({userID:"e\u0301"}):context({userID:"é"}));await client.overview();
  await assert.rejects(client.capacityLedgerContext(),code("denied"));assert.equal(client.closed,true);
});
