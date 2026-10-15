"use strict";
// Real pipe -> Swift -> private PostgreSQL integration. No browser or network listener.
const {test,before,after}=require("node:test"),assert=require("node:assert/strict");
const {spawn,spawnSync}=require("node:child_process"),{createInterface}=require("node:readline");
const path=require("node:path"),fs=require("node:fs");
const M=require("../web/dist/model.js");
const C=require("../web/dist/bridge-client.js");
const P=require("../web/dist/task-pages.js");
const N=require("../web/dist/notification-view.js");
const F=require("../web/dist/directory-view.js");
const binary=path.join(process.env.MACNAS_BINARY_DIR||"","macnas");
const root=process.env.MACNAS_BRIDGE_TEST_ROOT,readonly=process.env.MACNAS_BRIDGE_READONLY_ROOT;
const hosts=new Set(),errorCode=code=>error=>error instanceof M.ServiceError&&error.code===code;

class PipeHost {
  constructor(source,user="fixture-owner") {
    this.pending=[];this.stderr="";this.unexpected=[];
    this.child=spawn(binary,["bridge","fixture","--source",source,"--user",user],{stdio:["pipe","pipe","pipe"]});
    hosts.add(this);
    this.exit=new Promise(resolve=>this.child.once("close",(code,signal)=>{hosts.delete(this);resolve({code,signal});}));
    this.child.on("error",()=>this.fail(Error("bridge spawn failed")));
    this.child.stdin.on("error",()=>this.fail(Error("bridge stdin failed")));
    this.child.stderr.on("data",data=>{this.stderr=(this.stderr+data.toString("utf8")).slice(0,8192);});
    const lines=createInterface({input:this.child.stdout,crlfDelay:Infinity});
    lines.on("line",line=>{
      const entry=this.pending.shift();
      if(!entry){this.unexpected.push("unexpected output");return;}
      clearTimeout(entry.timer);
      try {assert.ok(Buffer.byteLength(line)<=1048576);entry.resolve(JSON.parse(line));}
      catch {entry.reject(Error("invalid bridge output"));}
    });
    this.exit.then(()=>this.fail(Error("bridge exited before response")));
    this.api=M.createBridgeAdapter(message=>this.raw(JSON.stringify(message)+"\n"));
  }
  fail(error){for(const entry of this.pending.splice(0)){clearTimeout(entry.timer);entry.reject(error);}}
  typed(config={}) {
    return C.createDesktopClient({transport:message=>this.raw(JSON.stringify(message)+"\n"),timeoutMs:20000,closeTransport:()=>this.child.stdin.end(),...config});
  }
  raw(bytes){
    return new Promise((resolve,reject)=>{
      const entry={resolve,reject,timer:setTimeout(()=>{this.fail(Error("bridge response timeout"));this.child.kill("SIGKILL");},20000)};
      this.pending.push(entry);this.child.stdin.write(bytes);
    });
  }
  async finish(expected=0){
    this.child.stdin.end();
    const timer=setTimeout(()=>this.child.kill("SIGKILL"),5000);
    const result=await this.exit;clearTimeout(timer);
    assert.deepEqual(result,{code:expected,signal:null});assert.deepEqual(this.unexpected,[]);
    if(expected===0)assert.equal(this.stderr,"");
    return result;
  }
}
before(()=>{
  assert.ok(root&&readonly&&process.env.MACNAS_PG_SOCKET,"guarded development environment required");
  assert.ok(root.includes("/DeploySandbox/")&&!fs.existsSync(root));
  const result=spawnSync(binary,["fixture","create","--dest",root,"--schema","3"],{encoding:"utf8",timeout:30000,maxBuffer:1048576});
  assert.equal(result.status,0,"synthetic fixture creation failed");
});
after(async()=>{await Promise.all([...hosts].map(async host=>{host.child.kill("SIGKILL");await host.exit;}));});

