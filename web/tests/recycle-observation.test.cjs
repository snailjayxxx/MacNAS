"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const R=require("../dist/recycle-observation.js");
const operationID="10000000-0000-4000-8000-000000000001",entryID="20000000-0000-4000-8000-000000000002",otherID="30000000-0000-4000-8000-000000000003",ownerUserID="fixture-owner";
const ownerUserHex=Buffer.from(ownerUserID).toString("hex"),scope={operationID,entryID,ownerUserID};
const record=patch=>({operationID,entryID,kind:"recycle",phase:"armed",revision:2,entryRevision:2,chargeState:"reserved",chargedBytes:4,ownerUserHex,intentSHA256:"a".repeat(64),...patch});
const dto=(r=record(),classification="sourceOnly")=>({observationVersion:1,operationID,visibility:"visible",record:r,classification});
const no=()=>({observationVersion:1,operationID,visibility:"notVisible",record:null,classification:"notVisible"});
const bad=fn=>assert.throws(fn,error=>error?.code==="invalidResponse");
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};

test("exact visible and not-visible observations become immutable",()=>{
  const raw=dto(),value=R.observation(raw,scope);assert.deepEqual(value,raw);assert.ok(Object.isFrozen(value));assert.ok(Object.isFrozen(value.record));
  raw.record.phase="completed";assert.equal(value.record.phase,"armed");assert.throws(()=>{value.record.chargedBytes=0;},TypeError);
  assert.deepEqual(R.observation(no(),scope),no());
});
test("unknown, missing, inherited and symbol fields are refused",()=>{
  bad(()=>R.observation({...dto(),path:"/unapproved"},scope));const missing=dto();delete missing.visibility;bad(()=>R.observation(missing,scope));
  bad(()=>R.observation(Object.assign(Object.create({unexpected:true}),dto()),scope));
  bad(()=>R.observation({...dto(),[Symbol("extra")]:1},scope));bad(()=>R.observation(dto(record({payload:"secret"})),scope));
});
test("accessors are rejected without executing them at either DTO level",()=>{
  let calls=0;const raw=dto();Object.defineProperty(raw,"visibility",{enumerable:true,get(){calls++;return"visible";}});bad(()=>R.observation(raw,scope));
  const r=record();Object.defineProperty(r,"phase",{enumerable:true,get(){calls++;return"armed";}});bad(()=>R.observation(dto(r),scope));assert.equal(calls,0);
});
test("versions, canonical IDs and captured operation/entry are exact",()=>{
  for(const patch of [{observationVersion:2},{operationID:otherID},{operationID:operationID.toUpperCase()+"A"}])bad(()=>R.observation({...dto(),...patch},scope));
  bad(()=>R.observation(dto(record({operationID:otherID})),scope));bad(()=>R.observation(dto(record({entryID:otherID})),scope));
  bad(()=>R.observation(dto(record({entryID:"20000000-0000-4000-8000-00000000000A"})),scope));
});
test("raw subject bytes remain distinct including canonical Unicode variants",()=>{
  const composed="é",decomposed="e\u0301";const value=dto(record({ownerUserHex:Buffer.from(composed).toString("hex")}));
  assert.ok(R.observation(value,{operationID,ownerUserID:composed}));bad(()=>R.observation(value,{operationID,ownerUserID:decomposed}));
  bad(()=>R.observation(dto(record({ownerUserHex:"00"})),scope));
  for(const ownerUserID of ["", "x\0y", "x\ny", "\ud800", "界".repeat(43)])assert.throws(()=>R.observation(dto(),{operationID,ownerUserID}),e=>e.code==="invalidInput");
});
test("numbers reject boolean, negative, fractional and unsafe integers",()=>{
  for(const revision of [true,0,1.5,Number.MAX_SAFE_INTEGER+1,NaN,Infinity])bad(()=>R.observation(dto(record({revision})),scope));
  bad(()=>R.observation(dto(record({entryRevision:1})),scope));
  for(const chargedBytes of [-1,0.5,true,16777217])bad(()=>R.observation(dto(record({chargedBytes})),scope));
  assert.equal(R.observation(dto(record({chargedBytes:0})),scope).record.chargeState,"reserved");
});
test("hash, direction, phase and charge vocabulary are closed",()=>{
  for(const patch of [{intentSHA256:"A".repeat(64)},{intentSHA256:"a".repeat(63)},{kind:"delete"},{phase:"done"},{chargeState:"free"}])bad(()=>R.observation(dto(record(patch)),scope));
});
test("current charge is not inferred from historical completion or cancellation",()=>{
  const recycled=dto(record({phase:"completed",revision:4,entryRevision:8,chargeState:"released",chargedBytes:0}),"ambiguous");
  assert.equal(R.observation(recycled,scope).record.chargeState,"released");
  const cancelled=dto(record({kind:"restore",phase:"cancelled",entryRevision:10,chargeState:"released",chargedBytes:0}),"notObserved");
  assert.equal(R.observation(cancelled,scope).record.chargeState,"released");
  bad(()=>R.observation(dto(record({phase:"completed"}),"matchedPost"),scope));
  bad(()=>R.observation(dto(record({chargeState:"released",chargedBytes:4})),scope));
});
test("in-progress restore keeps retained charge and completed restore releases it",()=>{
  const restore=record({kind:"restore",chargeState:"retained"});assert.ok(R.observation(dto(restore),scope));
  bad(()=>R.observation(dto({...restore,chargeState:"released",chargedBytes:0}),scope));
  bad(()=>R.observation(dto({...restore,phase:"completed"},"matchedPost"),scope));
  assert.ok(R.observation(dto({...restore,phase:"completed",revision:4,entryRevision:9,chargeState:"released",chargedBytes:0},"matchedPost"),scope));
});
test("classification does not contradict persisted evidence phases",()=>{
  for(const [phase,classification]of [["armed","matchedPost"],["completed","candidateMoved"],["observed","candidateMoved"],["armed","notObserved"],["prepared","sourceOnly"],["observed","changed"]])bad(()=>R.observation(dto(record({phase,...(phase==="completed"?{chargeState:"retained",revision:4,entryRevision:4}:{})}),classification),scope));
  bad(()=>R.observation({...no(),classification:"ambiguous"},scope));bad(()=>R.observation({...no(),record:record()},scope));
  bad(()=>R.observation(dto(record(),"notVisible"),scope));
});
test("candidate or matched post never promotes the journal phase",()=>{
  const hidden=R.summary(no(),scope);assert.equal(hidden.journalCompleted,false);assert.equal(hidden.chargedBytes,null);assert.equal(hidden.requiresReview,true);
  const candidate=R.summary(dto(record(),"candidateMoved"),scope);assert.equal(candidate.journalPhase,"armed");assert.equal(candidate.journalCompleted,false);assert.equal(candidate.requiresReview,true);
  const matched=R.summary(dto(record({phase:"observed",revision:3,entryRevision:3}),"matchedPost"),scope);assert.equal(matched.journalPhase,"observed");assert.equal(matched.journalCompleted,false);assert.equal(matched.requiresReview,true);
  const complete=R.summary(dto(record({phase:"completed",revision:4,entryRevision:4,chargeState:"retained"}),"matchedPost"),scope);assert.equal(complete.journalCompleted,true);assert.equal(complete.requiresReview,false);
});
test("read-only model performs no implicit read, retry, cancel or close",async()=>{
  let calls=0;const model=R.createReadOnlyModel({...scope,read:async id=>{calls++;assert.equal(id,operationID);return dto();}});
  assert.equal(calls,0);assert.deepEqual(Object.keys(model).sort(),["dispose","refresh","snapshot"]);
  const result=await model.refresh();assert.equal(result,model.snapshot());assert.equal(result.busy,false);assert.equal(calls,1);assert.equal(model.snapshot().phase,"ready");model.dispose();assert.equal(calls,1);
  await assert.rejects(model.refresh(),e=>e.code==="unavailable");
});
test("concurrent refresh is refused without issuing a second read",async()=>{
  const gate=deferred();let calls=0;const model=R.createReadOnlyModel({...scope,read:()=>{calls++;return gate.promise;}});const pending=model.refresh();
  await assert.rejects(model.refresh(),e=>e.code==="busy");assert.equal(calls,1);gate.resolve(dto());await pending;assert.equal(model.snapshot().busy,false);
});
test("failed refresh keeps prior rows explicitly stale and does not auto retry",async()=>{
  let calls=0;const model=R.createReadOnlyModel({...scope,read:async()=>{if(++calls===1)return dto();throw new Error("private path must not leak");}});
  await model.refresh();const prior=model.snapshot().observation;await assert.rejects(model.refresh(),e=>e.code==="unavailable");
  assert.equal(calls,2);assert.equal(model.snapshot().observation,prior);assert.equal(model.snapshot().stale,true);assert.equal(model.snapshot().error,"unavailable");assert.equal(model.snapshot().busy,false);
});
test("invalid later metadata cannot replace the captured observation",async()=>{
  let calls=0;const model=R.createReadOnlyModel({...scope,read:async()=>++calls===1?dto():dto(record({entryID:otherID}))});
  await model.refresh();const prior=model.snapshot().observation;await assert.rejects(model.refresh(),e=>e.code==="invalidResponse");assert.equal(model.snapshot().observation,prior);assert.equal(model.snapshot().stale,true);
});
test("late success or error after disposal leaves a closed empty model",async()=>{
  for(const fail of [false,true]){const gate=deferred(),model=R.createReadOnlyModel({...scope,read:()=>gate.promise});const pending=model.refresh();model.dispose();
    if(fail)gate.reject(new Error("late"));else gate.resolve(dto());await pending;assert.equal(model.snapshot().phase,"closed");assert.equal(model.snapshot().observation,null);assert.equal(model.snapshot().busy,false);}
});
test("disposal from change callback prevents a late-started read",async()=>{
  let calls=0,model;model=R.createReadOnlyModel({...scope,read:async()=>{calls++;return dto();},onChange:view=>{if(view.phase==="reading")model.dispose();}});
  await model.refresh();assert.equal(calls,0);assert.equal(model.snapshot().phase,"closed");
});
test("option accessors and borrowed-source control fields are not accepted",()=>{
  let calls=0;const options={...scope};Object.defineProperty(options,"read",{enumerable:true,get(){calls++;return async()=>dto();}});
  assert.throws(()=>R.createReadOnlyModel(options),e=>e.code==="invalidInput");assert.equal(calls,0);
  assert.throws(()=>R.createReadOnlyModel({...scope,read:async()=>dto(),close(){calls++;}}),e=>e.code==="invalidInput");assert.equal(calls,0);
});

