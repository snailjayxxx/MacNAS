"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),C=require("../dist/bridge-client.js"),R=require("../dist/notification-reconciliation.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const info=(patch={})=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN","ja-JP"],databaseSchema:3,active:0,completed:0,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[],...patch});
const context=(patch={})=>({contextVersion:1,source:"fixture-host",scopeID:"a".repeat(64),userID:"fixture-owner",role:"administrator",mode:"synthetic_development",...patch});
const observation=(id,ack=0,ctx=context(),patch={})=>({observationVersion:1,context:ctx,status:{statusVersion:1,consumerID:id,visibility:"visible",acknowledgedThrough:ack,deliveredThrough:Math.max(2,ack),...patch}});
const event={sequence:1,job_id:"job",revision:1,type:"queued",state:"queued"};
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {resolve,reject,promise};};
function client(handler,overview=info(),config={}){
  const calls=[],value=C.createDesktopClient({transport:async request=>{calls.push(request);return {apiVersion:1,requestId:request.requestId,data:request.method==="overview"?overview:await handler(request)};},...config});
  return {client:value,calls};
}
async function original({events=[event],options={consumerID:"consumer"}}={}){
  const old=client(r=>r.method==="eventConsumerObservation"?observation(r.params.consumerID):r.method==="pollEvents"?events:(()=>{throw Error("response lost after a possible commit");})());
  const view=await R.createClientReconciliationView(old.client,options);await view.poll();await assert.rejects(view.acknowledge(),code("unavailable"));
  return {...old,view};
}
async function candidate(ack=1,ctx=context(),patch={},overview=info()){
  const result=client(r=>observation(r.params.consumerID,ack,ctx,patch),overview);await result.client.overview();return result;
}
test("same-source durable ACK resolves only the explicit check and preserves the old uncertain batch",async()=>{
  const old=await original(),next=await candidate(),before=old.view.snapshot();
  const result=await old.view.reconcile(next.client);
  assert.equal(result.reconciliation.outcome,"acknowledged");assert.equal(result.reconciliation.target,1);
  assert.equal(result.reconciliation.acknowledgedThrough,1);assert.deepEqual(result.items,before.items);
  assert.equal(result.confirmedThrough,0);assert.equal(result.ackRetryRequired,true);assert.equal(result.unavailable,true);
  assert.deepEqual(next.calls.map(x=>x.method),["overview","eventConsumerObservation"]);
  assert.ok(Object.isFrozen(result.reconciliation));old.view.dispose();assert.equal(next.client.closed,false);next.client.close();
});
test("insufficient or invisible persistent positions never resolve the original target",async()=>{
  const old=await original();
  for(const patch of [{},{visibility:"notVisible",acknowledgedThrough:null,deliveredThrough:null}]){
    const next=await candidate(0,context(),patch);const s=await old.view.reconcile(next.client);
    assert.equal(s.reconciliation.outcome,"unresolved");assert.equal(s.items.length,1);assert.equal(s.confirmedThrough,0);next.client.close();
  }
  old.view.dispose();
});
test("different database or instance scopes cannot reconcile even with a higher durable position",async()=>{
  const old=await original(),next=await candidate(100,context({scopeID:"b".repeat(64)}));
  await assert.rejects(old.view.reconcile(next.client),code("denied"));
  assert.equal(old.view.snapshot().reconciliation.outcome,"unresolved");assert.equal(old.view.snapshot().items.length,1);
  assert.equal(next.client.closed,false);old.view.dispose();next.client.close();
});
test("user role and recovery mode differences stay unresolved even if a transport repeats the scope string",async()=>{
  const old=await original();
  for(const patch of [{userID:"fixture-family",role:"reader"},{role:"reader"},{mode:"read_only_recovery"},{mode:"rolled_back_recovery"}]){
    const next=await candidate(100,context(patch),{},info(patch));
    await assert.rejects(old.view.reconcile(next.client),code("denied"));assert.equal(old.view.snapshot().items.length,1);next.client.close();
  }
  old.view.dispose();
});
test("the original high target is retained after a lost ACK and cannot be replaced by a lower candidate ACK",async()=>{
  const old=await original({events:[event,{sequence:2,job_id:"job-2",revision:1,type:"queued",state:"queued"}]}),next=await candidate(1);
  const s=await old.view.reconcile(next.client);assert.equal(s.reconciliation.target,2);assert.equal(s.reconciliation.outcome,"unresolved");
  assert.equal(s.items.length,2);assert.equal(old.calls.find(x=>x.method==="acknowledgeEvents").params.through,2);
  await assert.rejects(old.view.poll(),code("unavailable"));old.view.dispose();next.client.close();
});
test("a candidate must be explicitly provided and initialized, with no connection factory or automatic overview",async()=>{
  const old=await original(),next=client(r=>observation(r.params.consumerID,1));
  await assert.rejects(old.view.reconcile(undefined),code("unavailable"));
  await assert.rejects(old.view.reconcile(old.client),code("unavailable"));
  await assert.rejects(old.view.reconcile(next.client),code("unavailable"));assert.deepEqual(next.calls,[]);
  assert.equal(old.view.snapshot().items.length,1);old.view.dispose();next.client.close();
});
test("failed queries preserve a fixed error and never retry or close a borrowed candidate themselves",async()=>{
  const old=await original();let calls=0;
  const next=C.createDesktopClient({transport:async r=>{calls++;return r.method==="overview"?{apiVersion:1,requestId:r.requestId,data:info()}:{apiVersion:1,requestId:r.requestId,error:{code:"database"}};}});
  await next.overview();await assert.rejects(old.view.reconcile(next),code("database"));
  assert.equal(calls,2);assert.equal(next.closed,false);assert.equal(old.view.snapshot().reconciliation.error,"database");
  assert.equal(old.view.snapshot().confirmedThrough,0);old.view.dispose();next.close();
});
test("dispose while checking drops late success without closing the candidate",async()=>{
  const old=await original(),wait=deferred(),next=client(()=>wait.promise);await next.client.overview();
  const pending=old.view.reconcile(next.client);old.view.dispose();wait.resolve(observation("consumer",1));
  const s=await pending;assert.equal(s.phase,"closed");assert.equal(s.reconciliation.phase,"closed");assert.equal(s.reconciliation.outcome,"unresolved");assert.deepEqual(s.items,[]);
  assert.equal(next.client.closed,false);next.client.close();
});
test("a pending check excludes poll ACK and another check while the candidate consumer is serialized",async()=>{
  const old=await original(),wait=deferred(),next=client(()=>wait.promise);await next.client.overview();
  const pending=old.view.reconcile(next.client);
  await assert.rejects(old.view.reconcile(next.client),code("busy"));await assert.rejects(old.view.poll(),code("busy"));await assert.rejects(old.view.acknowledge(),code("busy"));
  await assert.rejects(next.client.eventConsumerStatus("consumer"),code("busy"));
  wait.resolve(observation("consumer",1));await pending;old.view.dispose();next.client.close();
});
test("candidate close or timeout leaves the original batch unresolved and ignores late results",async()=>{
  const old=await original(),wait=deferred(),next=client(()=>wait.promise);await next.client.overview();
  const pending=old.view.reconcile(next.client),rejected=assert.rejects(pending,code("cancelled"));next.client.close();await rejected;
  wait.resolve(observation("consumer",1));await Promise.resolve();assert.equal(old.view.snapshot().reconciliation.outcome,"unresolved");
  const timed=client(()=>new Promise(()=>{}),info(),{timeoutMs:10});await timed.client.overview();await assert.rejects(old.view.reconcile(timed.client),code("timedOut"));
  assert.equal(old.view.snapshot().items.length,1);assert.equal(timed.calls.length,2);old.view.dispose();
});
test("successful direct ACK needs no reconciliation and preserves existing view semantics",async()=>{
  const provider=client(r=>r.method==="eventConsumerObservation"?observation(r.params.consumerID):r.method==="pollEvents"?[event]:true);
  const view=await R.createClientReconciliationView(provider.client,{consumerID:"consumer"});await view.poll();await view.acknowledge();
  assert.equal(view.snapshot().confirmedThrough,1);assert.deepEqual(view.snapshot().items,[]);
  const next=await candidate();await assert.rejects(view.reconcile(next.client),code("staleState"));view.dispose();assert.equal(provider.client.closed,false);provider.client.close();next.client.close();
});
test("creation captures consumer options before an await so callers cannot redirect the old batch",async()=>{
  const options={consumerID:"consumer",capacity:1},provider=client(r=>r.method==="eventConsumerObservation"?observation(r.params.consumerID):r.method==="pollEvents"?[event]:(()=>{throw Error("lost");})());
  const creating=R.createClientReconciliationView(provider.client,options);options.consumerID="foreign";options.capacity=100;
  const view=await creating;assert.equal(view.snapshot().capacity,1);await view.poll();await assert.rejects(view.acknowledge(),code("unavailable"));
  const next=await candidate();await view.reconcile(next.client);assert.equal(next.calls.at(-1).params.consumerID,"consumer");
  assert.ok(provider.calls.filter(r=>r.params.consumerID).every(r=>r.params.consumerID==="consumer"));view.dispose();next.client.close();
});
test("accessor and extra options are rejected before any provider request",async()=>{
  const provider=client(()=>true);let getterCalled=false;
  for(const options of [{get consumerID(){getterCalled=true;return "consumer";}},{consumerID:"consumer",sourceID:"chosen"},Object.assign({consumerID:"consumer"},{[Symbol()]:true}),null]){
    await assert.rejects(R.createClientReconciliationView(provider.client,options),code("invalidInput"));
  }
  assert.equal(getterCalled,false);assert.deepEqual(provider.calls,[]);provider.client.close();
});
test("the observation wire validates exact nested fields versions scopes and safe status integers",async()=>{
  const alterations=[v=>({...v,observationVersion:2}),v=>({...v,extra:true}),v=>({...v,context:{...v.context,scopeID:"x"}}),
    v=>({...v,context:{...v.context,contextVersion:2}}),v=>({...v,context:{...v.context,database:"private"}}),
    v=>({...v,status:{...v.status,consumerID:"foreign"}}),v=>({...v,status:{...v.status,acknowledgedThrough:3,deliveredThrough:2}}),
    v=>({...v,status:{...v.status,deliveredThrough:Number.MAX_SAFE_INTEGER+1}}),v=>({...v,status:{...v.status,visibility:"notVisible"}})];
  for(const alter of alterations){
    const next=client(r=>alter(observation(r.params.consumerID)));await next.client.overview();
    await assert.rejects(next.client.eventConsumerObservation("consumer"),code("invalidResponse"));assert.equal(next.client.closed,true);
  }
});
test("a named client pins its observed source and rejects a later scope change",async()=>{
  let scope="a".repeat(64);const next=client(r=>observation(r.params.consumerID,0,context({scopeID:scope})));await next.client.overview();
  const first=await next.client.eventConsumerObservation("consumer");assert.ok(Object.isFrozen(first.context));scope="b".repeat(64);
  await assert.rejects(next.client.eventConsumerObservation("consumer"),code("denied"));assert.equal(next.client.closed,true);
});
test("observation does not allocate delivery consumers or grant ACK authority and uses strict IDs",async()=>{
  const next=await candidate(50);
  for(let i=0;i<40;i++)await next.client.eventConsumerObservation("read-"+i);
  await assert.rejects(next.client.acknowledgeEvents("read-0",50),code("denied"));
  const before=next.calls.length;
  for(const id of ["","line\nend","line\rend","nul\0id","中".repeat(43),"\uD800"])await assert.rejects(next.client.eventConsumerObservation(id),code("invalidInput"));
  assert.equal(next.calls.length,before);next.client.close();
});