test("JavaScript client reaches real durable jobs, replay/ACK and persisted restart through Swift pipes",async()=>{
  const host=new PipeHost(root);
  try {
    const overview=await host.api.request("overview");
    assert.equal(overview.source,"fixture-host");assert.equal(overview.physicalPool,"unbound");
    assert.equal(overview.databaseSchema,3);assert.equal(overview.taskTimestampsAvailable,false);
    const value="合成 <script>普通文本</script> 🐚";
    const job=await host.api.request("submitLabelJob",{id:"pipe-job",key:"pipe-key",value});
    assert.equal(job.state,"queued");assert.equal(job.title,value);assert.equal(job.payload,undefined);
    const same=await host.api.request("submitLabelJob",{id:"another-id",key:"pipe-key",value});
    assert.equal(same.id,job.id);
    await assert.rejects(host.api.request("submitLabelJob",{id:"conflict",key:"pipe-key",value:"different"}),errorCode("collision"));
    assert.equal((await host.api.request("cancelJob",{id:job.id})).state,"cancelled");
    const params={consumerID:"pipe-consumer",limit:100},events=await host.api.request("pollEvents",params);
    assert.ok(events.length>=2);assert.deepEqual(await host.api.request("pollEvents",params),events);
    const through=events.at(-1).sequence;assert.ok(Number.isSafeInteger(through));
    await assert.rejects(host.api.request("acknowledgeEvents",{consumerID:params.consumerID,through:through+100}),errorCode("denied"));
    assert.equal(await host.api.request("acknowledgeEvents",{consumerID:params.consumerID,through}),true);
    assert.deepEqual(await host.api.request("pollEvents",params),[]);
  } finally {await host.finish();}
  const restarted=new PipeHost(root);
  try {assert.equal((await restarted.api.request("listJobs")).find(job=>job.id==="pipe-job").state,"cancelled");}
  finally {await restarted.finish();}
});

test("reader is scoped by the host and library metadata never grants file access",async()=>{
  const reader=new PipeHost(root,"fixture-family"),owner=new PipeHost(root);
  try {
    assert.deepEqual(await reader.api.request("listJobs"),[]);
    await assert.rejects(reader.api.request("cancelJob",{id:"pipe-job"}),errorCode("denied"));
    await assert.rejects(reader.api.request("submitLabelJob",{id:"reader",key:"reader",value:"reader"}),errorCode("denied"));
    await assert.rejects(reader.api.request("overview",{role:"administrator"}),errorCode("invalidInput"));
    await assert.rejects(reader.api.request("authorizeApp",{id:"settings"}),errorCode("denied"));
    assert.deepEqual(await reader.api.request("listLibraries"),[]);
    const libraries=await owner.api.request("listLibraries");assert.equal(libraries.length,1);
    assert.equal(libraries[0].state,"missing");assert.equal(libraries[0].relativePath,undefined);
    await assert.rejects(owner.api.request("listFiles",{libraryID:libraries[0].libraryID}),errorCode("missingVolume"));
    await assert.rejects(owner.api.request("listFiles",{libraryID:libraries[0].libraryID,root:"/"}),errorCode("invalidInput"));
    assert.equal(fs.existsSync(path.join(root,"host-binding/fixtures")),false);
  } finally {await Promise.all([reader.finish(),owner.finish()]);}
});

test("restored read-only host permits queries and refuses all mutations",async()=>{
  const host=new PipeHost(readonly);
  try {
    assert.equal((await host.api.request("overview")).mode,"read_only_recovery");
    assert.ok(Array.isArray(await host.api.request("listJobs")));
    for(const [method,params] of [
      ["submitLabelJob",{id:"readonly",key:"readonly",value:"readonly"}],
      ["cancelJob",{id:"anything"}],["pollEvents",{consumerID:"readonly"}],
      ["acknowledgeEvents",{consumerID:"readonly",through:0}]
    ])await assert.rejects(host.api.request(method,params),errorCode("readOnly"));
    assert.equal(fs.existsSync(path.join(readonly,"host-binding/fixtures")),false);
  } finally {await host.finish();}
});

