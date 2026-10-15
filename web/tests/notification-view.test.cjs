"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),N=require("../dist/notification-view.js"),P=require("../dist/task-pages.js"),C=require("../dist/bridge-client.js"),I=require("../dist/i18n.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject};};
const evt=(sequence,patch={})=>({sequence,job_id:"jobHash",revision:1,type:"queued",state:"queued",...patch});
const hostInfo=()=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN"],databaseSchema:3,active:0,completed:0,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[]});
async function setup({scenario="owner",capacity=100,consumerID="notifications",override={}}={}) {
  const original=M.createFixtureAdapter(),session=await original.beginFixtureSession(scenario),api={...original,...override};
  const view=await N.createFixtureNotificationView(api,session,{consumerID,capacity});return {original,api,session,view};
}
test("fixture notification view projects immutable pending records, replays and clears only after success",async()=>{
  const {view,original,session}=await setup();assert.equal(view.snapshot().phase,"idle");
  const loaded=await view.poll();assert.deepEqual(loaded.items.map(x=>x.sequence),[4,3,1]);
  assert.deepEqual(Object.keys(loaded.items[0]),["sequence","jobID","revision","type","state"]);
  assert.ok(Object.isFrozen(loaded.items[0])&&Object.isFrozen(loaded.items));assert.equal(loaded.confirmedThrough,0);
  assert.deepEqual((await view.poll()).items,loaded.items);
  const confirmed=await view.acknowledge();assert.deepEqual(confirmed.items,[]);assert.equal(confirmed.confirmedThrough,4);
  assert.deepEqual((await view.poll()).items,[]);assert.equal((await original.listJobs(session)).length,5);
  await assert.rejects(view.acknowledge(),code("denied"));
});
test("100 pending records apply backpressure without dropping or implicitly acknowledging the next batch",async()=>{
  let polls=0,acks=0;const api=M.createFixtureAdapter(),session=await api.beginFixtureSession();
  for(let i=0;i<98;i++)await api.submitLabelJob({id:"bounded-"+i,key:"bounded-"+i,value:"合成"},session);
  const view=await N.createFixtureNotificationView({...api,pollEvents:async(...args)=>{polls++;assert.equal(args[2],100);return api.pollEvents(...args);},acknowledgeEvents:async(...args)=>{acks++;return api.acknowledgeEvents(...args);}},session,{consumerID:"hundred"});
  const first=await view.poll();assert.equal(first.items.length,100);assert.equal(first.full,true);
  for(let i=0;i<5;i++)await assert.rejects(view.poll(),code("budgetExceeded"));
  assert.equal(polls,1);assert.equal(acks,0);assert.equal(view.snapshot().items.length,100);
  await view.acknowledge();assert.equal(acks,1);assert.equal(view.snapshot().full,false);
  assert.equal((await view.poll()).items.length,1);await view.acknowledge();assert.deepEqual((await view.poll()).items,[]);
});
test("replay merges with newly delivered events without using a remaining-capacity poll that stalls on old records",async()=>{
  let count=0;const {view}=await setup({capacity:5,override:{pollEvents:async(id,session,limit)=>{assert.equal(limit,5);return ++count===1?[evt(1),evt(2)]:[evt(1),evt(2),evt(3),evt(4)];}}});
  await view.poll();assert.deepEqual((await view.poll()).items.map(x=>x.sequence),[4,3,2,1]);assert.equal(view.snapshot().full,false);
});
test("conflicting replay quarantines the view and retains its earlier unconfirmed batch",async()=>{
  let polls=0;const {view}=await setup({override:{pollEvents:async()=>[evt(1,++polls===1?{}:{revision:2})]}});
  const old=(await view.poll()).items;await assert.rejects(view.poll(),code("invalidResponse"));
  assert.deepEqual(view.snapshot().items,old);assert.equal(view.snapshot().unavailable,true);
  await assert.rejects(view.acknowledge(),code("unavailable"));assert.equal(view.snapshot().confirmedThrough,0);
});
test("invalid event shapes, ordering, state relationships and unsafe identifiers fail atomically",async()=>{
  for(const raw of [[evt(1),evt(1)],[evt(2),evt(1)],[evt(1,{sequence:0})],[evt(1,{sequence:Number.MAX_SAFE_INTEGER+1})],[evt(1,{revision:0})],[evt(1,{type:"queued",state:"completed"})],[evt(1,{job_id:"\uD800"})],[evt(1,{owner_user:"other"})],[evt(1,{type:"toString"})],[evt(1,{type:{}})]]){
    const {view}=await setup({override:{pollEvents:async()=>raw}});await assert.rejects(view.poll(),code("invalidResponse"));
    assert.deepEqual(view.snapshot().items,[]);assert.equal(view.snapshot().confirmedThrough,0);
  }
});
test("over-budget input is an explicit error that preserves old data and never sends ACK",async()=>{
  let count=0,acks=0;const {view}=await setup({capacity:3,override:{pollEvents:async()=>++count===1?[evt(1),evt(2)]:[evt(3),evt(4)],acknowledgeEvents:async()=>{acks++;}}});
  const old=(await view.poll()).items;await assert.rejects(view.poll(),code("budgetExceeded"));
  assert.deepEqual(view.snapshot().items,old);assert.equal(acks,0);assert.equal(view.snapshot().unavailable,false);
  const malformed=await setup({capacity:1,override:{pollEvents:async()=>[evt(1),evt(2)]}});await assert.rejects(malformed.view.poll(),code("invalidResponse"));
});
test("same consumer polls and acknowledgements serialize across views sharing a provider",async()=>{
  const gate=deferred(),{view,api,session}=await setup({override:{pollEvents:()=>gate.promise}});
  const other=await N.createFixtureNotificationView(api,session,{consumerID:"notifications"});
  const pending=view.poll();assert.equal(view.snapshot().phase,"polling");
  await assert.rejects(view.poll(),code("busy"));await assert.rejects(view.acknowledge(),code("busy"));await assert.rejects(other.poll(),code("busy"));
  gate.resolve([evt(1)]);await pending;assert.equal((await other.poll()).items.length,1);
});
test("in-flight consumer lock budget is bounded and disposal does not prematurely release a live operation",async()=>{
  const gate=deferred(),api=M.createFixtureAdapter(),session=await api.beginFixtureSession(),borrowed={...api,pollEvents:()=>gate.promise};
  const views=[];for(let i=0;i<33;i++)views.push(await N.createFixtureNotificationView(borrowed,session,{consumerID:"lock-"+i}));
  const pending=views.slice(0,32).map(view=>view.poll());await assert.rejects(views[32].poll(),code("budgetExceeded"));
  views[0].dispose();await assert.rejects(views[32].poll(),code("budgetExceeded"));gate.resolve([]);await Promise.all(pending);
  assert.equal((await views[32].poll()).phase,"ready");
});
test("ACK failure preserves the batch and retries exactly the captured delivered upper bound",async()=>{
  const calls=[];let first=true;const {view}=await setup({override:{pollEvents:async()=>[evt(2),evt(9)],acknowledgeEvents:async(id,through)=>{calls.push(through);if(first){first=false;throw new M.ServiceError("database");}}}});
  const old=(await view.poll()).items;await assert.rejects(view.acknowledge(),code("database"));
  assert.deepEqual(view.snapshot().items,old);assert.equal(view.snapshot().ackRetryRequired,true);assert.equal(view.snapshot().confirmedThrough,0);
  await assert.rejects(view.poll(),code("staleState"));await view.acknowledge();assert.deepEqual(calls,[9,9]);
  assert.deepEqual(view.snapshot().items,[]);assert.equal(view.snapshot().confirmedThrough,9);
});
test("committed ACK with lost response stays unconfirmed locally until explicit idempotent retry succeeds",async()=>{
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(),throughs=[];let lost=true;
  const view=await N.createFixtureNotificationView({...api,acknowledgeEvents:async(id,through,s)=>{throughs.push(through);await api.acknowledgeEvents(id,through,s);if(lost){lost=false;throw new M.ServiceError("database");}}},session,{consumerID:"lost"});
  const batch=await view.poll();await assert.rejects(view.acknowledge(),code("database"));
  assert.deepEqual(await api.pollEvents("lost",session),[]);assert.deepEqual(view.snapshot().items,batch.items);
  await api.submitLabelJob({id:"after-lost",key:"after-lost",value:"later"},session);
  await assert.rejects(view.poll(),code("staleState"));await view.acknowledge();assert.deepEqual(throughs,[4,4]);
  assert.equal((await view.poll()).items[0].jobID,"after-lost");
});
test("ACK in flight cannot include a newly committed event or clear before success",async()=>{
  const gate=deferred(),api=M.createFixtureAdapter(),session=await api.beginFixtureSession();let through;
  const view=await N.createFixtureNotificationView({...api,acknowledgeEvents:async(id,n,s)=>{through=n;await gate.promise;return api.acknowledgeEvents(id,n,s);}},session,{consumerID:"inflight"});
  const batch=await view.poll(),pending=view.acknowledge();assert.equal(view.snapshot().phase,"acknowledging");assert.deepEqual(view.snapshot().items,batch.items);
  await api.submitLabelJob({id:"new-event",key:"new-event",value:"new"},session);await assert.rejects(view.poll(),code("busy"));
  gate.resolve();await pending;assert.equal(through,4);assert.deepEqual((await view.poll()).items.map(x=>x.jobID),["new-event"]);
});
test("closed poll and ACK results cannot repopulate or advance a disposed view",async()=>{
  for(const action of ["poll","acknowledge"]){
    const gate=deferred(),{view}=await setup({override:action==="poll"?{pollEvents:()=>gate.promise}:{acknowledgeEvents:()=>gate.promise}});
    if(action==="acknowledge")await view.poll();const pending=view[action]();view.dispose();view.dispose();gate.resolve(action==="poll"?[evt(8)]:undefined);
    assert.equal((await pending).phase,"closed");assert.deepEqual(view.snapshot().items,[]);assert.equal(view.snapshot().confirmedThrough,0);
    await assert.rejects(view.poll(),code("unavailable"));
  }
});
test("late failures are ignored after identity disposal and cannot affect another user's view",async()=>{
  const gate=deferred(),{view,original}=await setup({override:{pollEvents:()=>gate.promise}}),pending=view.poll();view.dispose();
  const reader=await original.beginFixtureSession("reader"),next=await N.createFixtureNotificationView(original,reader,{consumerID:"family-view"});
  gate.reject(Error("private database details"));await pending;assert.deepEqual((await next.poll()).items.map(x=>x.jobID),["family-job"]);
  assert.equal(next.snapshot().confirmedThrough,0);assert.equal(next.snapshot().error,null);
});
test("reader notifications remain scoped; another user cannot take over a persisted consumer",async()=>{
  const {view,original,session}=await setup();await view.poll();const reader=await original.beginFixtureSession("reader");
  const stolen=await N.createFixtureNotificationView(original,reader,{consumerID:"notifications"});await assert.rejects(stolen.poll(),code("denied"));
  await assert.rejects(original.acknowledgeEvents("notifications",4,reader),code("denied"));
  await assert.rejects(original.acknowledgeEvents("notifications",999,session),code("denied"));
  const family=await N.createFixtureNotificationView(original,reader,{consumerID:"family"});assert.deepEqual((await family.poll()).items.map(x=>x.sequence),[2]);await family.acknowledge();
});
test("read-only recovery refuses both delivery and ACK before touching their write operations",async()=>{
  let calls=0;const {view}=await setup({scenario:"recovery",override:{pollEvents:async()=>{calls++;},acknowledgeEvents:async()=>{calls++;}}});
  await assert.rejects(view.poll(),code("readOnly"));await assert.rejects(view.acknowledge(),code("readOnly"));assert.equal(calls,0);assert.deepEqual(view.snapshot().items,[]);
});
test("invalid options reject before overview, including getters and cross-field extras",async()=>{
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession();let calls=0,read=false;
  for(const options of [null,[],{consumerID:""},{consumerID:"a",capacity:0},{consumerID:"a",capacity:101},{consumerID:"a",capacity:null},{consumerID:"a",role:"owner"},{get consumerID(){read=true;return "a";}},{consumerID:"a",[Symbol("key")]:1}])await assert.rejects(N.createFixtureNotificationView({...api,overview:async()=>{calls++;}},session,options),code("invalidInput"));
  assert.equal(calls,0);assert.equal(read,false);await assert.rejects(N.createClientNotificationView(null,{consumerID:"x"}),code("unavailable"));
});
test("unknown diagnostics are sanitized and failed reads retain the previous batch",async()=>{
  let calls=0;const {view}=await setup({override:{pollEvents:async()=>{if(++calls===1)return [evt(1)];throw Error("secret path /database/password");}}});
  const old=(await view.poll()).items;await assert.rejects(view.poll(),code("unavailable"));assert.equal(view.snapshot().error,"unavailable");assert.deepEqual(view.snapshot().items,old);
});
test("notification names use only bounded current task rows and preserve literal translation-like or HTML titles",async()=>{
  const {original,session}=await setup(),source=await P.createFixtureTaskSource(original,session);
  await source.submitLabelJob({id:"a-name",key:"a-name",value:"jobHash"});const first=await source.page({pageSize:1});source.discardCursor(first.nextCursor);
  const t=key=>I.t("zh-CN",key);assert.equal(N.notificationTaskName({jobID:"a-name"},first.tasks,t),"jobHash");
  assert.equal(N.notificationTaskName({jobID:"jobHash"},first.tasks,t),t("notificationTaskFallback"));
  assert.equal(N.notificationTaskName({jobID:"html"},[{id:"html",name:{kind:"text",value:"<script>文本</script>"}}],t),"<script>文本</script>");
  assert.equal(N.notificationTaskName({jobID:"key"},[{id:"key",name:{kind:"key",value:"jobHash"}}],t),t("jobHash"));
  assert.throws(()=>N.notificationTaskName({jobID:"x"},Array(103).fill({id:"y"}),t),code("invalidInput"));
});
test("typed client integration is explicit, validates real DTOs and does not own shared connection closure",async()=>{
  const calls=[];let ack=0;const client=C.createDesktopClient({transport:async request=>{calls.push(request);return {apiVersion:1,requestId:request.requestId,data:request.method==="overview"?hostInfo():request.method==="pollEvents"?(ack?[]:[evt(1)]):(ack=request.params.through,true)};}});
  const view=await N.createClientNotificationView(client,{consumerID:"typed"});assert.equal(view.context.source,"fixture-host");
  assert.equal((await view.poll()).items[0].jobID,"jobHash");await view.acknowledge();assert.deepEqual((await view.poll()).items,[]);
  view.dispose();assert.equal(client.closed,false);assert.ok(calls.every(x=>!Object.hasOwn(x.params,"userID")));client.close();
});
test("lost ACK response that times out closes the client and never fabricates reconciliation on a new connection",async()=>{
  const committed=deferred(),late=deferred();let durableAck=0;
  const client=C.createDesktopClient({timeoutMs:30,transport:async request=>{
    if(request.method==="acknowledgeEvents"){durableAck=request.params.through;committed.resolve();await late.promise;}
    return {apiVersion:1,requestId:request.requestId,data:request.method==="overview"?hostInfo():request.method==="pollEvents"?[evt(7)]:true};
  }}),view=await N.createClientNotificationView(client,{consumerID:"timeout"});
  const old=(await view.poll()).items,pending=view.acknowledge();await committed.promise;assert.equal(durableAck,7);
  await assert.rejects(pending,code("timedOut"));assert.deepEqual(view.snapshot().items,old);assert.equal(view.snapshot().confirmedThrough,0);assert.equal(view.snapshot().unavailable,true);
  late.resolve();await Promise.resolve();await assert.rejects(view.acknowledge(),code("unavailable"));assert.deepEqual(view.snapshot().items,old);
});
test("ACK must return explicit true on a typed source and a closed shared client is reflected without polling",async()=>{
  const client=C.createDesktopClient({transport:async request=>({apiVersion:1,requestId:request.requestId,data:request.method==="overview"?hostInfo():request.method==="pollEvents"?[evt(1)]:false})});
  const view=await N.createClientNotificationView(client,{consumerID:"false-ack"});const old=(await view.poll()).items;
  await assert.rejects(view.acknowledge(),code("invalidResponse"));assert.deepEqual(view.snapshot().items,old);assert.equal(view.snapshot().confirmedThrough,0);
  assert.equal(view.snapshot().unavailable,true);
  const other=C.createDesktopClient({transport:async request=>({apiVersion:1,requestId:request.requestId,data:hostInfo()})});
  const borrowed=await N.createClientNotificationView(other,{consumerID:"closed"});other.close();assert.equal(borrowed.snapshot().unavailable,true);await assert.rejects(borrowed.poll(),code("unavailable"));
});
