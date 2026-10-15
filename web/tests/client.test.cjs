"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),C=require("../dist/bridge-client.js");
const errorCode=code=>error=>error instanceof M.ServiceError&&error.code===code;
const copy=value=>JSON.parse(JSON.stringify(value));
const lib=()=>({libraryID:"library",volumeID:"00000000-0000-4000-8000-000000000001",estimatedBytes:35000000000000,state:"missing"});
const info=()=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN","ja-JP"],databaseSchema:3,active:0,completed:0,logicalReferenceBytes:35000000000000,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[lib()]});
const job=(patch={})=>({id:"job",idempotency_key:"key",kind:"label",owner_user:"fixture-owner",title:"<script>普通数据</script>",titleKey:"jobLabels",state:"queued",attempts:0,max_attempts:3,effects:0,revision:1,checkpoint:{},...patch});
const event=(sequence=1,patch={})=>({sequence,job_id:"job",revision:sequence,type:"queued",state:"queued",...patch});
const file=(patch={})=>({name:"<b>笔记</b>.txt",relativePath:"<b>笔记</b>.txt",kind:"file",bytes:10,modifiedAt:"2026-10-15T00:00:00Z",...patch});
const page=(items=[],patch={})=>({pageVersion:1,order:"id-utf8",consistency:"live",pageSize:50,items,nextCursor:null,...patch});
const token="00000000-0000-4000-8000-000000000001";
function transport(handler=()=>true){return async request=>({apiVersion:1,requestId:request.requestId,data:request.method==="overview"?info():await handler(request)});}
async function opened(handler,config={}){const client=C.createDesktopClient({transport:transport(handler),...config});await client.overview();return client;}
async function bad(method,value,params=[]){const client=await opened(()=>value);await assert.rejects(client[method](...params),errorCode("invalidResponse"));assert.equal(client.closed,true);}