test("NDJSON rejects duplicate keys, replay, oversize and truncated frames with fixed errors",async()=>{
  const host=new PipeHost(root);
  try {
    const duplicate=await host.raw('{"apiVersion":1,"requestId":"duplicate","method":"overview","params":{"role":"a","role":"b"}}\n');
    assert.deepEqual(duplicate,{apiVersion:1,requestId:null,error:{code:"invalidInput"}});
    const message=JSON.stringify({apiVersion:1,requestId:"fragment",method:"authorizeApp",params:{id:"overview"}});
    const waiting=host.raw(message.slice(0,31));
    await new Promise(setImmediate);host.child.stdin.write(message.slice(31)+"\r\n");
    assert.deepEqual(await waiting,{apiVersion:1,requestId:"fragment",data:true});
    assert.equal((await host.raw(message+"\n")).error.code,"replay");
  } finally {await host.finish();}
  const large=new PipeHost(root);
  assert.deepEqual(await large.raw(" ".repeat(65537)),{apiVersion:1,requestId:null,error:{code:"budgetExceeded"}});
  await large.finish(1);assert.equal(large.stderr.trim(),"macnas: budgetExceeded");
  const truncated=new PipeHost(root),reply=truncated.raw('{"apiVersion":1');
  truncated.child.stdin.end();
  assert.deepEqual(await reply,{apiVersion:1,requestId:null,error:{code:"invalidInput"}});
  await truncated.finish(1);assert.equal(truncated.stderr.trim(),"macnas: invalidSchema");
});

test("typed clients validate actual durable DTOs and owner, reader and restored contexts",async()=>{
  const host=new PipeHost(root),client=host.typed();
  try {
    const overview=await client.overview();assert.equal(overview.source,"fixture-host");
    const intent={id:"typed-job",key:"typed-key",value:"真实管道中的合成任务 🐚"};
    assert.equal((await client.submitLabelJob(intent)).id,intent.id);
    assert.equal((await client.submitLabelJob({...intent,id:"typed-retry"})).id,intent.id);
    assert.equal((await client.cancelJob(intent.id)).state,"cancelled");
    assert.ok((await client.listJobs()).some(job=>job.id===intent.id));
    const events=await client.pollEvents("typed-consumer",100);assert.ok(events.length>0);
    assert.equal(await client.acknowledgeEvents("typed-consumer",events.at(-1).sequence),true);
    assert.deepEqual(await client.pollEvents("typed-consumer"),[]);
    const libraries=await client.listLibraries();assert.equal(libraries[0].state,"missing");
    await assert.rejects(client.listFiles({libraryID:libraries[0].libraryID}),errorCode("missingVolume"));
  } finally {client.close();await host.finish();}
  for(const [source,user] of [[root,"fixture-family"],[readonly,"fixture-owner"]]) {
    const host=new PipeHost(source,user),client=host.typed();
    try {
      const info=await client.overview();assert.ok(Array.isArray(await client.listJobs()));
      await assert.rejects(client.submitLabelJob({id:"blocked",key:"blocked",value:"blocked"}),errorCode(info.role==="reader"?"denied":"readOnly"));
      if(info.role==="reader") {
        assert.deepEqual(await client.listLibraries(),[]);
        await assert.rejects(client.authorizeApp("settings"),errorCode("denied"));
      }
    } finally {client.close();await host.finish();}
  }
});

test("a timed-out committed write is recovered with the same durable business key",{timeout:60000},async()=>{
  const host=new PipeHost(root);let sawCommit;
  const committed=new Promise(resolve=>{sawCommit=resolve;});
  const client=host.typed({timeoutMs:10000,transport:async message=>{
    const response=await host.raw(JSON.stringify(message)+"\n");
    if(message.method==="submitLabelJob") {
      assert.equal(response.data.id,"lost-response-job");sawCommit();
      return new Promise(()=>{}); // The actual committed response never reaches the typed client.
    }
    return response;
  }});
  const intent={id:"lost-response-job",key:"lost-response-key",value:"合成响应丢失重试"};
  try {
    await client.overview();const pending=client.submitLabelJob(intent).catch(error=>error);
    await committed;assert.equal((await pending).code,"timedOut");assert.equal(client.closed,true);
  } finally {client.close();await host.finish();}
  const nextHost=new PipeHost(root),next=nextHost.typed();
  try {
    await next.overview();const recovered=await next.submitLabelJob({...intent,id:"new-retry-id"});
    assert.equal(recovered.id,intent.id);assert.equal((await next.listJobs()).filter(job=>job.idempotency_key===intent.key).length,1);
  } finally {next.close();await nextHost.finish();}
});

test("new typed client prefixes prevent replay on a caller-retained host",async()=>{
  const host=new PipeHost(root);
  try {
    for(let i=0;i<2;i++) {
      const client=host.typed({closeTransport:()=>{}});
      assert.equal((await client.overview()).userID,"fixture-owner");client.close();
    }
  } finally {await host.finish();}
});

