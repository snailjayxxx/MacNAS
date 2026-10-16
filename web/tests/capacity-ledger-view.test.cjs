"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const V=require("../dist/capacity-ledger-view.js"),M=require("../dist/model.js");
const scopeID="70000000-0000-4000-8000-000000000001",ownerUserID="fixture-owner",sourceID="c".repeat(64),scope={scopeID,ownerUserID,sourceID};
const uuid=n=>"10000000-0000-4000-8000-"+n.toString(16).padStart(12,"0"),hash="a".repeat(64),limitBytes=64*1024*1024;
const row=(n=1,patch={})=>({allocationID:uuid(n),origin:"upload",intentSHA256:hash,declaredBytes:4,state:"reserved",revision:1,sha256:null,...patch});
const state=(n,s,bytes=4)=>row(n,{state:s,declaredBytes:bytes,revision:{reserved:1,armed:2,owned:3,cancelled:2}[s],sha256:s==="owned"?hash:null});
function dto(items=[]){return{listVersion:1,scopeID,sourceID,ownerUserHex:Buffer.from(ownerUserID).toString("hex"),evidence:"ledgerOnly",limitBytes,totals:{reservedBytes:items.filter(r=>r.state==="reserved").reduce((n,r)=>n+r.declaredBytes,0),unresolvedBytes:items.filter(r=>r.state==="armed").reduce((n,r)=>n+r.declaredBytes,0),ownedBytes:items.filter(r=>r.state==="owned").reduce((n,r)=>n+r.declaredBytes,0),allocatedBytes:items.filter(r=>r.state!=="cancelled").reduce((n,r)=>n+r.declaredBytes,0),historyCount:items.length,unresolvedCount:items.filter(r=>r.state==="armed").length},items};}
const bad=fn=>assert.throws(fn,e=>e?.code==="invalidResponse");
const error=code=>e=>e?.code===code;
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};

