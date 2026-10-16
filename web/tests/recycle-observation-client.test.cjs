"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),C=require("../dist/bridge-client.js"),R=require("../dist/recycle-observation.js");
const operationID="aaaaaaaa-0000-4000-8000-000000000001",entryID="bbbbbbbb-0000-4000-8000-000000000002";
const info=patch=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN"],databaseSchema:4,active:0,completed:0,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[],...patch});
const absent=id=>({observationVersion:1,operationID:id,visibility:"notVisible",record:null,classification:"notVisible"});
const visible=patch=>({observationVersion:1,operationID,visibility:"visible",record:{operationID,entryID,kind:"recycle",phase:"completed",revision:4,entryRevision:4,chargeState:"retained",chargedBytes:4,ownerUserHex:Buffer.from("fixture-owner").toString("hex"),intentSHA256:"a".repeat(64),...patch},classification:"matchedPost"});
const context=patch=>({contextVersion:1,source:"fixture-host",scopeID:"c".repeat(64),userID:"fixture-owner",role:"administrator",mode:"synthetic_development",...patch});
const reply=(request,data,ctx=context())=>({apiVersion:1,requestId:request.requestId,data:request.method==="observeRecycleOperation"?{observationEnvelopeVersion:1,context:ctx,observation:data}:data});
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const gate=()=>{let resolve;const promise=new Promise(a=>{resolve=a;});return{promise,resolve};};

test("Schema4 read-only host provides only a typed observation, without approval/write ownership",async()=>{
  const requests=[];const client=C.createDesktopClient({transport:async request=>{requests.push(request);return reply(request,request.method==="overview"?info({mode:"read_only_recovery"}):visible(),context({mode:"read_only_recovery"}));}});
  await client.overview();const result=await client.observeRecycleOperation(operationID);assert.equal(result.classification,"matchedPost");assert.equal(Object.isFrozen(result.record),true);
  assert.deepEqual(requests[1].params,{operationID});assert.equal(requests[1].method,"observeRecycleOperation");
  assert.equal(client.authorizeFixtureRecycleObservation,undefined);assert.equal(client.settleRecycleOperation,undefined);assert.equal(client.restoreRecycleEntry,undefined);client.close();
});
test("Schema3, reader and malformed IDs fail before a read request",async()=>{
  for(const [patch,error]of [[{databaseSchema:3},"unsupported"],[{role:"reader"},"denied"]]){
    let sends=0;const client=C.createDesktopClient({transport:async request=>{sends++;return reply(request,info(patch));}});await client.overview();await assert.rejects(client.observeRecycleOperation(operationID),code(error));assert.equal(sends,1);client.close();
  }
  let sends=0;const client=C.createDesktopClient({transport:async request=>{sends++;return reply(request,info());}});await client.overview();
  for(const id of [operationID.toUpperCase(),"/absolute/path",null,{operationID}])await assert.rejects(client.observeRecycleOperation(id),code("invalidInput"));assert.equal(sends,1);client.close();
});
test("unknown records remain null without creating ownership or suggesting released bytes",async()=>{
  const client=C.createDesktopClient({transport:async request=>reply(request,request.method==="overview"?info():absent(request.params.operationID))});await client.overview();
  const result=await client.observeRecycleOperation(operationID),summary=R.summary(result,{operationID,ownerUserID:"fixture-owner"});
  assert.equal(summary.chargedBytes,null);assert.equal(summary.journalCompleted,false);assert.equal(summary.requiresReview,true);assert.equal(client.cancelRecycleOperation,undefined);client.close();
});
test("foreign IDs, subjects and filesystem evidence cannot enter a typed response",async()=>{
  for(const transform of [value=>({...value,operationID:entryID}),value=>({...value,record:{...value.record,ownerUserHex:"00"}}),value=>({...value,postEvidence:{inode:"1"}}),value=>({...value,record:{...value.record,path:"/vault/payload"}})]){
    const client=C.createDesktopClient({transport:async request=>reply(request,request.method==="overview"?info():transform(visible()))});await client.overview();await assert.rejects(client.observeRecycleOperation(operationID),code("invalidResponse"));assert.equal(client.closed,true);
  }
});
test("same-ID reads serialize locally and at most eight distinct reads remain active",async()=>{
  const waiting=[];const client=C.createDesktopClient({transport:request=>request.method==="overview"?Promise.resolve(reply(request,info())):new Promise(resolve=>waiting.push({request,resolve}))});await client.overview();
  const ids=Array.from({length:9},(_,i)=>"00000000-0000-4000-8000-"+(i+1).toString(16).padStart(12,"0"));
  const pending=ids.slice(0,8).map(id=>client.observeRecycleOperation(id));await assert.rejects(client.observeRecycleOperation(ids[0]),code("busy"));await assert.rejects(client.observeRecycleOperation(ids[8]),code("budgetExceeded"));assert.equal(waiting.length,8);
  waiting[0].resolve(reply(waiting[0].request,absent(ids[0])));await pending[0];const ninth=client.observeRecycleOperation(ids[8]);assert.equal(waiting.length,9);
  const settled=Promise.allSettled([...pending,ninth]);client.close();await settled;
});
test("explicit read abort follows the existing connection-close policy without retrying",async()=>{
  const delayed=gate();let sends=0;const client=C.createDesktopClient({transport:request=>request.method==="overview"?Promise.resolve(reply(request,info())):(sends++,delayed.promise.then(()=>reply(request,absent(request.params.operationID))))});await client.overview();
  const controller=new AbortController(),pending=client.observeRecycleOperation(operationID,{signal:controller.signal});controller.abort();await assert.rejects(pending,code("cancelled"));assert.equal(client.closed,true);
  await assert.rejects(client.observeRecycleOperation(operationID),code("unavailable"));delayed.resolve();assert.equal(sends,1);client.close();
});
test("read timeout uses the existing connection policy and never retries or approves",async()=>{
  let sends=0,closes=0;const client=C.createDesktopClient({timeoutMs:10,closeTransport:()=>{closes++;},transport:request=>request.method==="overview"?Promise.resolve(reply(request,info())):(sends++,new Promise(()=>{}))});await client.overview();
  await assert.rejects(client.observeRecycleOperation(operationID),code("timedOut"));assert.equal(client.closed,true);assert.equal(sends,1);assert.equal(closes,1);
  await assert.rejects(client.observeRecycleOperation(operationID),code("unavailable"));assert.equal(sends,1);
});
test("read-only view disposal does not close or cancel a shared client and ignores a late observation",async()=>{
  const delayed=gate();let sends=0;const client=C.createDesktopClient({transport:request=>request.method==="overview"?Promise.resolve(reply(request,info())):(sends++,delayed.promise.then(()=>reply(request,visible())))});await client.overview();
  const model=await C.createRecycleObservationModel(client,{operationID,entryID});const pending=model.refresh();model.dispose();assert.equal(client.closed,false);delayed.resolve();await pending;
  assert.equal(model.snapshot().phase,"closed");assert.equal(model.snapshot().observation,null);assert.equal(sends,1);assert.equal(client.closed,false);client.close();
});