test("typed task pages traverse actual SQL rows with single-use session-scoped cursors",async()=>{
  const host=new PipeHost(root),client=host.typed(),other=new PipeHost(root),reader=new PipeHost(root,"fixture-family");
  try {
    await client.overview();const expected=await client.listJobs(),seen=[];
    let page=await client.listJobsPage({pageSize:1});
    assert.ok(page.nextCursor);const first=page.nextCursor;
    await assert.rejects(other.api.request("listJobsPage",{pageSize:1,cursor:first}),errorCode("denied"));
    await assert.rejects(reader.api.request("listJobsPage",{pageSize:1,cursor:first}),errorCode("denied"));
    while(true) {
      seen.push(...page.items.map(x=>x.id));
      if(page.nextCursor===null)break;
      page=await client.listJobsPage({pageSize:1,cursor:page.nextCursor});
    }
    assert.deepEqual(seen,expected.map(x=>x.id).sort((a,b)=>Buffer.compare(Buffer.from(a),Buffer.from(b))));
    await assert.rejects(host.api.request("listJobsPage",{pageSize:1,cursor:first}),errorCode("replay"));
    assert.equal((await reader.api.request("listJobsPage")).items.length,0);
  } finally {client.close();await Promise.all([host.finish(),other.finish(),reader.finish()]);}
  const restored=new PipeHost(readonly),query=restored.typed();
  try {await query.overview();assert.ok(Array.isArray((await query.listJobsPage()).items));}
  finally{query.close();await restored.finish();}
});

test("task presentation projects actual host pages and refreshes cancellation in place",async()=>{
  const host=new PipeHost(root),client=host.typed(),source=await P.createClientTaskSource(client),pager=P.createTaskPager({source,pageSize:1});
  try {
    await source.submitLabelJob({id:"a-presented-job",key:"a-presented-key",value:"jobHash"});
    const before=await source.overview(),first=await pager.reload();
    assert.equal(first.items[0].id,"a-presented-job");assert.equal(first.items[0].updated,undefined);
    assert.equal(P.taskName(first.items[0],()=>{throw Error("plain host title must not be translated");}),"jobHash");
    const cancelled=await pager.cancelJob(first.items[0].id);
    assert.equal(cancelled.pageNumber,1);assert.equal(cancelled.items[0].state,"cancelled");
    assert.equal((await source.overview()).active,before.active-1);
    while(pager.snapshot().hasNext){const view=await pager.next();assert.ok(view.items.length<=1);}
    pager.dispose();assert.deepEqual(pager.snapshot().items,[]);assert.equal(client.closed,false);
  } finally {pager.dispose();await source.close();await host.finish();}
  for(const [target,user] of [[root,"fixture-family"],[readonly,"fixture-owner"]]) {
    const host=new PipeHost(target,user),source=await P.createClientTaskSource(host.typed()),pager=P.createTaskPager({source,pageSize:1});
    try {
      const view=await pager.reload();assert.ok(view.items.length<=1);
      await assert.rejects(source.submitLabelJob({id:"blocked-view",key:"blocked-view",value:"x"}),errorCode(source.context.role==="reader"?"denied":"readOnly"));
      if(source.context.role==="reader")assert.equal(view.items.length,0);
    } finally {pager.dispose();await source.close();await host.finish();}
  }
});

