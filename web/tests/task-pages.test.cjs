"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),P=require("../dist/task-pages.js"),C=require("../dist/bridge-client.js"),I=require("../dist/i18n.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const copy=value=>JSON.parse(JSON.stringify(value)),t=key=>I.t("zh-CN",key);
const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
const token=n=>`00000000-0000-4000-8000-${String(n).padStart(12,"0")}`;
const rawJob=(id="job",patch={})=>({id,idempotency_key:"key-"+id,owner_user:"fixture-owner",kind:"label",title:"普通标题",titleKey:"jobLabels",state:"queued",attempts:0,max_attempts:3,effects:0,revision:1,checkpoint:{},...patch});
const rawPage=(items=[],patch={})=>({pageVersion:1,order:"id-utf8",consistency:"live",pageSize:50,items,nextCursor:null,...patch});
const hostInfo=()=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN"],databaseSchema:3,active:3,completed:1,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[]});
async function setup(scenario="owner",options={},override={}) {
  const api=M.createFixtureAdapter(options),session=await api.beginFixtureSession(scenario);
  const source=await P.createFixtureTaskSource({...api,...override},session);
  return {api,session,source,pager:P.createTaskPager({source,pageSize:2})};
}

test("fixture pages are byte-ordered, scoped, one-use and return explicit terminal null",async()=>{
  const {api,session}=await setup();
  for(const id of ["é","e\u0301","\uE000","🐚","a' OR true --"])await api.submitLabelJob({id,key:id,value:id},session);
  const reader=await api.beginFixtureSession("reader"),other=await api.beginFixtureSession("owner");
  let page=await api.listJobsPage({pageSize:2},session);const first=page.nextCursor,ids=[...page.items.map(x=>x.id)];
  await assert.rejects(api.listJobsPage({pageSize:2,cursor:first},reader),code("denied"));
  await assert.rejects(api.listJobsPage({pageSize:2,cursor:first},other),code("denied"));
  await assert.rejects(api.listJobsPage({pageSize:1,cursor:first},session),code("denied"));
  while(page.nextCursor!==null){page=await api.listJobsPage({pageSize:2,cursor:page.nextCursor},session);ids.push(...page.items.map(x=>x.id));}
  assert.deepEqual(ids,(await api.listJobs(session)).map(x=>x.id).sort((a,b)=>Buffer.compare(Buffer.from(a),Buffer.from(b))));
  await assert.rejects(api.listJobsPage({pageSize:2,cursor:first},session),code("replay"));
  assert.deepEqual((await api.listJobsPage({},reader)).items.map(x=>x.id),["family-job"]);
});
test("fixture cursor lifetime is non-sliding, survives read-only queries and ends with the session",async()=>{
  let now=0;const {api,session}=await setup("recovery",{monotonicNow:()=>now});
  const first=await api.listJobsPage({pageSize:1},session);now=59000;
  const second=await api.listJobsPage({pageSize:1,cursor:first.nextCursor},session);now=60000;
  await assert.rejects(api.listJobsPage({pageSize:1,cursor:second.nextCursor},session),code("expired"));
  const next=await api.listJobsPage({pageSize:1},session);await api.endSession(session);
  await assert.rejects(api.listJobsPage({pageSize:1,cursor:next.nextCursor},session),code("denied"));
});
test("fixture cursor resources are bounded, discard is scoped and expiry reclaims slots",async()=>{
  let now=0;const {api,session}=await setup("owner",{monotonicNow:()=>now}),reader=await api.beginFixtureSession("reader");
  const cursors=[];for(let i=0;i<128;i++)cursors.push((await api.listJobsPage({pageSize:1},session)).nextCursor);
  await assert.rejects(api.listJobsPage({pageSize:1},session),code("budgetExceeded"));
  await assert.rejects(api.discardJobPage(cursors[0],reader),code("denied"));
  assert.equal(await api.discardJobPage(cursors[0],session),true);assert.equal(await api.discardJobPage(cursors[0],session),false);
  await api.listJobsPage({pageSize:1},session);now=60000;assert.ok((await api.listJobsPage({pageSize:1},session)).nextCursor);
});
test("fixture page input refuses null, getters, unknown fields and invalid limits before access",async()=>{
  const {api,session}=await setup();let accessed=false;
  for(const params of [null,{pageSize:true},{pageSize:0},{pageSize:101},{pageSize:null},{cursor:null},{cursor:"sql"},{sort:"state"},{get cursor(){accessed=true;return token(1);}}, {[Symbol("cursor")]:token(1)}])await assert.rejects(api.listJobsPage(params,session),code("invalidInput"));
  assert.equal(accessed,false);
});
test("live pages see later IDs and updated states, while earlier insertions require reload",async()=>{
  const {api,session}=await setup();
  const first=await api.listJobsPage({pageSize:3},session);
  for(const id of ["a-before","z-after"])await api.submitLabelJob({id,key:id,value:id},session);
  await api.cancelJob("demo-retry",session);
  const next=await api.listJobsPage({pageSize:3,cursor:first.nextCursor},session);
  assert.deepEqual(next.items.map(x=>x.id),["demo-retry","demo-volume","z-after"]);assert.equal(next.items[0].state,"cancelled");
  assert.equal((await api.listJobsPage({pageSize:1},session)).items[0].id,"a-before");
});
test("presentation projects immutable fields and independent counts without task timestamps",async()=>{
  const {source}=await setup(),pager=P.createTaskPager({source,pageSize:1});
  assert.equal(pager.snapshot().phase,"idle");const pending=pager.reload();assert.equal(pager.snapshot().phase,"loading");
  const result=await pending,info=await source.overview();
  assert.equal(result.items[0].state,"completed");assert.equal(info.active,3);assert.equal(info.completed,1);
  assert.equal(info.taskTimestampsAvailable,false);assert.equal(result.items[0].updated,undefined);assert.equal(result.items[0].idempotency_key,undefined);
  assert.ok(Object.isFrozen(result.items)&&Object.isFrozen(result.items[0].name));assert.equal(result.nextCursor,undefined);
});
test("pager only replaces one page, does not invoke legacy arrays and stops at terminal pages",async()=>{
  let calls=0;const api=M.createFixtureAdapter(),session=await api.beginFixtureSession();
  const source=await P.createFixtureTaskSource({...api,listJobs:()=>{throw Error("legacy must not be called");},listJobsPage:async(...args)=>{calls++;return api.listJobsPage(...args);}},session);
  const pager=P.createTaskPager({source,pageSize:2}),first=await pager.reload();assert.equal(calls,1);assert.equal(first.items.length,2);
  const second=await pager.next();assert.equal(second.pageNumber,2);assert.equal(second.items.length,2);assert.notEqual(first.items[0].id,second.items[0].id);
  const third=await pager.next();assert.equal(third.items.length,1);assert.equal(third.hasNext,false);assert.equal(calls,3);
  await assert.rejects(pager.next(),code("denied"));assert.equal(calls,3);
  assert.throws(()=>P.createTaskPager({source:{page:()=>{}},pageSize:2}),code("invalidInput"));
});
test("search and filters only inspect the current page, preserving literal translation-like titles",async()=>{
  const {api,session,source,pager}=await setup();await pager.reload();
  assert.equal(P.filterTasks(pager.snapshot().items,{search:"demo-volume"},t).length,0);
  await source.submitLabelJob({id:"a-name",key:"a-name",value:"jobHash"});await pager.reload();
  const named=pager.snapshot().items[0];assert.equal(P.taskName(named,()=>{throw Error("must not translate");}),"jobHash");
  assert.equal(P.filterTasks(pager.snapshot().items,{search:"jobhash",filter:"inProgress"},t).length,1);
  assert.equal(P.filterTasks(pager.snapshot().items,{filter:"finished"},t).length,1);
  await api.submitLabelJob({id:"a-html",key:"a-html",value:"<script>中文</script>"},session);await pager.reload();
  assert.equal(P.taskName(pager.snapshot().items[0],t),"<script>中文</script>");
});
test("cancellation refreshes the current page in place and leaves continuation usable",async()=>{
  const {source}=await setup(),pager=P.createTaskPager({source,pageSize:3});
  const first=await pager.reload(),ids=first.items.map(x=>x.id);
  await assert.rejects(pager.cancelJob("demo-volume"),code("denied"));
  const pending=pager.cancelJob("demo-hash");assert.equal(pager.snapshot().phase,"mutating");
  await assert.rejects(pager.next(),code("busy"));const changed=await pending;
  assert.equal(changed.pageNumber,1);assert.deepEqual(changed.items.map(x=>x.id),ids);assert.equal(changed.items.at(-1).state,"cancelled");
  assert.equal((await source.overview()).active,2);assert.equal((await pager.next()).pageNumber,2);
});
test("reader and recovery task views preserve scopes and refuse read-only mutation",async()=>{
  const reader=await setup("reader");assert.deepEqual((await reader.pager.reload()).items.map(x=>x.id),["family-job"]);
  assert.equal((await reader.pager.cancelJob("family-job")).items[0].state,"cancelled");
  await assert.rejects(reader.source.submitLabelJob({id:"r",key:"r",value:"r"}),code("denied"));
  const recovery=await setup("recovery");await recovery.pager.reload();
  await assert.rejects(recovery.pager.cancelJob("demo-failed"),code("readOnly"));
  assert.equal(recovery.pager.snapshot().requiresReload,true);assert.equal((await recovery.pager.reload()).phase,"ready");
});
test("expired continuation retains a labelled stale page, disables next and never auto-retries",async()=>{
  let now=0,calls=0;const api=M.createFixtureAdapter({monotonicNow:()=>now}),session=await api.beginFixtureSession();
  const source=await P.createFixtureTaskSource({...api,listJobsPage:async(...args)=>{calls++;return api.listJobsPage(...args);}},session),pager=P.createTaskPager({source,pageSize:2});
  const first=await pager.reload();now=60000;
  await assert.rejects(pager.next(),code("expired"));assert.deepEqual(pager.snapshot().items,first.items);
  assert.equal(pager.snapshot().requiresReload,true);assert.equal(pager.snapshot().hasNext,false);assert.equal(calls,2);
  await assert.rejects(pager.next(),code("denied"));assert.equal(calls,2);
  assert.equal((await pager.reload()).phase,"ready");assert.equal(calls,3);
});
test("unknown post-commit write failure stays ambiguous until an explicit reload",async()=>{
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession();
  const source=await P.createFixtureTaskSource({...api,cancelJob:async(...args)=>{await api.cancelJob(...args);throw Error("/private/SQL credential");}},session),pager=P.createTaskPager({source,pageSize:3});
  await pager.reload();await assert.rejects(pager.cancelJob("demo-hash"),error=>code("unavailable")(error)&&error.message==="unavailable");
  assert.equal(pager.snapshot().items.at(-1).state,"running");assert.equal(pager.snapshot().requiresReload,true);
  assert.equal((await pager.reload()).items.at(-1).state,"cancelled");
});
test("dispose discards late first-page responses without closing the shared source",async()=>{
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(),gate=deferred(),started=deferred(),discarded=[];
  let hold=true,returned;
  const source=await P.createFixtureTaskSource({...api,listJobsPage:async(...args)=>{const result=await api.listJobsPage(...args);if(hold){returned=result;started.resolve();await gate.promise;}return result;},discardJobPage:async cursor=>{discarded.push(cursor);return api.discardJobPage(cursor,session);}},session);
  const pager=P.createTaskPager({source,pageSize:2}),pending=pager.reload();await started.promise;
  await assert.rejects(pager.reload(),code("busy"));pager.dispose();gate.resolve();await pending;
  assert.equal(pager.snapshot().phase,"closed");assert.deepEqual(pager.snapshot().items,[]);assert.ok(discarded.includes(returned.nextCursor));assert.equal(source.closed,false);
  hold=false;const next=P.createTaskPager({source,pageSize:2});assert.equal((await next.reload()).phase,"ready");
});
test("closing a session prevents old results from reaching a replacement reader model",async()=>{
  const api=M.createFixtureAdapter(),old=await api.beginFixtureSession(),gate=deferred(),started=deferred();
  const source=await P.createFixtureTaskSource({...api,listJobsPage:async(...args)=>{const result=await api.listJobsPage(...args);started.resolve();await gate.promise;return result;}},old);
  const pager=P.createTaskPager({source,pageSize:2}),pending=pager.reload();await started.promise;pager.dispose();await source.close();
  const reader=await api.beginFixtureSession("reader"),replacement=await P.createFixtureTaskSource(api,reader),fresh=P.createTaskPager({source:replacement});
  gate.resolve();await pending;assert.deepEqual(pager.snapshot().items,[]);assert.deepEqual((await fresh.reload()).items.map(x=>x.id),["family-job"]);
  await assert.rejects(api.overview(old),code("denied"));
});
test("context changes close the source and revoke its fixture session",async()=>{
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession();let changed=false;
  const source=await P.createFixtureTaskSource({...api,overview:async s=>({...await api.overview(s),...(changed?{role:"reader"}:{})})},session);
  changed=true;await assert.rejects(source.overview(),code("denied"));assert.equal(source.closed,true);
  await assert.rejects(api.overview(session),code("denied"));await source.close();
});
test("presentation rejects malformed page metadata, hidden audiences and arbitrary translation keys",async()=>{
  for(const patch of [{pageVersion:2},{order:"locale"},{pageSize:1},{extra:"path"},{nextCursor:token(1)},{items:[rawJob("x",{owner_user:"other"})]},{items:[rawJob("x",{title:undefined,titleKey:"private-key"})]},{items:[rawJob("z"),rawJob("a")]},{items:[rawJob("x",{title:"\uD800"})]}]){
    const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(),source=await P.createFixtureTaskSource({...api,listJobsPage:async()=>copy(rawPage([],{...patch}))},session);
    await assert.rejects(source.page(),code("invalidResponse"));assert.equal(source.closed,true);
  }
});
test("typed-client source is explicit, projects plain host titles and never creates fixture fallback",async()=>{
  await assert.rejects(P.createClientTaskSource(),code("unavailable"));await assert.rejects(P.createClientTaskSource({source:"fixture"}),code("unavailable"));
  const client=C.createDesktopClient({transport:async r=>({apiVersion:1,requestId:r.requestId,data:r.method==="overview"?hostInfo():rawPage([rawJob("a",{title:"jobHash"})])})});
  const source=await P.createClientTaskSource(client),pager=P.createTaskPager({source});
  assert.equal(source.context.source,"fixture-host");assert.equal(P.taskName((await pager.reload()).items[0],t),"jobHash");
  assert.equal((await source.overview()).taskTimestampsAvailable,false);pager.dispose();assert.equal(client.closed,false);await source.close();assert.equal(client.closed,true);
});
test("dispose during a typed continuation releases the late local capability after it settles",async()=>{
  const gate=deferred(),started=deferred();
  const client=C.createDesktopClient({transport:async r=>{
    if(r.method==="overview")return {apiVersion:1,requestId:r.requestId,data:hostInfo()};
    if(r.params.cursor){started.resolve();await gate.promise;}
    return {apiVersion:1,requestId:r.requestId,data:rawPage([rawJob(r.params.cursor?"b":"a")],{pageSize:1,nextCursor:r.params.cursor?token(2):token(1)})};
  }});
  const source=await P.createClientTaskSource(client),pager=P.createTaskPager({source,pageSize:1});await pager.reload();
  const pending=pager.next();await started.promise;pager.dispose();gate.resolve();await pending;
  assert.equal(pager.snapshot().phase,"closed");await assert.rejects(client.listJobsPage({pageSize:1,cursor:token(2)}),code("denied"));await source.close();
});
test("repeated fixture reloads release abandoned chains and keep only the current page",async()=>{
  const {source,pager}=await setup();
  for(let i=0;i<150;i++)assert.equal((await pager.reload()).items.length,2);
  pager.dispose();assert.deepEqual(pager.snapshot().items,[]);await source.close();
});

