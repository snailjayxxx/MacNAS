(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"),require("./recycle-observation.js"));
  else root.MacNASManagedRecycleObservation=Object.freeze(factory(root.MacNASModel,root.MacNASRecycleObservation));
})(globalThis,function(M,R){
  "use strict";
  // Proposed managed observation presentation. No approval, transport or filesystem effect.
  const encoder=new TextEncoder(),modes=new Set(["synthetic_development","read_only_recovery","rolled_back_recovery"]);
  const errors=new Set(["invalidInput","invalidResponse","unsafePath","unsafeFile","collision","invalidSchema","integrity","database","busy","denied","readOnly","expired","replay","staleState","unsupported","interrupted","missingVolume","timedOut","cancelled","budgetExceeded","unavailable"]);
  const check=(v,c="invalidResponse")=>{if(!v)throw new M.ServiceError(c);};
  function fields(value,names,optional=[],code="invalidResponse"){
    check(value&&Object.getPrototypeOf(value)===Object.prototype,code);
    const descriptors=Object.getOwnPropertyDescriptors(value),copy={};check(names.every(k=>Object.hasOwn(descriptors,k)),code);
    for(const key of Reflect.ownKeys(descriptors)){
      const d=descriptors[key];check(typeof key==="string"&&[...names,...optional].includes(key)&&d.enumerable&&Object.hasOwn(d,"value"),code);
      Object.defineProperty(copy,key,{value:d.value,enumerable:true});
    }
    return copy;
  }
  function id(v,c="invalidResponse"){check(typeof v==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v),c);return v;}
  function hash(v,c="invalidResponse"){check(typeof v==="string"&&/^[0-9a-f]{64}$/.test(v),c);return v;}
  function subject(v,c="invalidInput"){check(typeof v==="string"&&v.length>0&&v.length<=128&&v.isWellFormed()&&!/[\0\r\n]/.test(v)&&encoder.encode(v).length<=128,c);return v;}
  function expected(value){
    const b=fields(value,["scopeID","sourceID","ownerUserID","mode","operationID"],["entryID","allocationID"],"invalidInput");
    id(b.scopeID,"invalidInput");hash(b.sourceID,"invalidInput");subject(b.ownerUserID);id(b.operationID,"invalidInput");check(modes.has(b.mode),"invalidInput");
    if(Object.hasOwn(b,"entryID"))id(b.entryID,"invalidInput");if(Object.hasOwn(b,"allocationID"))id(b.allocationID,"invalidInput");return Object.freeze(b);
  }
  const bodyBinding=b=>({operationID:b.operationID,ownerUserID:b.ownerUserID,...(Object.hasOwn(b,"entryID")?{entryID:b.entryID}:{})});
  function context(value,b){
    const p=fields(value,["contextVersion","source","scopeID","sourceID","userID","role","mode"]);
    check(p.contextVersion===1&&p.source==="fixture-host"&&p.role==="administrator");id(p.scopeID);hash(p.sourceID);subject(p.userID,"invalidResponse");
    check(p.scopeID===b.scopeID&&p.sourceID===b.sourceID&&p.userID===b.ownerUserID&&p.mode===b.mode);return Object.freeze(p);
  }
  function allocation(value){
    const p=fields(value,["allocationID","origin","intentSHA256","declaredBytes","state","revision","sha256"]);
    id(p.allocationID);hash(p.intentSHA256);hash(p.sha256);check(["upload","copy"].includes(p.origin));
    check(Number.isSafeInteger(p.declaredBytes)&&p.declaredBytes>=0&&p.declaredBytes<=16*1024*1024&&p.state==="owned"&&p.revision===3);return Object.freeze(p);
  }
  function observationSnapshot(value,binding){
    const b=expected(binding),p=fields(value,["managedObservationVersion","context","allocation","observation"]);check(p.managedObservationVersion===1);
    const c=context(p.context,b),o=R.observation(p.observation,bodyBinding(b));let a=null;
    if(o.visibility==="notVisible")check(p.allocation===null);
    else{a=allocation(p.allocation);if(Object.hasOwn(b,"allocationID"))check(a.allocationID===b.allocationID);if(o.record.chargeState!=="released")check(o.record.chargedBytes===a.declaredBytes);}
    return Object.freeze({...p,context:c,allocation:a,observation:o});
  }
  function summarize(value,binding){
    const p=observationSnapshot(value,binding),s=R.summary(p.observation,bodyBinding(expected(binding)));
    return Object.freeze({visibility:s.visibility,journalPhase:s.journalPhase,journalCompleted:s.journalCompleted,classification:s.classification,
      entryChargeState:s.chargeState,entryChargedBytes:s.chargedBytes,ownedChargedBytes:p.allocation?.declaredBytes??null,
      ownedRemainsCharged:p.allocation?true:null,matchingReported:s.classification==="matchedPost",requiresReview:s.requiresReview,
      filesystemVerified:false,executionAuthorized:false,capacityReleaseAuthorized:false});
  }
  function progression(previous,current){
    const a=previous.allocation,b=current.allocation,p=previous.observation.record,c=current.observation.record;
    check(a&&b&&p&&c);
    check(["allocationID","origin","intentSHA256","declaredBytes","state","revision","sha256"].every(k=>a[k]===b[k]));
    check(["operationID","entryID","kind","ownerUserHex","intentSHA256"].every(k=>p[k]===c[k]));
    check(c.revision>=p.revision&&c.entryRevision>=p.entryRevision);
    if(c.revision===p.revision)check(c.phase===p.phase);
    if(c.entryRevision===p.entryRevision)check(c.chargeState===p.chargeState&&c.chargedBytes===p.chargedBytes);
    if(p.chargeState==="released")check(c.chargeState==="released");
    if(["completed","cancelled"].includes(p.phase))check(c.phase===p.phase);
  }
  function errorCode(error){
    try{if(error instanceof M.ServiceError){const d=Object.getOwnPropertyDescriptor(error,"code");if(d&&Object.hasOwn(d,"value")&&errors.has(d.value))return d.value;}}catch{}
    return "unavailable";
  }
  function createReadOnlyModel(options){
    const p=fields(options,["scopeID","sourceID","ownerUserID","mode","operationID","read"],["entryID","allocationID","onChange"],"invalidInput");
    const b=expected({scopeID:p.scopeID,sourceID:p.sourceID,ownerUserID:p.ownerUserID,mode:p.mode,operationID:p.operationID,...(Object.hasOwn(p,"entryID")?{entryID:p.entryID}:{}),...(Object.hasOwn(p,"allocationID")?{allocationID:p.allocationID}:{})});
    check(typeof p.read==="function"&&(!Object.hasOwn(p,"onChange")||typeof p.onChange==="function"),"invalidInput");
    let closed=false,busy=false,epoch=0,lastVisible=null,view=Object.freeze({phase:"idle",busy:false,envelope:null,error:null,stale:false});
    const update=patch=>{view=Object.freeze({...view,...patch});try{p.onChange?.(view);}catch{}return view;};
    return Object.freeze({snapshot:()=>view,
      async refresh(){
        check(!closed,"unavailable");check(!busy,"busy");busy=true;const current=++epoch;
        update({phase:"reading",busy:true,error:null,stale:view.envelope!==null});if(closed||current!==epoch)return view;
        let failure=null;
        try{
          const raw=await p.read(b.operationID);
          if(!closed&&current===epoch){const value=observationSnapshot(raw,b);if(value.allocation){if(lastVisible)progression(lastVisible,value);lastVisible=value;}update({phase:"ready",envelope:value,error:null,stale:false});}
        }catch(error){if(!closed&&current===epoch){const code=errorCode(error);failure=new M.ServiceError(code);update({phase:"error",error:code,stale:view.envelope!==null});}}
        finally{if(!closed&&current===epoch){busy=false;update({busy:false});}}
        if(failure)throw failure;return view;
      },
      dispose(){if(closed)return;closed=true;epoch++;busy=false;lastVisible=null;update({phase:"closed",busy:false,envelope:null,error:null,stale:false});}
    });
  }
  return Object.freeze({observationSnapshot,summarize,createReadOnlyModel});
});
