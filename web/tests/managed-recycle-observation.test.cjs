"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const V=require('../dist/managed-recycle-observation.js'),M=require('../dist/model.js');
const operationID='cccccccc-0000-4000-8000-000000000003',entryID='dddddddd-0000-4000-8000-000000000004',allocationID='bbbbbbbb-0000-4000-8000-000000000002';
const binding=patch=>({scopeID:'aaaaaaaa-0000-4000-8000-000000000001',sourceID:'c'.repeat(64),ownerUserID:'fixture-owner',mode:'read_only_recovery',operationID,...patch});
const value=patch=>({managedObservationVersion:1,context:{contextVersion:1,source:'fixture-host',scopeID:binding().scopeID,sourceID:binding().sourceID,userID:'fixture-owner',role:'administrator',mode:'read_only_recovery'},
 allocation:{allocationID,origin:'upload',intentSHA256:'a'.repeat(64),declaredBytes:4,state:'owned',revision:3,sha256:'b'.repeat(64)},
 observation:{observationVersion:1,operationID,visibility:'visible',record:{operationID,entryID,kind:'recycle',phase:'completed',revision:4,entryRevision:4,chargeState:'retained',chargedBytes:4,ownerUserHex:Buffer.from('fixture-owner').toString('hex'),intentSHA256:'d'.repeat(64)},classification:'matchedPost'},...patch});
const absent=()=>value({allocation:null,observation:{observationVersion:1,operationID,visibility:'notVisible',record:null,classification:'notVisible'}});
const clone=x=>JSON.parse(JSON.stringify(x)),code=c=>e=>e instanceof M.ServiceError&&e.code===c;
function model(read,extra={}){return V.createReadOnlyModel({...binding(),read,...extra});}
const gate=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};