test("typed calls require a host overview and configuration cannot select an identity",async()=>{
  let calls=0;const client=C.createDesktopClient({transport:async()=>{calls++;}});
  await assert.rejects(client.listJobs(),errorCode("unavailable"));assert.equal(calls,0);client.close();
  for(const config of [{transport:()=>{},role:"administrator"},{transport:()=>{},timeoutMs:null},{transport:()=>{},maximumPending:0}])assert.throws(()=>C.createDesktopClient(config),errorCode("invalidInput"));
  let accessed=false;
  assert.throws(()=>C.createDesktopClient({get transport(){accessed=true;return ()=>{};}}),errorCode("invalidInput"));assert.equal(accessed,false);
});
test("overview rejects unknown fields, fabricated physical data, unsafe counts and inconsistent totals",async()=>{
  for(const patch of [{source:"production"},{physicalPool:"35TB"},{taskTimestampsAvailable:true},{active:true},{completed:-1},{logicalReferenceBytes:1},{databaseSchema:2},{languages:["zh-CN","zh-CN"]},{role:"root"},{token:"private"}]){
    const client=C.createDesktopClient({transport:async request=>({apiVersion:1,requestId:request.requestId,data:{...info(),...patch}})});
    await assert.rejects(client.overview(),errorCode("invalidResponse"));assert.equal(client.closed,true);
  }
});
test("identity, role or mode changes invalidate the whole connection",async()=>{
  for(const patch of [{userID:"someone-else"},{role:"reader"},{mode:"read_only_recovery"}]){
    let changed=false;const client=C.createDesktopClient({transport:async request=>({apiVersion:1,requestId:request.requestId,data:changed?{...info(),...patch}:info()})});
    await client.overview();changed=true;await assert.rejects(client.overview(),errorCode("denied"));
    await assert.rejects(client.listLibraries(),errorCode("unavailable"));
  }
});
test("task DTOs retain plain titles, immutable checkpoints and real terminal semantics",async()=>{
  const rows=[job(),job({id:"hash",idempotency_key:"hash-key",kind:"fixtureHash",title:undefined,titleKey:"jobHash",state:"completed",attempts:1,effects:1,checkpoint:{step:"completed"}})];
  delete rows[1].title;
  const client=await opened(()=>rows),result=await client.listJobs();
  assert.equal(result[0].title,"<script>普通数据</script>");assert.ok(Object.isFrozen(result)&&Object.isFrozen(result[1].checkpoint));
  assert.equal(result[0].updated,undefined);assert.throws(()=>{result[0].state="completed";},TypeError);client.close();
});
test("cross-user tasks, hidden payloads and impossible counters never reach consumers",async()=>{
  for(const patch of [{owner_user:"other"},{app_id:"hello-diagnostics"},{payload:{root:"/private"}},{titleKey:"arbitraryTranslation"},{attempts:4},{revision:0},{effects:1},{state:"completed"},{state:"running"},{last_error:"/private/SQL"},{checkpoint:{step:"completed"}},{kind:"appValue"}])await bad("listJobs",[job(patch)]);
  await bad("listJobs",[job(),job()]);
});
test("explicit label intent is immutable and retries may return the original durable task ID",async()=>{
  const intent=C.prepareLabelJob("合成 🐚"),calls=[];assert.ok(Object.isFrozen(intent));assert.notEqual(intent.id,intent.key);
  const client=await opened(request=>{calls.push(request);return job({id:"original",idempotency_key:request.params.key,title:request.params.value});});
  assert.equal((await client.submitLabelJob(intent)).id,"original");
  assert.equal((await client.submitLabelJob({...intent,id:"new-id"})).id,"original");
  assert.equal(calls[0].params.key,calls[1].params.key);assert.notEqual(calls[0].requestId,calls[1].requestId);
  assert.throws(()=>C.prepareLabelJob(" "),errorCode("invalidInput"));assert.throws(()=>C.prepareLabelJob("x".repeat(81)),errorCode("invalidInput"));client.close();
});
test("submission and cancellation responses must match the requested business operation",async()=>{
  await bad("submitLabelJob",job({idempotency_key:"wrong"}),[{id:"job",key:"key",value:"title"}]);
  await bad("submitLabelJob",job({title:"wrong"}),[{id:"job",key:"key",value:"title"}]);
  await bad("cancelJob",job(),["job"]);
  await bad("cancelJob",job({id:"other",state:"cancelled"}),["job"]);
});
test("events reject unsorted, duplicate, malformed and impossible transition records",async()=>{
  for(const events of [[event(2),event(1)],[event(1),event(1)],[event(0)],[event(1,{type:["queued"]})],[event(1,{type:"completed"})],[event(1,{owner_user:"private"})],[event(1,{revision:9007199254740992})]])await bad("pollEvents",events,["consumer",100]);
  await bad("pollEvents",[event(1),event(2)],["consumer",1]);
});
test("event replay is checked and ACK only advances to actually delivered sequence numbers",async()=>{
  let changed=false,acks=0;
  const client=await opened(request=>request.method==="pollEvents"?[event(2),event(4,changed?{job_id:"different"}:{})]:(acks++,true));
  assert.deepEqual(await client.pollEvents("consumer"),[event(2),event(4)]);
  await assert.rejects(client.acknowledgeEvents("consumer",3),errorCode("denied"));
  await assert.rejects(client.acknowledgeEvents("consumer",99),errorCode("denied"));assert.equal(acks,0);
  await client.acknowledgeEvents("consumer",2);await client.acknowledgeEvents("consumer",2);assert.equal(acks,2);
  await assert.rejects(client.acknowledgeEvents("consumer",1),errorCode("denied"));client.close();
  const conflicting=await opened(()=>[event(1,changed?{revision:2}:{})]);await conflicting.pollEvents("consumer");changed=true;
  await assert.rejects(conflicting.pollEvents("consumer"),errorCode("invalidResponse"));assert.equal(conflicting.closed,true);
});
test("consumer requests serialize and the cursor registry is bounded",async()=>{
  let release;const client=await opened(()=>new Promise(resolve=>{release=resolve;}));
  const waiting=client.pollEvents("consumer");await assert.rejects(client.pollEvents("consumer"),errorCode("busy"));
  await assert.rejects(client.acknowledgeEvents("consumer",0),errorCode("busy"));release([]);await waiting;client.close();
  const bounded=await opened(()=>[]);for(let i=0;i<32;i++)await bounded.pollEvents("consumer-"+i);
  await assert.rejects(bounded.pollEvents("too-many"),errorCode("budgetExceeded"));bounded.close();
});
test("library discovery checks identifiers, safe estimates, states and duplicate logical IDs",async()=>{
  const client=await opened(()=>[lib()]);assert.equal((await client.listLibraries())[0].state,"missing");client.close();
  for(const patch of [{estimatedBytes:9007199254740992},{estimatedBytes:-1},{volumeID:"host-path"},{state:"online"},{root:"/"}])await bad("listLibraries",[{...lib(),...patch}]);
  await bad("listLibraries",[lib(),lib()]);
});
test("file metadata stays relative, rejects collisions and distinguishes directories from byte counts",async()=>{
  const valid=file({name:"笔记.txt",relativePath:"folder/笔记.txt"});
  const folder={name:"child",relativePath:"folder/child",kind:"directory",modifiedAt:"2026-10-15T00:00:00Z"};
  const client=await opened(()=>[valid,folder]);assert.equal((await client.listFiles({libraryID:"library",relativePath:"folder"}))[0].name,"笔记.txt");client.close();
  for(const patch of [{relativePath:"../outside.txt"},{relativePath:"other.txt"},{kind:"directory"},{bytes:null},{modifiedAt:"2026-02-30T00:00:00Z"},{nameKey:"fakeTranslation"}])await bad("listFiles",[file({...patch,name:"note.txt",...("relativePath" in patch?{}:{relativePath:"note.txt"})})],[{libraryID:"library"}]);
  await bad("listFiles",[file({name:"A.txt",relativePath:"A.txt"}),file({name:"a.txt",relativePath:"a.txt"})],[{libraryID:"library"}]);
});
test("text preview verifies request correlation and UTF-8 bytes while preserving ordinary HTML and NUL data",async()=>{
  const value={libraryID:"library",relativePath:"note.txt",text:"<b>中文 🐚</b>\0",utf8Bytes:Buffer.byteLength("<b>中文 🐚</b>\0")};
  const client=await opened(()=>value);assert.equal((await client.previewFile({libraryID:"library",relativePath:"note.txt"})).text,value.text);client.close();
  for(const patch of [{libraryID:"other"},{relativePath:"other.txt"},{utf8Bytes:1},{nameKey:"private"}])await bad("previewFile",{...value,...patch},[{libraryID:"library",relativePath:"note.txt"}]);
});
test("unknown fields, null defaults, traversal, getters and invalid limits are rejected before transport",async()=>{
  let calls=0,accessed=false;const client=await opened(()=>{calls++;return [];});
  for(const params of [{libraryID:"library",root:"/"},{libraryID:"library",relativePath:null},{libraryID:"library",maximumEntries:null},{libraryID:"library",maximumEntries:true},{libraryID:"library",relativePath:"../outside"},{get libraryID(){accessed=true;return "library";}}])await assert.rejects(client.listFiles(params),errorCode("invalidInput"));
  await assert.rejects(client.previewFile({libraryID:"library",relativePath:"note.txt",maximumBytes:null}),errorCode("invalidInput"));
  await assert.rejects(client.listJobs({role:"administrator"}),errorCode("invalidInput"));
  assert.equal(calls,0);assert.equal(accessed,false);client.close();
});
test("read-only and reader contexts refuse local writes while retaining query access",async()=>{
  for(const patch of [{mode:"read_only_recovery"},{mode:"rolled_back_recovery"},{role:"reader"}]){
    const client=C.createDesktopClient({transport:async r=>({apiVersion:1,requestId:r.requestId,data:r.method==="overview"?{...info(),...patch}:[]})});
    await client.overview();await client.listJobs();
    await assert.rejects(client.submitLabelJob({id:"x",key:"x",value:"x"}),errorCode(patch.role?"denied":"readOnly"));client.close();
  }
});
test("timeout aborts transport, cancels other calls and discards late successful writes",async()=>{
  const signals=[],releases=[];let closes=0;
  const client=await opened(undefined,{timeoutMs:15,closeTransport:()=>{closes++;},transport:async(r,context)=>r.method==="overview"?{apiVersion:1,requestId:r.requestId,data:info()}:new Promise(resolve=>{signals.push(context.signal);releases.push(()=>resolve({apiVersion:1,requestId:r.requestId,data:r.method==="submitLabelJob"?job({id:r.params.id,idempotency_key:r.params.key,title:r.params.value}):[]}));})});
  const first=client.submitLabelJob(C.prepareLabelJob("合成写入")),second=client.listLibraries();
  const result=await Promise.allSettled([first,second]);assert.equal(result[0].reason.code,"timedOut");assert.equal(result[1].reason.code,"cancelled");
  assert.ok(signals.every(signal=>signal.aborted));assert.equal(closes,1);releases.forEach(fn=>fn());await new Promise(setImmediate);
  await assert.rejects(client.listJobs(),errorCode("unavailable"));client.close();assert.equal(closes,1);
});
test("close and caller cancellation invalidate pending responses without leaking errors",async()=>{
  const controller=new AbortController();let signal;
  const client=await opened(undefined,{transport:async(r,ctx)=>r.method==="overview"?{apiVersion:1,requestId:r.requestId,data:info()}:new Promise(()=>{signal=ctx.signal;}),closeTransport:()=>{throw Error("private socket path");}});
  const waiting=client.listJobs({signal:controller.signal});controller.abort();await assert.rejects(waiting,errorCode("cancelled"));assert.equal(signal.aborted,true);assert.equal(client.closed,true);
  const other=await opened(()=>new Promise(()=>{}));const promise=other.listJobs();other.close();await assert.rejects(promise,errorCode("cancelled"));
});
test("pre-aborted calls and concurrency backpressure do not dispatch extra requests",async()=>{
  let count=0,release;const client=await opened(()=>{count++;return new Promise(resolve=>{release=resolve;});},{maximumPending:1});
  const controller=new AbortController();controller.abort();await assert.rejects(client.listJobs({signal:controller.signal}),errorCode("cancelled"));assert.equal(client.closed,false);
  const first=client.listJobs();await assert.rejects(client.listLibraries(),errorCode("busy"));assert.equal(count,1);release([]);await first;client.close();
});
test("recreated typed clients have distinct wire IDs even on the same host transport",async()=>{
  const ids=new Set();const send=async request=>{assert.ok(!ids.has(request.requestId));ids.add(request.requestId);return {apiVersion:1,requestId:request.requestId,data:info()};};
  const first=C.createDesktopClient({transport:send}),second=C.createDesktopClient({transport:send});await first.overview();first.close();await second.overview();second.close();assert.equal(ids.size,2);
});
test("business refusal keeps the client usable while transport failures are fixed-code fatal errors",async()=>{
  const client=C.createDesktopClient({transport:async r=>r.method==="overview"?{apiVersion:1,requestId:r.requestId,data:info()}:{apiVersion:1,requestId:r.requestId,error:{code:"denied"}}});
  await client.overview();await assert.rejects(client.authorizeApp("settings"),errorCode("denied"));assert.equal(client.closed,false);client.close();
  const broken=await opened(()=>{throw Error("/private SQL credential");});await assert.rejects(broken.listJobs(),error=>errorCode("unavailable")(error)&&error.message==="unavailable");assert.equal(broken.closed,true);
});