test("empty and every valid state produce deeply immutable ledger-only snapshots",()=>{
  const raw=dto([state(1,"reserved"),state(2,"armed"),state(3,"owned"),state(4,"cancelled")]),value=V.listSnapshot(raw,scope);
  assert.deepEqual(value,raw);for(const p of [value,value.items,value.totals,...value.items])assert.ok(Object.isFrozen(p));
  raw.items[0].declaredBytes=3;assert.equal(value.items[0].declaredBytes,4);assert.equal(V.listSnapshot(dto(),scope).items.length,0);
});
test("unknown missing inherited symbol and accessor fields are refused without invoking getters",()=>{
  for(const make of [()=>({...dto(),path:"/unapproved"}),()=>{const p=dto();delete p.totals;return p;},()=>Object.assign(Object.create({inherited:true}),dto()),()=>({...dto(),[Symbol("extra")]:1})])bad(()=>V.listSnapshot(make(),scope));
  let calls=0;for(const area of ["body","totals","row","array"]){const p=dto([row()]);const object=area==="body"?p:area==="totals"?p.totals:area==="row"?p.items[0]:p.items;const key=area==="body"?"scopeID":area==="totals"?"allocatedBytes":area==="row"?"state":"0";Object.defineProperty(object,key,{enumerable:true,get(){calls++;return null;}});bad(()=>V.listSnapshot(p,scope));}assert.equal(calls,0);
});
test("arrays reject holes extras symbols and subclasses",()=>{
  const a=[row()];a.extra=true;const b=[row()];b[Symbol("x")]=1;const c=new Array(1);const d=new(class extends Array{})(row());
  for(const items of [a,b,c,d,{0:row(),length:1}])bad(()=>V.listSnapshot({...dto(),items},scope));
});
test("scope and raw UTF8 subject are captured exactly",()=>{
  const p=dto();p.ownerUserHex=Buffer.from("é").toString("hex");assert.ok(V.listSnapshot(p,{scopeID,sourceID,ownerUserID:"é"}));bad(()=>V.listSnapshot(p,{scopeID,sourceID,ownerUserID:"e\u0301"}));
  bad(()=>V.listSnapshot({...dto(),scopeID:uuid(8)},scope));bad(()=>V.listSnapshot({...dto(),ownerUserHex:"00"},scope));
  for(const ownerUserID of ["","a\0b","a\nb","\ud800","界".repeat(43)])assert.throws(()=>V.listSnapshot(dto(),{scopeID,sourceID,ownerUserID}),error("invalidInput"));
});
test("canonical sorted UUIDs enforce one complete unique history",()=>{
  bad(()=>V.listSnapshot(dto([row(2),row(1)]),scope));bad(()=>V.listSnapshot(dto([row(1),row(1)]),scope));
  for(const allocationID of ["not-uuid",uuid(10).toUpperCase(),"",null])bad(()=>V.listSnapshot(dto([row(1,{allocationID})]),scope));
});
test("state revision origin and hash vocabulary are closed",()=>{
  for(const patch of [{origin:"initial"},{origin:"move"},{state:"deleted"},{revision:2},{sha256:hash},{intentSHA256:"A".repeat(64)},{intentSHA256:hash.slice(1)}])bad(()=>V.listSnapshot(dto([row(1,patch)]),scope));
  for(const s of ["armed","owned","cancelled"]){const p=state(1,s);bad(()=>V.listSnapshot(dto([{...p,revision:1}]),scope));}
  bad(()=>V.listSnapshot(dto([{...state(1,"owned"),sha256:null}]),scope));
});
test("all numeric fields reject booleans fractions unsafe and nonfinite values",()=>{
  for(const n of [true,-1,0.5,NaN,Infinity,Number.MAX_SAFE_INTEGER+1]){
    bad(()=>V.listSnapshot(dto([row(1,{declaredBytes:n})]),scope));
    const p=dto();p.totals.historyCount=n;bad(()=>V.listSnapshot(p,scope));
  }
  bad(()=>V.listSnapshot(dto([row(1,{declaredBytes:16777217})]),scope));
});
test("all six totals must equal the visible complete ledger records",()=>{
  const p=dto([state(1,"reserved"),state(2,"armed"),state(3,"owned"),state(4,"cancelled")]);
  for(const key of Object.keys(p.totals)){const q=structuredClone(p);q.totals[key]++;bad(()=>V.listSnapshot(q,scope));}
});
test("zero exact16MiB and exact64MiB preserve charge including zero-byte uncertainty",()=>{
  const p=dto([state(1,"owned",16777216),state(2,"owned",16777216),state(3,"owned",16777216),state(4,"reserved",16777216),state(5,"armed",0)]);
  assert.equal(V.listSnapshot(p,scope).totals.allocatedBytes,limitBytes);assert.equal(V.summarize(p,scope).admissionBlockedByArmed,true);
  bad(()=>V.listSnapshot(dto([...p.items,row(6,{declaredBytes:1})]),scope));
});
test("64 cancelled zero-byte histories are finite and65 are refused",()=>{
  const items=Array.from({length:64},(_,n)=>state(n+1,"cancelled",0));assert.equal(V.listSnapshot(dto(items),scope).totals.historyCount,64);
  bad(()=>V.listSnapshot(dto([...items,state(65,"cancelled",0)]),scope));
});
test("zero-byte active records still consume the eight admission slots",()=>{
  const items=Array.from({length:8},(_,n)=>state(n+1,n%2?"armed":"reserved",0));assert.ok(V.listSnapshot(dto(items),scope));bad(()=>V.listSnapshot(dto([...items,state(9,"reserved",0)]),scope));
});
test("ledger evidence never becomes filesystem proof free-space or execution authority",()=>{
  const p=dto([state(1,"owned")]),value=V.summarize(p,scope);assert.equal(value.filesystemVerified,false);assert.equal(value.executionAuthorized,false);assert.equal(value.ownedBytes,4);assert.equal(value.freeBytes,undefined);
  bad(()=>V.listSnapshot({...p,evidence:"matchedFiles"},scope));bad(()=>V.listSnapshot({...p,freeBytes:limitBytes-4},scope));bad(()=>V.listSnapshot({...p,limitBytes:limitBytes+1},scope));
});
test("model has no implicit read close cancel or mutation and only one explicit refresh",async()=>{
  let calls=0;const model=V.createReadOnlyModel({...scope,read:async id=>{calls++;assert.equal(id,scopeID);return dto();}});assert.equal(calls,0);assert.deepEqual(Object.keys(model).sort(),["dispose","refresh","snapshot"]);
  await model.refresh();assert.equal(calls,1);assert.equal(model.snapshot().phase,"ready");model.dispose();await assert.rejects(model.refresh(),error("unavailable"));assert.equal(calls,1);
});
test("concurrent refresh is rejected before a second read",async()=>{
  let calls=0;const gate=deferred(),model=V.createReadOnlyModel({...scope,read:()=>{calls++;return gate.promise;}}),pending=model.refresh();await assert.rejects(model.refresh(),error("busy"));assert.equal(calls,1);gate.resolve(dto());await pending;
});
test("failed refresh keeps prior data visibly stale and sanitizes errors without retry",async()=>{
  let calls=0;const model=V.createReadOnlyModel({...scope,read:async()=>{if(++calls===1)return dto([row()]);throw Error("private path");}});await model.refresh();const prior=model.snapshot().list;await assert.rejects(model.refresh(),error("unavailable"));assert.equal(model.snapshot().list,prior);assert.equal(model.snapshot().stale,true);assert.equal(model.snapshot().busy,false);assert.equal(calls,2);
});
test("unarmed cancellation and skipped intermediate owned transition are allowed",async()=>{
  let n=0;const p=[dto([row(1),row(2)]),dto([state(1,"cancelled"),state(2,"owned")])],model=V.createReadOnlyModel({...scope,read:async()=>p[n++]});await model.refresh();await model.refresh();assert.equal(model.snapshot().list.totals.ownedBytes,4);assert.equal(model.snapshot().list.totals.reservedBytes,0);
});
test("same-id declaration changes and history loss are refused without losing prior snapshot",async()=>{
  for(const changed of [dto(),dto([row(1,{origin:"copy"})]),dto([row(1,{declaredBytes:5})]),dto([row(1,{intentSHA256:"b".repeat(64)})])]){let n=0;const model=V.createReadOnlyModel({...scope,read:async()=>n++?changed:dto([row()])});await model.refresh();const prior=model.snapshot().list;await assert.rejects(model.refresh(),error("invalidResponse"));assert.equal(model.snapshot().list,prior);assert.equal(model.snapshot().stale,true);}
});
test("armed cannot become cancelled and terminal records cannot resurrect or change hash",async()=>{
  for(const [before,after]of [[state(1,"armed"),state(1,"cancelled")],[state(1,"owned"),state(1,"reserved")],[state(1,"cancelled"),state(1,"owned")],[state(1,"owned"),{...state(1,"owned"),sha256:"b".repeat(64)}]]){let n=0;const model=V.createReadOnlyModel({...scope,read:async()=>dto([n++?after:before])});await model.refresh();await assert.rejects(model.refresh(),error("invalidResponse"));}
});
test("disposed pending successes and errors never replace the closed view or invoke raw getters",async()=>{
  for(const rejects of [false,true]){const gate=deferred();let changes=0,calls=0;const model=V.createReadOnlyModel({...scope,read:()=>gate.promise,onChange:()=>changes++}),pending=model.refresh();model.dispose();const closed=model.snapshot(),count=changes;const raw={};Object.defineProperty(raw,"listVersion",{get(){calls++;throw Error("late");}});if(rejects)gate.reject(Error("late private path"));else gate.resolve(raw);await pending;assert.equal(model.snapshot(),closed);assert.equal(changes,count);assert.equal(calls,0);}
});
test("dispose from the reading callback prevents the unissued source read",async()=>{
  let reads=0,model;model=V.createReadOnlyModel({...scope,read:async()=>{reads++;return dto();},onChange:value=>{if(value.phase==="reading")model.dispose();}});await model.refresh();assert.equal(reads,0);assert.equal(model.snapshot().phase,"closed");
});
test("callback exceptions do not strand the model in busy state",async()=>{
  const model=V.createReadOnlyModel({...scope,read:async()=>dto(),onChange:()=>{throw Error("view callback");}});await model.refresh();assert.equal(model.snapshot().phase,"ready");assert.equal(model.snapshot().busy,false);await model.refresh();
});
test("known service errors remain finite codes while arbitrary messages do not escape",async()=>{
  const model=V.createReadOnlyModel({...scope,read:async()=>{throw new M.ServiceError("denied","secret");}});await assert.rejects(model.refresh(),error("denied"));assert.equal(model.snapshot().error,"denied");assert.equal(model.snapshot().list,null);
});