test("bounded notification presentation retries a committed ACK with withheld success at the same delivered position",async()=>{
  const host=new PipeHost(root),throughs=[];let withheld=true;
  const client=host.typed({transport:async message=>{
    const response=await host.raw(JSON.stringify(message)+"\n");
    if(message.method==="acknowledgeEvents") {
      throughs.push(message.params.through);assert.equal(response.data,true);
      if(withheld){withheld=false;return {apiVersion:1,requestId:message.requestId,error:{code:"database"}};}
    }
    return response;
  }}),view=await N.createClientNotificationView(client,{consumerID:"presentation-ack",capacity:2});
  try {
    const batch=await view.poll();assert.equal(batch.items.length,2);assert.equal(batch.full,true);
    await assert.rejects(view.poll(),errorCode("budgetExceeded"));
    await assert.rejects(view.acknowledge(),errorCode("database"));
    assert.deepEqual(view.snapshot().items,batch.items);assert.equal(view.snapshot().confirmedThrough,0);
    const durable=await host.api.request("pollEvents",{consumerID:"presentation-ack",limit:2});
    assert.ok(durable.every(event=>event.sequence>batch.items[0].sequence));
    await assert.rejects(view.poll(),errorCode("staleState"));
    await view.acknowledge();assert.deepEqual(throughs,[batch.items[0].sequence,batch.items[0].sequence]);
    assert.deepEqual(view.snapshot().items,[]);
    const next=await view.poll();assert.ok(next.items.every(event=>event.sequence>batch.items[0].sequence));
    if(next.items.length)await view.acknowledge();
  } finally {view.dispose();client.close();await host.finish();}
  for(const [target,user] of [[root,"fixture-family"],[readonly,"fixture-owner"]]) {
    const host=new PipeHost(target,user),client=host.typed(),view=await N.createClientNotificationView(client,{consumerID:"notification-scope"});
    try {
      if(view.context.mode!=="synthetic_development")await assert.rejects(view.poll(),errorCode("readOnly"));
      else {assert.deepEqual((await view.poll()).items,[]);await assert.rejects(view.acknowledge(),errorCode("denied"));}
      assert.equal(view.snapshot().confirmedThrough,0);
    } finally {view.dispose();client.close();await host.finish();}
  }
});

test("committed notification ACK timeout keeps the old batch unresolved even when a restarted host proves durable advancement",async()=>{
  const host=new PipeHost(root);let committedResolve,lateResolve;
  const committed=new Promise(resolve=>{committedResolve=resolve;}),late=new Promise(resolve=>{lateResolve=resolve;});
  const client=host.typed({timeoutMs:10000,transport:async message=>{
    const response=await host.raw(JSON.stringify(message)+"\n");
    if(message.method==="acknowledgeEvents"){assert.equal(response.data,true);committedResolve();await late;}
    return response;
  }}),view=await N.createClientNotificationView(client,{consumerID:"presentation-timeout"});
  let batch;
  try {
    batch=await view.poll();assert.ok(batch.items.length>0);
    const pending=view.acknowledge(),rejected=assert.rejects(pending,errorCode("timedOut"));
    await committed;await rejected;
    assert.equal(client.closed,true);assert.deepEqual(view.snapshot().items,batch.items);
    assert.equal(view.snapshot().confirmedThrough,0);assert.equal(view.snapshot().unavailable,true);
    lateResolve();await Promise.resolve();await assert.rejects(view.acknowledge(),errorCode("unavailable"));
  } finally {lateResolve();client.close();await host.finish();}
  const restarted=new PipeHost(root);
  try {
    assert.deepEqual(await restarted.api.request("pollEvents",{consumerID:"presentation-timeout",limit:100}),[]);
    assert.deepEqual(view.snapshot().items,batch.items);assert.equal(view.snapshot().confirmedThrough,0);
  } finally {view.dispose();await restarted.finish();}
});

test("directory presentation preserves actual metadata and missing-volume authority while borrowing the shared client",async()=>{
  const host=new PipeHost(root),client=host.typed(),source=await F.createClientDirectorySource(client),pager=F.createDirectoryPager({source,pageSize:3});
  try {
    const libraries=await source.libraries();assert.equal(libraries.length,1);assert.equal(libraries[0].state,"missing");
    assert.equal(libraries[0].root,undefined);assert.ok(Number.isSafeInteger(libraries[0].estimatedBytes));
    await assert.rejects(pager.open({libraryID:libraries[0].libraryID}),errorCode("missingVolume"));
    assert.equal(pager.snapshot().requiresReload,true);assert.equal(pager.snapshot().hasNext,false);
    await assert.rejects(source.preview({libraryID:libraries[0].libraryID,relativePath:"README.txt"}),errorCode("missingVolume"));
    pager.dispose();source.dispose();assert.equal(client.closed,false);assert.ok(Array.isArray((await client.listJobsPage({pageSize:1})).items));
    assert.equal(fs.existsSync(path.join(root,"host-binding/fixtures")),false);
  } finally {pager.dispose();source.dispose();client.close();await host.finish();}
});
