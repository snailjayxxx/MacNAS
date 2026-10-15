"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),C=require("../dist/bridge-client.js"),N=require("../dist/notification-view.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const info=(mode="synthetic_development")=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode,languages:["zh-CN","ja-JP"],databaseSchema:3,active:0,completed:0,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[]});
const status=(consumerID,patch={})=>({statusVersion:1,consumerID,visibility:"visible",acknowledgedThrough:0,deliveredThrough:1,...patch});
const event={sequence:1,job_id:"job",revision:1,type:"queued",state:"queued"};
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {resolve,reject,promise};};
async function opened(handler,config={},mode){
  const calls=[],client=C.createDesktopClient({transport:async request=>{
    calls.push(request);return {apiVersion:1,requestId:request.requestId,data:request.method==="overview"?info(mode):await handler(request)};
  },...config});await client.overview();return {client,calls};
}
test("fixture status is read-only, missing and foreign rows stay indistinguishable and queries do not create IDs",async()=>{
  const api=M.createFixtureAdapter(),owner=await api.beginFixtureSession(),reader=await api.beginFixtureSession("reader");
  const missing=await api.eventConsumerStatus("private",owner);assert.equal(missing.visibility,"notVisible");assert.equal(missing.acknowledgedThrough,null);
  await api.pollEvents("private",reader);assert.deepEqual(await api.eventConsumerStatus("private",owner),missing);
  await api.eventConsumerStatus("unclaimed",owner);assert.deepEqual(await api.pollEvents("unclaimed",reader),[{sequence:2,job_id:"family-job",revision:2,type:"deferred",state:"waiting_for_volume"}]);
  assert.ok(Object.isFrozen(missing));assert.equal((await api.eventConsumerStatus("private",reader)).visibility,"visible");
});
test("fixture reports delivered and acknowledged positions separately, including read-only recovery",async()=>{
  const api=M.createFixtureAdapter(),owner=await api.beginFixtureSession(),recovery=await api.beginFixtureSession("recovery");
  const first=await api.pollEvents("consumer",owner,1);let s=await api.eventConsumerStatus("consumer",owner);
  assert.equal(s.acknowledgedThrough,0);assert.equal(s.deliveredThrough,first[0].sequence);
  await api.acknowledgeEvents("consumer",first[0].sequence,owner);
  const next=await api.pollEvents("consumer",owner,1);s=await api.eventConsumerStatus("consumer",recovery);
  assert.equal(s.acknowledgedThrough,first[0].sequence);assert.equal(s.deliveredThrough,next[0].sequence);
  await assert.rejects(api.pollEvents("consumer",recovery),code("readOnly"));
  await assert.rejects(api.acknowledgeEvents("consumer",next[0].sequence,recovery),code("readOnly"));
});
test("fixture status requires a registered session and strict raw UTF-8 IDs",async()=>{
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession();
  for(const value of [null,{},"","x".repeat(129),"中".repeat(43),"\uD800","x\0y","x\ny","x\ry"])await assert.rejects(api.eventConsumerStatus(value,session),code("invalidInput"));
  const id="o'hara🐚";assert.equal((await api.eventConsumerStatus(id,session)).consumerID,id);
  assert.equal((await api.eventConsumerStatus("中".repeat(42),session)).visibility,"notVisible");
  await assert.rejects(api.eventConsumerStatus(id,{...session}),code("denied"));await api.endSession(session);
  await assert.rejects(api.eventConsumerStatus(id,session),code("denied"));
});
test("named status requires the existing host overview and allows read-only queries without a poll",async()=>{
  const client=C.createDesktopClient({transport:async()=>{throw Error("must not run");}});
  await assert.rejects(client.eventConsumerStatus("consumer"),code("unavailable"));client.close();
  for(const mode of ["read_only_recovery","rolled_back_recovery"]){
    const {client,calls}=await opened(r=>status(r.params.consumerID,{acknowledgedThrough:4,deliveredThrough:8}),{},mode);
    const s=await client.eventConsumerStatus("consumer");assert.equal(s.acknowledgedThrough,4);assert.ok(Object.isFrozen(s));
    assert.equal(calls.at(-1).method,"eventConsumerStatus");assert.deepEqual(calls.at(-1).params,{consumerID:"consumer"});
    await assert.rejects(client.pollEvents("consumer"),code("readOnly"));client.close();
  }
});
test("named status validates exact fields, version, ID, visibility, nullability and safe ordered integers",async()=>{
  for(const alter of [
    s=>({...s,statusVersion:2}),s=>({...s,consumerID:"other"}),s=>({...s,visibility:"missing"}),s=>({...s,databaseName:"private"}),
    s=>({...s,acknowledgedThrough:null}),s=>({...s,deliveredThrough:null}),s=>({...s,acknowledgedThrough:-1}),s=>({...s,acknowledgedThrough:true}),
    s=>({...s,acknowledgedThrough:2,deliveredThrough:1}),s=>({...s,deliveredThrough:Number.MAX_SAFE_INTEGER+1}),
    s=>({...s,visibility:"notVisible",acknowledgedThrough:0,deliveredThrough:0}),
    s=>{const v={...s};delete v.deliveredThrough;return v;}
  ]){
    const {client}=await opened(r=>alter(status(r.params.consumerID)));await assert.rejects(client.eventConsumerStatus("consumer"),code("invalidResponse"));assert.equal(client.closed,true);
  }
  const {client}=await opened(r=>status(r.params.consumerID,{acknowledgedThrough:Number.MAX_SAFE_INTEGER,deliveredThrough:Number.MAX_SAFE_INTEGER}));
  assert.equal((await client.eventConsumerStatus("consumer")).deliveredThrough,Number.MAX_SAFE_INTEGER);client.close();
});
test("named notVisible status preserves explicit null and ordinary consumer IDs",async()=>{
  const id="jobHash <b>🐚</b>",{client}=await opened(r=>status(r.params.consumerID,{visibility:"notVisible",acknowledgedThrough:null,deliveredThrough:null}));
  assert.deepEqual(await client.eventConsumerStatus(id),{statusVersion:1,consumerID:id,visibility:"notVisible",acknowledgedThrough:null,deliveredThrough:null});client.close();
});
test("invalid IDs and options are refused without transport or lingering per-consumer locks",async()=>{
  const {client,calls}=await opened(r=>status(r.params.consumerID));let accessed=false;
  for(const id of [undefined,null,{},"","中".repeat(43),"x\0y","x\ny","x\ry","\uD800"])await assert.rejects(client.eventConsumerStatus(id),code("invalidInput"));
  await assert.rejects(client.eventConsumerStatus("consumer",{get signal(){accessed=true;}}),code("invalidInput"));
  assert.equal(accessed,false);assert.equal(calls.length,1);assert.equal((await client.eventConsumerStatus("consumer")).visibility,"visible");client.close();
});
test("status queries do not allocate delivery consumers or grant acknowledgement authority",async()=>{
  const {client,calls}=await opened(r=>r.method==="eventConsumerStatus"?status(r.params.consumerID,{acknowledgedThrough:50,deliveredThrough:100}):r.method==="pollEvents"?[event]:true);
  for(let i=0;i<40;i++)await client.eventConsumerStatus("observed-"+i);
  await assert.rejects(client.acknowledgeEvents("observed-0",50),code("denied"));
  await client.pollEvents("consumer");await client.eventConsumerStatus("consumer");const count=calls.length;
  await assert.rejects(client.acknowledgeEvents("consumer",100),code("denied"));assert.equal(calls.length,count);
  assert.equal(await client.acknowledgeEvents("consumer",1),true);client.close();
});
test("observation leaves an existing notification batch unresolved until its own successful ACK",async()=>{
  const {client}=await opened(r=>r.method==="pollEvents"?[event]:r.method==="eventConsumerStatus"?status(r.params.consumerID,{acknowledgedThrough:1}):true);
  const view=await N.createClientNotificationView(client,{consumerID:"consumer"}),batch=await view.poll();
  await client.eventConsumerStatus("consumer");assert.deepEqual(view.snapshot().items,batch.items);assert.equal(view.snapshot().confirmedThrough,0);
  await view.acknowledge();assert.equal(view.snapshot().confirmedThrough,1);view.dispose();client.close();
});
test("queries serialize with same-client poll and ACK without blocking a different consumer",async()=>{
  const wait=deferred();let delayed=true;
  const {client}=await opened(r=>r.method==="pollEvents"?[event]:r.method==="eventConsumerStatus"&&r.params.consumerID==="consumer"&&delayed?wait.promise:status(r.params.consumerID));
  await client.pollEvents("consumer");const pending=client.eventConsumerStatus("consumer");
  await assert.rejects(client.eventConsumerStatus("consumer"),code("busy"));await assert.rejects(client.pollEvents("consumer"),code("busy"));await assert.rejects(client.acknowledgeEvents("consumer",1),code("busy"));
  assert.equal((await client.eventConsumerStatus("other")).visibility,"visible");delayed=false;wait.resolve(status("consumer"));await pending;
  assert.equal((await client.pollEvents("consumer")).length,1);client.close();
});
test("a status read during an existing poll is refused and transport business errors release the lock",async()=>{
  const wait=deferred();let failing=true;
  const {client}=await opened(r=>r.method==="pollEvents"?wait.promise:(()=>{if(failing)throw Error("not raw diagnostic");return status(r.params.consumerID);})());
  const pending=client.pollEvents("consumer");await assert.rejects(client.eventConsumerStatus("consumer"),code("busy"));wait.resolve([event]);await pending;
  // A fixed business error is retryable on the same client; an arbitrary transport error is unavailable and closes it.
  await assert.rejects(client.eventConsumerStatus("consumer"),code("unavailable"));assert.equal(client.closed,true);
  let count=0;const good=C.createDesktopClient({transport:async r=>r.method==="overview"?{apiVersion:1,requestId:r.requestId,data:info()}:++count===1?{apiVersion:1,requestId:r.requestId,error:{code:"database"}}:{apiVersion:1,requestId:r.requestId,data:status(r.params.consumerID)}});
  await good.overview();await assert.rejects(good.eventConsumerStatus("consumer"),code("database"));assert.equal(good.closed,false);assert.equal((await good.eventConsumerStatus("consumer")).visibility,"visible");good.close();
});
test("status observes existing pending-call limits and drops values arriving after close or timeout",async()=>{
  const wait=deferred(),{client}=await opened(()=>wait.promise,{maximumPending:1});
  const first=client.eventConsumerStatus("consumer"),rejected=assert.rejects(first,code("cancelled"));
  await assert.rejects(client.eventConsumerStatus("other"),code("busy"));client.close();await rejected;wait.resolve(status("consumer"));await Promise.resolve();
  await assert.rejects(client.eventConsumerStatus("consumer"),code("unavailable"));
  const timed=await opened(()=>new Promise(()=>{}),{timeoutMs:20});await assert.rejects(timed.client.eventConsumerStatus("consumer"),code("timedOut"));assert.equal(timed.client.closed,true);
});
test("aborted status reads release pending waits without creating connections or automatic retries",async()=>{
  const controller=new AbortController(),{client,calls}=await opened(()=>new Promise(()=>{}));
  const pending=client.eventConsumerStatus("consumer",{signal:controller.signal}),rejected=assert.rejects(pending,code("cancelled"));controller.abort();await rejected;
  assert.equal(client.closed,true);assert.equal(calls.length,2);await assert.rejects(client.eventConsumerStatus("consumer"),code("unavailable"));
});
