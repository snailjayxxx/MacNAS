"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const C=require("../dist/bridge-client.js"),M=require("../dist/model.js"),V=require("../dist/managed-recycle-observation.js");
const scopeID="aaaaaaaa-0000-4000-8000-000000000001",allocationID="bbbbbbbb-0000-4000-8000-000000000002",operationID="cccccccc-0000-4000-8000-000000000003",entryID="dddddddd-0000-4000-8000-000000000004",sourceID="c".repeat(64);
const info=patch=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN","ja-JP"],databaseSchema:6,active:0,completed:0,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[],...patch});
const context=patch=>({contextVersion:1,source:"fixture-host",scopeID,sourceID,userID:"fixture-owner",role:"administrator",mode:"synthetic_development",...patch});
const value=patch=>({managedObservationVersion:1,context:context(),allocation:{allocationID,origin:"upload",intentSHA256:"a".repeat(64),declaredBytes:4,state:"owned",revision:3,sha256:"b".repeat(64)},observation:{observationVersion:1,operationID,visibility:"visible",record:{operationID,entryID,kind:"recycle",phase:"completed",revision:4,entryRevision:4,chargeState:"retained",chargedBytes:4,ownerUserHex:Buffer.from("fixture-owner").toString("hex"),intentSHA256:"d".repeat(64)},classification:"matchedPost"},...patch});
const absent=()=>value({allocation:null,observation:{observationVersion:1,operationID,visibility:"notVisible",record:null,classification:"notVisible"}});
const reply=(r,data)=>({apiVersion:1,requestId:r.requestId,data}),denied=(r,code)=>({apiVersion:1,requestId:r.requestId,error:{code}});
const code=c=>e=>e instanceof M.ServiceError&&e.code===c;
const gate=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function clientFor(handler){return C.createDesktopClient({transport:async r=>reply(r,await handler(r))});}
const dispatch=r=>r.method==="overview"?info():r.method==="managedRecycleObservationContext"?context():value();