test("later observations cannot change immutable identity or regress revisions",async()=>{
  for(const [patch,classification]of [[{entryID:otherID},"sourceOnly"],[{intentSHA256:"b".repeat(64)},"sourceOnly"],[{kind:"restore",chargeState:"retained"},"sourceOnly"],[{revision:1,entryRevision:1},"sourceOnly"],[{phase:"observed"},"matchedPost"],[{chargedBytes:0},"sourceOnly"]]){
    let calls=0;const model=R.createReadOnlyModel({operationID,ownerUserID,read:async()=>++calls===1?dto():dto(record(patch),classification)});
    await model.refresh();const prior=model.snapshot().observation;
    await assert.rejects(model.refresh(),e=>e.code==="invalidResponse");assert.equal(model.snapshot().observation,prior);assert.equal(model.snapshot().stale,true);
  }
});

test("completed history can retain its operation revision while entry release advances",async()=>{
  let calls=0;const model=R.createReadOnlyModel({...scope,read:async()=>dto(record({phase:"completed",revision:4,entryRevision:calls++===0?4:8,chargeState:calls===1?"retained":"released",chargedBytes:calls===1?4:0}),"ambiguous")});
  await model.refresh();assert.equal(model.snapshot().observation.record.chargeState,"retained");
  const result=await model.refresh();assert.equal(result.observation.record.revision,4);assert.equal(result.observation.record.chargeState,"released");assert.equal(result.observation.record.entryRevision,8);
});