test('MOCK strict managed envelope keeps owned charge separate from released entry',()=>{
 const raw=value();raw.observation.record.chargeState='released';raw.observation.record.chargedBytes=0;raw.observation.record.entryRevision=9;
 const result=V.observationSnapshot(raw,binding()),summary=V.summarize(result,binding());assert.equal(summary.ownedChargedBytes,4);assert.equal(summary.entryChargedBytes,0);assert.equal(summary.ownedRemainsCharged,true);
 assert.equal(summary.capacityReleaseAuthorized,false);assert.equal(summary.executionAuthorized,false);assert.equal(summary.filesystemVerified,false);assert.equal(summary.matchingReported,true);assert.equal(Object.hasOwn(summary,'freeBytes'),false);
});
test('MOCK notVisible has explicit null allocation and unknown charges',()=>{
 const result=V.observationSnapshot(absent(),binding()),s=V.summarize(result,binding());assert.equal(result.allocation,null);assert.equal(s.ownedChargedBytes,null);assert.equal(s.entryChargedBytes,null);assert.equal(s.requiresReview,true);
 for(const bad of [value({allocation:null}),absent()]){if(bad.observation.visibility==='notVisible')bad.allocation=value().allocation;assert.throws(()=>V.observationSnapshot(bad,binding()),code('invalidResponse'));}
});
test('MOCK bounded owned row requires exact7 fields and conserves nonreleased bytes',()=>{
 const changes=[a=>delete a.sha256,a=>a.state='armed',a=>a.revision=4,a=>a.origin='initial',a=>a.declaredBytes=5,a=>a.declaredBytes=-1,a=>a.declaredBytes=16777217,a=>a.sha256='BAD',a=>a.path='/private',a=>a.allocationID=allocationID.toUpperCase()];
 for(const change of changes){const raw=value();change(raw.allocation);assert.throws(()=>V.observationSnapshot(raw,binding()),code('invalidResponse'));}
 for(const bytes of [0,16777216]){const raw=value();raw.allocation.declaredBytes=bytes;raw.observation.record.chargedBytes=bytes;assert.equal(V.observationSnapshot(raw,binding()).allocation.declaredBytes,bytes);}
});
test('MOCK fields reject extras missing fields inherited values symbols and getters without calls',()=>{
 let gets=0;
 for(const modify of [v=>v.extra=true,v=>delete v.context,v=>v.context.extra=true,v=>Object.defineProperty(v.allocation,'sha256',{enumerable:true,get(){gets++;return 'b'.repeat(64);}}),v=>v.observation[Symbol('x')]=1,v=>v.context=Object.create(v.context)]){
  const raw=value();modify(raw);assert.throws(()=>V.observationSnapshot(raw,binding()),code('invalidResponse'));
 }
 assert.equal(gets,0);
});
test('MOCK fixed context rejects other source scope role mode and raw subject',()=>{
 for(const patch of [{sourceID:'e'.repeat(64)},{scopeID:entryID},{role:'reader'},{mode:'synthetic_development'},{userID:'another'},{contextVersion:2},{source:'fixture'}]){
  const raw=value();Object.assign(raw.context,patch);assert.throws(()=>V.observationSnapshot(raw,binding()),code('invalidResponse'));
 }
 const raw=value();raw.context.userID='é';raw.observation.record.ownerUserHex=Buffer.from('é').toString('hex');assert.throws(()=>V.observationSnapshot(raw,binding({ownerUserID:'e\u0301'})),code('invalidResponse'));
});
test('MOCK expected binding is explicit rawUTF8 bounded and cannot derive source from response',()=>{
 for(const patch of [{sourceID:undefined},{scopeID:allocationID.toUpperCase()},{operationID:'/path'},{ownerUserID:'owner\n'},{ownerUserID:'\ud800'},{ownerUserID:'a'.repeat(129)},{mode:'unknown'},{extra:true}])assert.throws(()=>V.observationSnapshot(value(),binding(patch)),code('invalidInput'));
 const raw=value();raw.context.userID='e\u0301';raw.observation.record.ownerUserHex=Buffer.from('e\u0301').toString('hex');assert.equal(V.observationSnapshot(raw,binding({ownerUserID:'e\u0301'})).context.userID,'e\u0301');
});
test('MOCK known entry and allocation identities must match even on first response',()=>{
 assert.equal(V.observationSnapshot(value(),binding({entryID,allocationID})).allocation.allocationID,allocationID);
 for(const patch of [{entryID:allocationID},{allocationID:entryID},{operationID:entryID}])assert.throws(()=>V.observationSnapshot(value(),binding(patch)),code('invalidResponse'));
});
test('MOCK snapshot deeply copies and freezes all nested data',()=>{
 const raw=value(),result=V.observationSnapshot(raw,binding());raw.context.mode='synthetic_development';raw.allocation.declaredBytes=0;raw.observation.record.revision=99;
 assert.equal(result.context.mode,'read_only_recovery');assert.equal(result.allocation.declaredBytes,4);assert.equal(result.observation.record.revision,4);
 for(const v of [result,result.context,result.allocation,result.observation,result.observation.record])assert.equal(Object.isFrozen(v),true);
});
test('MOCK creation refresh and disposal create no operation or transport effects',async()=>{
 let reads=0;const m=model(async id=>{assert.equal(id,operationID);reads++;return value();});assert.deepEqual(Object.keys(m).sort(),['dispose','refresh','snapshot']);assert.equal(reads,0);const result=await m.refresh();assert.equal(result.busy,false);assert.equal(reads,1);m.dispose();assert.equal(reads,1);assert.equal(m.snapshot().envelope,null);
});
test('MOCK one in-flight read serializes refresh and never retries',async()=>{
 const d=gate();let reads=0;const m=model(()=>{reads++;return d.promise;}),pending=m.refresh();await assert.rejects(m.refresh(),code('busy'));assert.equal(reads,1);d.resolve(value());await pending;assert.equal(m.snapshot().busy,false);m.dispose();
});
test('MOCK errors retain prior envelope and mark stale using finite codes',async()=>{
 let failure=false;const m=model(async()=>{if(failure)throw new M.ServiceError('expired');return value();});await m.refresh();const prior=m.snapshot().envelope;failure=true;await assert.rejects(m.refresh(),code('expired'));assert.equal(m.snapshot().envelope,prior);assert.equal(m.snapshot().stale,true);assert.equal(m.snapshot().error,'expired');assert.equal(m.snapshot().busy,false);m.dispose();
});
test('MOCK unknown errors and code getters cannot enter the visible error',async()=>{
 let calls=0;const error=new M.ServiceError('denied');Object.defineProperty(error,'code',{get(){calls++;throw Error('secret');}});
 for(const e of [error,new Error('secret raw database detail'),{message:'private',code:'denied'}]){const m=model(async()=>{throw e;});await assert.rejects(m.refresh(),code('unavailable'));assert.equal(m.snapshot().error,'unavailable');m.dispose();}
 assert.equal(calls,0);
});
test('MOCK dispose clears previous owner envelope and ignores late success getters',async()=>{
 const d=gate();let calls=0,second=false;const m=model(()=>second?d.promise:Promise.resolve(value()));await m.refresh();second=true;const pending=m.refresh();m.dispose();const raw={};Object.defineProperty(raw,'context',{get(){calls++;throw Error('late');}});d.resolve(raw);await pending;
 assert.equal(calls,0);assert.equal(m.snapshot().phase,'closed');assert.equal(m.snapshot().envelope,null);assert.equal(m.snapshot().error,null);assert.equal(m.snapshot().stale,false);await assert.rejects(m.refresh(),code('unavailable'));
});
test('MOCK dispose ignores late failures without reading error properties',async()=>{
 const d=gate(),m=model(()=>d.promise),pending=m.refresh();let gets=0;m.dispose();const error={};Object.defineProperty(error,'code',{get(){gets++;throw Error('late');}});d.reject(error);await pending;assert.equal(gets,0);assert.equal(m.snapshot().phase,'closed');assert.equal(m.snapshot().error,null);
});
test('MOCK reading callback can dispose before any read is issued',async()=>{
 let reads=0,m;m=model(async()=>{reads++;return value();},{onChange:v=>{if(v.phase==='reading')m.dispose();}});await m.refresh();assert.equal(reads,0);assert.equal(m.snapshot().phase,'closed');assert.equal(m.snapshot().busy,false);
});
test('MOCK callback exceptions cannot strand busy or leak returned input mutations',async()=>{
 const m=model(async()=>value(),{onChange(){throw Error('callback');}});await m.refresh();assert.equal(m.snapshot().phase,'ready');assert.equal(m.snapshot().busy,false);await m.refresh();m.dispose();
});
test('MOCK a later visible record cannot replace the conserved allocation identity or declaration',async()=>{
 for(const key of ['allocationID','origin','intentSHA256','declaredBytes','sha256']){
  const first=value(),later=clone(first);later.allocation[key]=({allocationID:entryID,origin:'copy',intentSHA256:'e'.repeat(64),declaredBytes:0,sha256:'e'.repeat(64)})[key];if(key==='declaredBytes')later.observation.record.chargedBytes=0;
  let next=false;const m=model(async()=>next?later:first);await m.refresh();const prior=m.snapshot().envelope;next=true;await assert.rejects(m.refresh(),code('invalidResponse'));assert.equal(m.snapshot().envelope,prior);m.dispose();
 }
});
test('MOCK independent operation and entry revisions progress without coupling owned charge',async()=>{
 const first=value(),released=clone(first);released.observation.record.entryRevision=9;released.observation.record.chargeState='released';released.observation.record.chargedBytes=0;
 let next=false;const m=model(async()=>next?released:first);await m.refresh();next=true;await m.refresh();assert.equal(m.snapshot().envelope.allocation.declaredBytes,4);assert.equal(m.snapshot().envelope.observation.record.revision,4);m.dispose();
});
test('MOCK terminal records revisions and released entries cannot regress or switch intent',async()=>{
 const mutations=[r=>r.entryID=allocationID,r=>r.intentSHA256='e'.repeat(64),r=>r.revision=3,r=>r.entryRevision=3,r=>{r.phase='armed';r.revision=5;r.chargeState='reserved';},r=>{r.chargeState='released';r.chargedBytes=0;}];
 for(const mutate of mutations){const first=value(),later=clone(first);mutate(later.observation.record);if(later.observation.record.phase==='armed')later.observation.classification='sourceOnly';let next=false;const m=model(async()=>next?later:first);await m.refresh();next=true;await assert.rejects(m.refresh(),code('invalidResponse'));m.dispose();}
});
test('MOCK notVisible remains unknown while later reappearance must retain original allocation',async()=>{
 const later=value();later.allocation.allocationID=entryID;const queue=[value(),absent(),later],m=model(async()=>queue.shift());await m.refresh();await m.refresh();assert.equal(V.summarize(m.snapshot().envelope,binding()).ownedChargedBytes,null);await assert.rejects(m.refresh(),code('invalidResponse'));m.dispose();
});
test('MOCK released entry cannot regain charge even if its revision increases',async()=>{
 const first=value();Object.assign(first.observation.record,{entryRevision:9,chargeState:'released',chargedBytes:0});const later=clone(first);Object.assign(later.observation.record,{entryRevision:10,chargeState:'retained',chargedBytes:4});let next=false;
 const m=model(async()=>next?later:first);await m.refresh();next=true;await assert.rejects(m.refresh(),code('invalidResponse'));assert.equal(m.snapshot().envelope.allocation.declaredBytes,4);m.dispose();
});
test('MOCK candidateMoved retains owned fees and requires review without execution authority',()=>{
 const raw=value();Object.assign(raw.observation.record,{phase:'armed',revision:2,entryRevision:2,chargeState:'reserved'});raw.observation.classification='candidateMoved';
 const s=V.summarize(raw,binding());assert.equal(s.ownedChargedBytes,4);assert.equal(s.requiresReview,true);assert.equal(s.executionAuthorized,false);assert.equal(s.capacityReleaseAuthorized,false);assert.equal(s.filesystemVerified,false);
});