test("unbound ledger data must not be accepted as a current host source",()=>{
  // A persistent scope UUID and owner do not identify the current API/session.
  assert.throws(()=>V.listSnapshot(dto(),{scopeID,ownerUserID}),error("invalidInput"));
});
test("closing a model clears the previous owner's ledger from every current snapshot",async()=>{
  const model=V.createReadOnlyModel({...scope,read:async()=>dto([state(1,"owned")])});
  await model.refresh();model.dispose();
  assert.equal(model.snapshot().list,null);assert.equal(model.snapshot().error,null);
  assert.equal(model.snapshot().stale,false);
});

test("source marker is exact lower-case hex and cannot cross API/session bindings",()=>{
  for(const sourceID of ["",null,"C".repeat(64),"c".repeat(63)])
    assert.throws(()=>V.listSnapshot(dto(),{...scope,sourceID}),error("invalidInput"));
  for(const sourceID of ["b".repeat(64),"",null,"C".repeat(64)])
    bad(()=>V.listSnapshot({...dto(),sourceID},scope));
  const p=dto();delete p.sourceID;bad(()=>V.listSnapshot(p,scope));
});
test("a changed source never overwrites the current list and creates no new approval",async()=>{
  let reads=0;const model=V.createReadOnlyModel({...scope,read:async()=>({...dto([row()]),sourceID:++reads===1?sourceID:"b".repeat(64)})});
  await model.refresh();const previous=model.snapshot().list;
  await assert.rejects(model.refresh(),error("invalidResponse"));
  assert.equal(model.snapshot().list,previous);assert.equal(model.snapshot().stale,true);
  assert.equal(reads,2);model.dispose();assert.equal(model.snapshot().list,null);
});