test("generic prefix and request history are bounded independently of the typed client",async()=>{
  assert.throws(()=>M.createBridgeAdapter(()=>{}, {requestIdPrefix:"../wrong prefix"}),errorCode("invalidInput"));
  let calls=0;const api=M.createBridgeAdapter(r=>{calls++;return {apiVersion:1,requestId:r.requestId,data:true};},{requestIdPrefix:"bounded"});
  for(let i=0;i<4096;i++)assert.equal(await api.request("authorizeApp",{id:"overview"}),true);
  await assert.rejects(api.request("authorizeApp",{id:"overview"}),errorCode("budgetExceeded"));assert.equal(calls,4096);
});

test("task pages preserve raw Unicode byte ordering, metadata and terminal null",async()=>{
  const ids=["a","e\u0301","é","中","\uE000","🐚"],client=await opened(()=>page(ids.map(id=>job({id,idempotency_key:id}))));
  const result=await client.listJobsPage();assert.deepEqual(result.items.map(x=>x.id),ids);
  assert.equal(result.nextCursor,null);assert.equal(result.consistency,"live");assert.ok(Object.isFrozen(result.items));client.close();
});
test("page DTOs reject wrong versions, order, shape, limits, cursors and unsorted IDs",async()=>{
  for(const patch of [{pageVersion:2},{order:"locale"},{consistency:"snapshot"},{pageSize:1},{nextCursor:"sql"},{nextCursor:token},{total:100},{items:[job(),job()]},{items:[job({id:"z",idempotency_key:"z"}),job({id:"a",idempotency_key:"a"})]},{items:[job({owner_user:"other"})]}])await bad("listJobsPage",page([],{...patch}));
  const absent=page();delete absent.nextCursor;await bad("listJobsPage",absent);
  await bad("listJobsPage",page([job(),job({id:"other",idempotency_key:"other"})],{pageSize:1}),[{pageSize:1}]);
});
test("continuations are owned by the client, size-bound, serialized and checked across pages",async()=>{
  let release,calls=0;
  const client=await opened(request=>{calls++;return request.params.cursor?new Promise(resolve=>{release=resolve;}):page([job({id:"m"})],{pageSize:1,nextCursor:token});});
  await client.listJobsPage({pageSize:1});
  await assert.rejects(client.listJobsPage({pageSize:2,cursor:token}),errorCode("denied"));
  const waiting=client.listJobsPage({pageSize:1,cursor:token});
  await assert.rejects(client.listJobsPage({pageSize:1,cursor:token}),errorCode("busy"));assert.equal(calls,2);
  release(page([job({id:"a"})],{pageSize:1}));await assert.rejects(waiting,errorCode("invalidResponse"));assert.equal(client.closed,true);
  const other=await opened(()=>page());await assert.rejects(other.listJobsPage({pageSize:1,cursor:token}),errorCode("denied"));other.close();
});
test("successful continuation consumes the token, rejects repetition and bounds abandoned chains",async()=>{
  let counter=0;
  const client=await opened(request=>request.params.cursor?page([job({id:"z"})],{pageSize:1}):page([job({id:"a"})],{pageSize:1,nextCursor:`00000000-0000-4000-8000-${String(++counter).padStart(12,"0")}`}));
  const first=await client.listJobsPage({pageSize:1});await client.listJobsPage({pageSize:1,cursor:first.nextCursor});
  await assert.rejects(client.listJobsPage({pageSize:1,cursor:first.nextCursor}),errorCode("denied"));
  for(let i=0;i<128;i++)await client.listJobsPage({pageSize:1});
  await assert.rejects(client.listJobsPage({pageSize:1}),errorCode("budgetExceeded"));assert.equal(counter,129);client.close();
});
test("page input errors do not dispatch, and expired capabilities are removed without closing",async()=>{
  let calls=0;
  const client=await opened(()=>{calls++;return page([job()],{pageSize:1,nextCursor:token});});
  for(const params of [{pageSize:null},{pageSize:true},{pageSize:0},{pageSize:101},{cursor:null},{cursor:"SQL"},{sort:"state"},{userID:"other"}])await assert.rejects(client.listJobsPage(params),errorCode("invalidInput"));
  assert.equal(calls,0);client.close();
  let continuations=0;
  const expired=C.createDesktopClient({transport:async r=>r.method==="overview"?{apiVersion:1,requestId:r.requestId,data:info()}:r.params.cursor?(continuations++,{apiVersion:1,requestId:r.requestId,error:{code:"expired"}}):{apiVersion:1,requestId:r.requestId,data:page([job()],{pageSize:1,nextCursor:token})}});
  await expired.overview();await expired.listJobsPage({pageSize:1});
  await assert.rejects(expired.listJobsPage({pageSize:1,cursor:token}),errorCode("expired"));
  await assert.rejects(expired.listJobsPage({pageSize:1,cursor:token}),errorCode("denied"));assert.equal(continuations,1);assert.equal(expired.closed,false);expired.close();
});
