"use strict";
// Real pipe -> Swift -> private PostgreSQL integration. No browser or network listener.
const {test,before,after}=require("node:test"),assert=require("node:assert/strict");
const {spawn,spawnSync}=require("node:child_process"),{createInterface}=require("node:readline");
const path=require("node:path"),fs=require("node:fs");
const M=require("../web/dist/model.js");
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
