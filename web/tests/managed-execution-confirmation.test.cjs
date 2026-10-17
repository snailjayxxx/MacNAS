"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const X=require("../dist/managed-execution-confirmation.js"),M=require("../dist/model.js");
const scopeID="aaaaaaaa-0000-4000-8000-000000000001",allocationID="bbbbbbbb-0000-4000-8000-000000000002",previewID="cccccccc-0000-4000-8000-000000000003",operationID="dddddddd-0000-4000-8000-000000000004",entryID="eeeeeeee-0000-4000-8000-000000000005";
const binding=patch=>({scopeID,sourceID:"d".repeat(64),ownerUserID:"fixture-owner",mode:"synthetic_development",...patch});
const intent=patch=>({kind:"recycle",allocationID,entryID:null,declaredBytes:4,allocationIntentSHA256:"b".repeat(64),sha256:"a".repeat(64),...patch});
const context=patch=>({executionContextVersion:1,source:"fixture-host",purpose:"managed-execution",scopeID,sourceID:binding().sourceID,userID:"fixture-owner",role:"administrator",mode:"synthetic_development",...patch});
const preview=patch=>({previewVersion:1,context:context(),previewID,operationID,entryID,kind:"recycle",allocationID,declaredBytes:4,allocationIntentSHA256:"b".repeat(64),operationIntentSHA256:"c".repeat(64),sha256:"a".repeat(64),expiresAfterMilliseconds:60000,confirmationRequired:true,...patch});
const result=patch=>({resultVersion:1,context:context(),previewID,operationID,entryID,kind:"recycle",allocationID,operationIntentSHA256:"c".repeat(64),state:"completed",...patch});
const code=c=>e=>e instanceof M.ServiceError&&e.code===c;
const gate=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
const model=(patch={})=>X.createConfirmationModel({...binding(),intent:intent(),prepare:async()=>preview(),confirm:async()=>result(),now:()=>10,...patch});
const clone=x=>JSON.parse(JSON.stringify(x));