test("a replaced source on the same-looking transport cannot overwrite an old view",async()=>{
  let tag="c".repeat(64);const client=C.createDesktopClient({transport:async request=>reply(request,request.method==="overview"?info():visible(),context({scopeID:tag}))});await client.overview();
  const model=R.createReadOnlyModel({operationID,entryID,ownerUserID:"fixture-owner",read:id=>client.observeRecycleOperation(id)});await model.refresh();const prior=model.snapshot().observation;
  tag="d".repeat(64);await assert.rejects(model.refresh(),code("denied"));assert.equal(model.snapshot().observation,prior);assert.equal(model.snapshot().stale,true);assert.equal(client.closed,true);
});

test("observation source envelope rejects unknown fields, bad tags and caller-context mismatch",async()=>{
  for(const transform of [v=>({...v,observationEnvelopeVersion:2}),v=>({...v,extra:true}),v=>({...v,context:{...v.context,databaseName:"private"}}),v=>({...v,context:{...v.context,scopeID:"c".repeat(63)}}),v=>({...v,context:{...v.context,userID:"other"}}),v=>({...v,context:{...v.context,mode:"read_only_recovery"}})]){
    const client=C.createDesktopClient({transport:async request=>request.method==="overview"?reply(request,info()):{apiVersion:1,requestId:request.requestId,data:transform({observationEnvelopeVersion:1,context:context(),observation:visible()})}});await client.overview();
    await assert.rejects(client.observeRecycleOperation(operationID),error=>["invalidResponse","denied"].includes(error.code));assert.equal(client.closed,true);
  }
});

test("named model adapter reads metadata first and requires an explicit refresh for file observation",async()=>{
  const methods=[];const client=C.createDesktopClient({transport:async request=>{methods.push(request.method);return reply(request,request.method==="overview"?info():visible());}});
  const model=await C.createRecycleObservationModel(client,{operationID,entryID});assert.deepEqual(methods,["overview"]);await model.refresh();assert.deepEqual(methods,["overview","observeRecycleOperation"]);model.dispose();assert.equal(client.closed,false);client.close();
  for(const patch of [{databaseSchema:3},{role:"reader"}]){const other=C.createDesktopClient({transport:async request=>reply(request,info(patch))});await assert.rejects(C.createRecycleObservationModel(other,{operationID}),error=>["unsupported","denied"].includes(error.code));other.close();}
});
test("named model adapter captures one borrowed client across external selection changes",async()=>{
  let firstReads=0,secondReads=0;const first=C.createDesktopClient({transport:async request=>{if(request.method!=="overview")firstReads++;return reply(request,request.method==="overview"?info():visible());}});
  const second=C.createDesktopClient({transport:async request=>{if(request.method!=="overview")secondReads++;return reply(request,request.method==="overview"?info():visible(),context({scopeID:"d".repeat(64)}));}});
  let selected=first;const model=await C.createRecycleObservationModel(selected,{operationID,entryID});selected=second;await model.refresh();assert.equal(firstReads,1);assert.equal(secondReads,0);assert.equal(selected,second);model.dispose();first.close();second.close();
});