test("page limits bound presentation memory and invalid sizes are refused",async()=>{
  const {api,session,source}=await setup();
  for(let i=0;i<105;i++)await api.submitLabelJob({id:"a-"+String(i).padStart(3,"0"),key:"key-"+i,value:"fixture"},session);
  for(const pageSize of [0,101,null,true])assert.throws(()=>P.createTaskPager({source,pageSize}),code("invalidInput"));
  const pager=P.createTaskPager({source,pageSize:100});assert.equal((await pager.reload()).items.length,100);
  assert.equal((await pager.next()).items.length,10);assert.equal(pager.snapshot().hasNext,false);pager.dispose();
});
test("cross-page regression is rejected and its newly returned capability is discarded",async()=>{
  const discarded=[];let n=0;
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession();
  const source=await P.createFixtureTaskSource({...api,listJobsPage:async()=>rawPage([rawJob("a")],{pageSize:1,nextCursor:token(++n)}),discardJobPage:async cursor=>{discarded.push(cursor);return true;}},session);
  const pager=P.createTaskPager({source,pageSize:1});await pager.reload();await assert.rejects(pager.next(),code("invalidResponse"));
  assert.equal(pager.snapshot().requiresReload,true);assert.ok(discarded.includes(token(2)));assert.equal(pager.snapshot().items[0].id,"a");
});
test("a disposed mutation never repopulates a closed page, even when its write committed",async()=>{
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(),gate=deferred(),started=deferred();
  const source=await P.createFixtureTaskSource({...api,cancelJob:async(...args)=>{const result=await api.cancelJob(...args);started.resolve();await gate.promise;return result;}},session),pager=P.createTaskPager({source,pageSize:3});
  await pager.reload();const pending=pager.cancelJob("demo-hash");await started.promise;pager.dispose();gate.resolve();await pending;
  assert.equal(pager.snapshot().phase,"closed");assert.deepEqual(pager.snapshot().items,[]);
  assert.equal((await api.listJobs(session)).find(x=>x.id==="demo-hash").state,"cancelled");
});