test("MOCK creation has no preview confirmation clock or filesystem capability effects",()=>{
 let prepares=0,confirms=0,times=0;const m=model({prepare(){prepares++;},confirm(){confirms++;},now(){times++;return 0;}});
 assert.deepEqual(Object.keys(m).sort(),["confirmPreview","discardPreview","dispose","preparePreview","snapshot"]);
 assert.equal(prepares+confirms+times,0);for(const k of ["filesystemVerified","executionAuthorized","capacityReleaseAuthorized"])assert.equal(m.snapshot()[k],false);m.dispose();assert.equal(prepares+confirms+times,0);
});
test("MOCK explicit preview sends selected intent once and never confirms automatically",async()=>{
 const calls=[],m=model({prepare:async p=>{calls.push(p);return preview();},confirm:async()=>{throw Error("unexpected confirmation");}});await m.preparePreview();
 assert.deepEqual(calls,[{scopeID,sourceID:binding().sourceID,...intent()}]);assert.equal(Object.isFrozen(calls[0]),true);assert.equal(m.snapshot().phase,"ready");assert.equal(m.snapshot().confirmationDispatched,false);m.discardPreview();assert.equal(calls.length,1);m.dispose();
});
test("MOCK preview requires exact own data fields without getters symbols or hidden capabilities",()=>{
 let gets=0;for(const change of [v=>v.path="/private",v=>delete v.operationID,v=>v[Symbol("extra")]=1,v=>Object.defineProperty(v,"sha256",{enumerable:true,get(){gets++;return "a".repeat(64);}}),v=>v.context=Object.create(v.context),v=>v.confirmationRequired=false]){
  const p=preview();change(p);assert.throws(()=>X.previewSnapshot(p,binding(),intent()),code("invalidResponse"));
 }assert.equal(gets,0);
});
test("MOCK an observation or ledger context cannot stand in for execution context",()=>{
 const p=preview({context:{contextVersion:1,source:"fixture-host",scopeID,sourceID:binding().sourceID,userID:"fixture-owner",role:"administrator",mode:"synthetic_development"}});
 assert.throws(()=>X.previewSnapshot(p,binding(),intent()),code("invalidResponse"));
 for(const patch of [{purpose:"managed-observation"},{executionContextVersion:2},{role:"reader"},{source:"fixture"}])assert.throws(()=>X.previewSnapshot(preview({context:context(patch)}),binding(),intent()),code("invalidResponse"));
});
test("MOCK scope source raw owner and mode are fixed and never inferred from response",()=>{
 for(const patch of [{scopeID:entryID},{sourceID:"e".repeat(64)},{userID:"other"},{mode:"read_only_recovery"}])assert.throws(()=>X.previewSnapshot(preview({context:context(patch)}),binding(),intent()),code("invalidResponse"));
 for(const patch of [{sourceID:undefined},{scopeID:scopeID.toUpperCase()},{ownerUserID:"owner\n"},{ownerUserID:"\ud800"},{ownerUserID:"a".repeat(129)},{extra:true}])assert.throws(()=>X.previewSnapshot(preview(),binding(patch),intent()),code("invalidInput"));
 const p=preview({context:context({userID:"é"})});assert.throws(()=>X.previewSnapshot(p,binding({ownerUserID:"e\u0301"}),intent()),code("invalidResponse"));
});
test("MOCK preview exactly echoes allocation declaration sha kind and selected restore entry",()=>{
 for(const patch of [{allocationID:entryID},{declaredBytes:0},{sha256:"e".repeat(64)},{allocationIntentSHA256:"e".repeat(64)},{kind:"restore"}])assert.throws(()=>X.previewSnapshot(preview(patch),binding(),intent()),code("invalidResponse"));
 for(const bytes of [0,16777216])assert.equal(X.previewSnapshot(preview({declaredBytes:bytes}),binding(),intent({declaredBytes:bytes})).declaredBytes,bytes);
 for(const patch of [{kind:"purge"},{declaredBytes:-1},{declaredBytes:16777217},{entryID},{sha256:null}])assert.throws(()=>X.previewSnapshot(preview(),binding(),intent(patch)),code("invalidInput"));
});
test("MOCK restore pins known entry while recycle receives a new host entry",()=>{
 const selected=intent({kind:"restore",entryID}),p=preview({kind:"restore"});assert.equal(X.previewSnapshot(p,binding(),selected).entryID,entryID);
 assert.throws(()=>X.previewSnapshot(preview({kind:"restore",entryID:allocationID}),binding(),selected),code("invalidResponse"));
 assert.equal(X.previewSnapshot(preview(),binding(),intent()).entryID,entryID);
});
test("MOCK proposed preview lifetime is bounded to one through60000milliseconds",()=>{
 for(const ttl of [1,60000])assert.equal(X.previewSnapshot(preview({expiresAfterMilliseconds:ttl}),binding(),intent()).expiresAfterMilliseconds,ttl);
 for(const ttl of [0,-1,60001,1.5,Infinity,"60000"])assert.throws(()=>X.previewSnapshot(preview({expiresAfterMilliseconds:ttl}),binding(),intent()),code("invalidResponse"));
});
test("MOCK result must retain preview operation entry allocation kind context and intent",()=>{
 for(const patch of [{previewID:allocationID},{operationID:allocationID},{entryID:allocationID},{allocationID:entryID},{kind:"restore"},{operationIntentSHA256:"e".repeat(64)},{context:context({sourceID:"e".repeat(64)})},{state:"released"},{capacityReleased:true}])assert.throws(()=>X.resultSnapshot(result(patch),preview(),binding(),intent()),code("invalidResponse"));
 for(const state of ["completed","uncertain"])assert.equal(X.resultSnapshot(result({state}),preview(),binding(),intent()).state,state);
});
test("MOCK one in-flight preview rejects reentry without a second callback",async()=>{
 const d=gate();let calls=0;const m=model({prepare:()=>{calls++;return d.promise;}}),pending=m.preparePreview();await assert.rejects(m.preparePreview(),code("busy"));assert.equal(calls,1);d.resolve(preview());await pending;await assert.rejects(m.preparePreview(),code("busy"));m.dispose();
});
test("MOCK confirmation requires exact owned previewID and explicit booleantrue",async()=>{
 let sends=0;const m=model({confirm:async()=>{sends++;return result();}});await m.preparePreview();
 for(const p of [{previewID,confirmed:false},{previewID,confirmed:"true"},{previewID},{previewID,confirmed:true,automatic:true},Object.defineProperty({previewID},"confirmed",{enumerable:true,get(){throw Error("getter");}})])await assert.rejects(m.confirmPreview(p),code("invalidInput"));
 await assert.rejects(m.confirmPreview({previewID:allocationID,confirmed:true}),code("denied"));assert.equal(sends,0);m.dispose();
});
test("MOCK exact confirmation parameters are emitted once after explicit action",async()=>{
 const calls=[],m=model({confirm:async p=>{calls.push(p);return result();}});await m.preparePreview();assert.equal(calls.length,0);await m.confirmPreview({previewID,confirmed:true});
 assert.deepEqual(calls,[{scopeID,sourceID:binding().sourceID,previewID,confirmed:true}]);assert.equal(Object.isFrozen(calls[0]),true);assert.equal(m.snapshot().phase,"completed");assert.equal(m.snapshot().confirmationDispatched,true);for(const k of ["filesystemVerified","executionAuthorized","capacityReleaseAuthorized"])assert.equal(m.snapshot()[k],false);m.dispose();
});
test("MOCK confirmation is consumed at dispatch and cannot retry or prepare another action",async()=>{
 const d=gate();let calls=0;const m=model({confirm:()=>{calls++;return d.promise;}});await m.preparePreview();const pending=m.confirmPreview({previewID,confirmed:true});
 assert.equal(m.snapshot().confirmationDispatched,true);await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("busy"));d.resolve(result());await pending;
 await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("replay"));await assert.rejects(m.preparePreview(),code("replay"));assert.throws(()=>m.discardPreview(),code("replay"));assert.equal(calls,1);m.dispose();
});
test("MOCK local expiry at the exact boundary prevents confirmation transport",async()=>{
 let now=10,sends=0;const m=model({now:()=>now,prepare:async()=>preview({expiresAfterMilliseconds:100}),confirm:async()=>{sends++;return result();}});await m.preparePreview();now=110;
 await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("expired"));assert.equal(sends,0);assert.equal(m.snapshot().preview,null);assert.equal(m.snapshot().confirmationDispatched,false);m.dispose();
});
test("MOCK preview lifetime starts at request time and cannot be extended by a delayed reply",async()=>{
 let now=10,sends=0;const m=model({now:()=>now,prepare:async()=>{now=110;return preview({expiresAfterMilliseconds:100});},confirm:async()=>{sends++;return result();}});
 await assert.rejects(m.preparePreview(),code("expired"));assert.equal(m.snapshot().preview,null);assert.equal(sends,0);m.dispose();
});
test("MOCK fractional monotonic clocks work and backward or invalid clocks cannot confirm",async()=>{
 let now=10.5,sends=0;const m=model({now:()=>now,confirm:async()=>{sends++;return result();}});await m.preparePreview();now=9;await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("unavailable"));assert.equal(sends,0);now=11.5;await m.confirmPreview({previewID,confirmed:true});assert.equal(sends,1);m.dispose();
 for(const v of [NaN,Infinity,-1,Number.MAX_SAFE_INTEGER+1]){let prepares=0;const n=model({now:()=>v,prepare:async()=>{prepares++;return preview();}});await assert.rejects(n.preparePreview(),code("unavailable"));assert.equal(prepares,0);assert.equal(n.snapshot().busy,false);n.dispose();}
});
test("MOCK a completion arriving after deadline remains a reported result after timely dispatch",async()=>{
 let now=0;const d=gate(),m=model({now:()=>now,prepare:async()=>preview({expiresAfterMilliseconds:1}),confirm:()=>d.promise});await m.preparePreview();const pending=m.confirmPreview({previewID,confirmed:true});now=1000;d.resolve(result());await pending;assert.equal(m.snapshot().phase,"completed");assert.equal(m.snapshot().requiresReview,false);m.dispose();
});
test("MOCK all post-dispatch errors remain uncertain and cannot automatically retry",async()=>{
 for(const failure of ["denied","expired","staleState","timedOut","cancelled","unavailable"]){let sends=0;const m=model({confirm:async()=>{sends++;throw new M.ServiceError(failure);}});await m.preparePreview();await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code(failure));
  assert.equal(m.snapshot().phase,"uncertain");assert.equal(m.snapshot().requiresReview,true);assert.equal(m.snapshot().stale,true);assert.equal(m.snapshot().preview.previewID,previewID);await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("replay"));await assert.rejects(m.preparePreview(),code("replay"));assert.equal(sends,1);m.dispose();
 }
});
test("MOCK malformed confirmation result is uncertain with fixed preview retained",async()=>{
 const m=model({confirm:async()=>result({operationID:allocationID})});await m.preparePreview();await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("invalidResponse"));assert.equal(m.snapshot().phase,"uncertain");assert.equal(m.snapshot().result,null);assert.equal(m.snapshot().preview.operationID,operationID);assert.equal(m.snapshot().confirmationDispatched,true);m.dispose();
});
test("MOCK unknown errors and code getters do not become visible error messages",async()=>{
 let gets=0;const poison=new M.ServiceError("denied");Object.defineProperty(poison,"code",{get(){gets++;throw Error("private");}});
 for(const failure of [poison,new Error("private SQL path"),{code:"denied",message:"private"}]){const m=model({confirm:async()=>{throw failure;}});await m.preparePreview();await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("unavailable"));assert.equal(m.snapshot().error,"unavailable");assert.equal(Object.hasOwn(m.snapshot(),"message"),false);m.dispose();}assert.equal(gets,0);
});
test("MOCK dispose clears prior subject and ignores late preview data getters",async()=>{
 const d=gate();let gets=0;const m=model({prepare:()=>d.promise}),pending=m.preparePreview();m.dispose();d.resolve(Object.defineProperty({},"context",{get(){gets++;throw Error("late");}}));await pending;
 assert.equal(gets,0);assert.equal(m.snapshot().phase,"closed");assert.equal(m.snapshot().preview,null);assert.equal(m.snapshot().result,null);await assert.rejects(m.preparePreview(),code("unavailable"));
});
test("MOCK dispose ignores late preview errors without inspecting their properties",async()=>{
 const d=gate();let gets=0;const m=model({prepare:()=>d.promise}),pending=m.preparePreview();m.dispose();d.reject(Object.defineProperty({},"code",{get(){gets++;throw Error("late");}}));await pending;assert.equal(gets,0);assert.equal(m.snapshot().error,null);assert.equal(m.snapshot().busy,false);
});
test("MOCK dispose ignores late confirmation result or failure and cannot undo a callback",async()=>{
 for(const failure of [false,true]){const d=gate();let sends=0,gets=0;const m=model({confirm:()=>{sends++;return d.promise;}});await m.preparePreview();const pending=m.confirmPreview({previewID,confirmed:true});m.dispose();const late=Object.defineProperty({},failure?"code":"context",{get(){gets++;throw Error("late");}});if(failure)d.reject(late);else d.resolve(late);await pending;
  assert.equal(sends,1);assert.equal(gets,0);assert.equal(m.snapshot().phase,"closed");assert.equal(m.snapshot().preview,null);assert.equal(m.snapshot().result,null);assert.equal(m.snapshot().confirmationDispatched,false);assert.equal(m.snapshot().requiresReview,false);
 }
});
test("MOCK preparing or confirming callbacks may dispose before any corresponding callback is sent",async()=>{
 for(const phase of ["preparing","confirming"]){let prepares=0,confirms=0,m;m=model({prepare:async()=>{prepares++;return preview();},confirm:async()=>{confirms++;return result();},onChange:v=>{if(v.phase===phase)m.dispose();}});await m.preparePreview();if(phase==="confirming")await m.confirmPreview({previewID,confirmed:true});assert.equal(prepares,phase==="preparing"?0:1);assert.equal(confirms,0);assert.equal(m.snapshot().phase,"closed");assert.equal(m.snapshot().busy,false);}
});
test("MOCK sync and async callback failures cannot strand busy or trigger effects",async()=>{
 for(const onChange of [()=>{throw Error("callback");},async()=>{throw Error("async callback");}]){let sends=0;const m=model({onChange,confirm:async()=>{sends++;return result();}});await m.preparePreview();assert.equal(m.snapshot().busy,false);await m.confirmPreview({previewID,confirmed:true});await new Promise(resolve=>setImmediate(resolve));assert.equal(m.snapshot().busy,false);assert.equal(sends,1);m.dispose();}
});
test("MOCK recovery modes reject preview and confirmation before clock or transport",async()=>{
 for(const mode of ["read_only_recovery","rolled_back_recovery"]){let calls=0;const m=model({mode,prepare:async()=>{calls++;return preview();},confirm:async()=>{calls++;return result();},now:()=>{calls++;return 0;}});await assert.rejects(m.preparePreview(),code("readOnly"));await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("readOnly"));assert.equal(calls,0);m.dispose();}
});
test("MOCK snapshots copy and freeze context and retain captured callback selection",async()=>{
 const raw=preview(),selected=intent();let first=0,second=0;const options={...binding(),intent:selected,prepare:async()=>{first++;return raw;},confirm:async()=>result(),now:()=>0};const m=X.createConfirmationModel(options);options.prepare=async()=>{second++;return raw;};selected.declaredBytes=0;await m.preparePreview();raw.context.userID="other";raw.declaredBytes=0;
 assert.equal(first,1);assert.equal(second,0);assert.equal(m.snapshot().preview.context.userID,"fixture-owner");assert.equal(m.snapshot().preview.declaredBytes,4);for(const value of [m.snapshot(),m.snapshot().preview,m.snapshot().preview.context])assert.equal(Object.isFrozen(value),true);m.dispose();
});
test("MOCK discarded nonce reuse is rejected and preview attempts are bounded",async()=>{
 const m=model();await m.preparePreview();m.discardPreview();await assert.rejects(m.preparePreview(),code("invalidResponse"));m.dispose();
 let calls=0;const n=model({prepare:async()=>{calls++;const suffix=String(calls).padStart(12,"0");return preview({previewID:"cccccccc-0000-4000-8000-"+suffix,operationID:"dddddddd-0000-4000-8000-"+suffix});}});for(let i=0;i<16;i++){await n.preparePreview();n.discardPreview();}await assert.rejects(n.preparePreview(),code("budgetExceeded"));assert.equal(calls,16);n.dispose();
});
test("MOCK a new preview cannot rewrap a previously discarded operation nonce",async()=>{
 let next=false;const m=model({prepare:async()=>next?preview({previewID:allocationID}):preview()});await m.preparePreview();m.discardPreview();next=true;await assert.rejects(m.preparePreview(),code("invalidResponse"));assert.equal(m.snapshot().preview,null);m.dispose();
});
test("MOCK a reported uncertain result remains spent and requires independent review",async()=>{
 let sends=0;const m=model({confirm:async()=>{sends++;return result({state:"uncertain"});}});await m.preparePreview();await m.confirmPreview({previewID,confirmed:true});
 assert.equal(m.snapshot().phase,"uncertain");assert.equal(m.snapshot().result.state,"uncertain");assert.equal(m.snapshot().requiresReview,true);assert.equal(m.snapshot().error,null);assert.equal(m.snapshot().stale,false);assert.equal(m.snapshot().confirmationDispatched,true);await assert.rejects(m.confirmPreview({previewID,confirmed:true}),code("replay"));assert.equal(sends,1);assert.equal(m.snapshot().capacityReleaseAuthorized,false);m.dispose();
});