test("MOCK provisional adapter handshakes separately and reads only on explicit refresh",async()=>{
  for(const mode of ["synthetic_development","read_only_recovery","rolled_back_recovery"]){
    const requests=[],client=clientFor(r=>{requests.push(r);return r.method==="overview"?info({mode}):r.method==="managedRecycleObservationContext"?context({mode}):value({context:context({mode})});});
    const model=await C.createManagedRecycleObservationModel(client,{operationID});assert.deepEqual(requests.map(r=>r.method),["overview","managedRecycleObservationContext"]);
    await model.refresh();assert.deepEqual(requests[2].params,{scopeID,sourceID,operationID});assert.equal(Object.isFrozen(model.snapshot().envelope.allocation),true);
    model.dispose();assert.equal(client.closed,false);client.close();
  }
});
test("MOCK Schema6 administrator and independent context are required before any observation send",async()=>{
  for(const [patch,error] of [[{databaseSchema:5},"unsupported"],[{databaseSchema:4},"unsupported"],[{role:"reader"},"denied"]]){
    let sends=0;const client=clientFor(()=>{sends++;return info(patch);});await client.overview();await assert.rejects(client.managedRecycleObservationContext(),code(error));await assert.rejects(client.observeManagedRecycleOperation(operationID),code(error));assert.equal(sends,1);client.close();
  }
  let sends=0;const client=clientFor(r=>{sends++;return dispatch(r);});await client.overview();await assert.rejects(client.observeManagedRecycleOperation(operationID),code("denied"));assert.equal(sends,1);client.close();
});
test("MOCK capacity ledger or old observation approval cannot substitute for managed approval",async()=>{
  const methods=[],client=C.createDesktopClient({transport:async r=>{methods.push(r.method);return r.method==="managedRecycleObservationContext"?denied(r,"denied"):reply(r,r.method==="overview"?info():r.method==="capacityLedgerContext"?context({sourceID:"e".repeat(64)}):{});}});
  await client.overview();await client.capacityLedgerContext();await assert.rejects(client.observeManagedRecycleOperation(operationID),code("denied"));await assert.rejects(client.managedRecycleObservationContext(),code("denied"));assert.equal(client.closed,false);
  assert.deepEqual(methods,["overview","capacityLedgerContext","managedRecycleObservationContext"]);client.close();
});
test("MOCK context rejects extras missing values accessors malformed scope and source",async()=>{
  let gets=0;
  for(const change of [v=>({...v,path:"private"}),v=>{delete v.sourceID;return v;},v=>({...v,scopeID:scopeID.toUpperCase()}),v=>({...v,sourceID:"BAD"}),v=>({...v,contextVersion:2}),v=>Object.defineProperty(v,"scopeID",{enumerable:true,get(){gets++;return scopeID;}})]){
    const client=clientFor(r=>r.method==="overview"?info():change(context()));await client.overview();await assert.rejects(client.managedRecycleObservationContext(),code("invalidResponse"));assert.equal(client.closed,true);
  }
  assert.equal(gets,0);
});
test("MOCK raw subject controls and unnormalized equality are independently enforced",async()=>{
  for(const userID of ["owner\n","owner\r","owner\0","\ud800"]){const client=clientFor(r=>r.method==="overview"?info({userID}):context({userID}));
    if(/[\n\r]/.test(userID)){await client.overview();await assert.rejects(client.managedRecycleObservationContext(),code("invalidResponse"));}else await assert.rejects(client.overview(),code("invalidResponse"));assert.equal(client.closed,true);
  }
  for(const patch of [{userID:"é"},{mode:"read_only_recovery"},{role:"reader"}]){const client=clientFor(r=>r.method==="overview"?info({userID:"e\u0301"}):context(patch));await client.overview();await assert.rejects(client.managedRecycleObservationContext(),code("denied"));assert.equal(client.closed,true);}
});
test("MOCK renewed managed source cannot silently replace the pinned source",async()=>{
  let renewed=false;const client=clientFor(r=>r.method==="overview"?info():context({sourceID:renewed?"e".repeat(64):sourceID}));await client.overview();await client.managedRecycleObservationContext();renewed=true;
  await assert.rejects(client.managedRecycleObservationContext(),code("denied"));assert.equal(client.closed,true);
});
test("MOCK operation input and known model identities are strict before handshake",async()=>{
  let sends=0;const client=clientFor(r=>{sends++;return dispatch(r);});
  for(const params of [{operationID:operationID.toUpperCase()},{operationID,extra:true},{operationID,entryID:null},{operationID,allocationID:"/private"},Object.defineProperty({},"operationID",{enumerable:true,get(){throw Error("accessed");}})])await assert.rejects(C.createManagedRecycleObservationModel(client,params),code("invalidInput"));assert.equal(sends,0);
  await client.overview();await client.managedRecycleObservationContext();for(const id of [null,operationID.toUpperCase(),"../x"])await assert.rejects(client.observeManagedRecycleOperation(id),code("invalidInput"));assert.equal(sends,2);client.close();
});
test("MOCK responses cannot substitute source scope operation mode owner or owned charge",async()=>{
  for(const mutate of [v=>v.context.sourceID="e".repeat(64),v=>v.context.scopeID=entryID,v=>v.context.mode="read_only_recovery",v=>v.context.userID="another",v=>v.observation.operationID=entryID,v=>v.observation.record.ownerUserHex="61",v=>v.allocation.declaredBytes=5,v=>v.filesystemVerified=true,v=>delete v.allocation.sha256]){
    const client=clientFor(r=>{if(r.method!=="observeManagedRecycleOperation")return dispatch(r);const v=value();mutate(v);return v;});const model=await C.createManagedRecycleObservationModel(client,{operationID});await assert.rejects(model.refresh(),code("invalidResponse"));assert.equal(client.closed,true);assert.equal(model.snapshot().envelope,null);model.dispose();
  }
});
test("MOCK context and all operation reads share one in-flight slot",async()=>{
  const wait=gate();let delayed=false,sends=0;const client=clientFor(async r=>{sends++;if(delayed)await wait.promise;return dispatch(r);});await client.overview();await client.managedRecycleObservationContext();delayed=true;
  const pending=client.observeManagedRecycleOperation(operationID);await assert.rejects(client.managedRecycleObservationContext(),code("busy"));await assert.rejects(client.observeManagedRecycleOperation(entryID),code("busy"));assert.equal(sends,3);wait.resolve();await pending;client.close();
});
test("MOCK business denial and expiry retain the old envelope stale without retry",async()=>{
  let failure;const methods=[],client=C.createDesktopClient({transport:async r=>{methods.push(r.method);return failure&&r.method==="observeManagedRecycleOperation"?denied(r,failure):reply(r,dispatch(r));}});const model=await C.createManagedRecycleObservationModel(client,{operationID});await model.refresh();const prior=model.snapshot().envelope;
  for(failure of ["denied","expired"]){await assert.rejects(model.refresh(),code(failure));assert.equal(model.snapshot().envelope,prior);assert.equal(model.snapshot().stale,true);assert.equal(client.closed,false);}
  assert.equal(methods.filter(m=>m==="observeManagedRecycleOperation").length,3);model.dispose();client.close();
});
test("MOCK disposing a borrowed model clears current data and ignores late success",async()=>{
  const wait=gate();let delayed=false;const client=clientFor(async r=>{if(delayed)await wait.promise;return dispatch(r);});const model=await C.createManagedRecycleObservationModel(client,{operationID});await model.refresh();delayed=true;const pending=model.refresh();model.dispose();wait.resolve();await pending;
  assert.equal(model.snapshot().phase,"closed");assert.equal(model.snapshot().envelope,null);assert.equal(model.snapshot().error,null);assert.equal(client.closed,false);client.close();
});
test("MOCK disposing a borrowed model ignores late denied replies and sends no follow-up",async()=>{
  const wait=gate();let reads=0;const client=C.createDesktopClient({transport:async r=>r.method==="observeManagedRecycleOperation"?(reads++,await wait.promise,denied(r,"denied")):reply(r,dispatch(r))});const model=await C.createManagedRecycleObservationModel(client,{operationID});const pending=model.refresh();model.dispose();wait.resolve();await pending;
  assert.equal(model.snapshot().phase,"closed");assert.equal(model.snapshot().error,null);assert.equal(reads,1);assert.equal(client.closed,false);client.close();
});
test("MOCK one model captures its borrowed client despite selection changes",async()=>{
  let first=0,second=0;const a=clientFor(r=>{first++;return dispatch(r);}),b=clientFor(r=>{second++;return dispatch(r);});let selected=a;const model=await C.createManagedRecycleObservationModel(selected,{operationID});selected=b;await model.refresh();assert.equal(first,3);assert.equal(second,0);assert.equal(selected,b);model.dispose();a.close();b.close();
});
test("MOCK optional expected entry and allocation reject wrong first response without a new read",async()=>{
  for(const params of [{operationID,entryID:allocationID},{operationID,allocationID:entryID}]){let reads=0;const client=clientFor(r=>{if(r.method==="observeManagedRecycleOperation")reads++;return dispatch(r);});const model=await C.createManagedRecycleObservationModel(client,params);await assert.rejects(model.refresh(),code("invalidResponse"));assert.equal(reads,1);assert.equal(model.snapshot().envelope,null);assert.equal(client.closed,false);model.dispose();client.close();}
});
test("MOCK abort and timeout retain the existing close policy and never retry",async()=>{
  for(const action of ["abort","timeout"]){let reads=0;const client=C.createDesktopClient({timeoutMs:action==="timeout"?10:30000,transport:r=>r.method==="observeManagedRecycleOperation"?(reads++,new Promise(()=>{})):Promise.resolve(reply(r,dispatch(r)))});await client.overview();await client.managedRecycleObservationContext();
    const controller=new AbortController(),pending=client.observeManagedRecycleOperation(operationID,{signal:controller.signal});if(action==="abort")controller.abort();await assert.rejects(pending,code(action==="abort"?"cancelled":"timedOut"));assert.equal(reads,1);assert.equal(client.closed,true);
  }
});
test("MOCK zero and 16MiB owned charges persist after the recycle entry is released",async()=>{
  for(const bytes of [0,16777216]){const raw=value();raw.allocation.declaredBytes=bytes;Object.assign(raw.observation.record,{entryRevision:9,chargeState:"released",chargedBytes:0});const client=clientFor(r=>r.method==="observeManagedRecycleOperation"?raw:dispatch(r));const model=await C.createManagedRecycleObservationModel(client,{operationID,entryID,allocationID});await model.refresh();
    const s=V.summarize(model.snapshot().envelope,{scopeID,sourceID,ownerUserID:"fixture-owner",mode:"synthetic_development",operationID});assert.equal(s.ownedChargedBytes,bytes);assert.equal(s.entryChargedBytes,0);assert.equal(s.capacityReleaseAuthorized,false);assert.equal(s.filesystemVerified,false);model.dispose();client.close();
  }
});
test("MOCK unknown operation stays unknown with null allocation and charge",async()=>{
  const client=clientFor(r=>r.method==="observeManagedRecycleOperation"?absent():dispatch(r)),model=await C.createManagedRecycleObservationModel(client,{operationID});await model.refresh();assert.equal(model.snapshot().envelope.allocation,null);assert.equal(model.snapshot().envelope.observation.record,null);model.dispose();client.close();
});
test("MOCK client exposes no managed approval execution settlement or capacity release method",()=>{
  const client=clientFor(dispatch);for(const key of ["authorizeFixtureManagedRecycleObservation","approveManagedRecycleObservation","settleManagedRecycleOperation","releaseCapacity","restoreManagedFile","recycleManagedFile"])assert.equal(client[key],undefined);client.close();
});
