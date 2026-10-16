(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"));
  else root.MacNASRecycleObservation=Object.freeze(factory(root.MacNASModel));
})(globalThis,function(M){
  "use strict";
  // Read-only presentation contract. No file operation, host approval or transport is created here.
  const encoder=new TextEncoder(),fileBytes=16*1024*1024;
  const phases=new Set(["prepared","armed","observed","completed","uncertain","cancelled"]);
  const classifications=new Set(["notVisible","notObserved","sourceOnly","candidateMoved","matchedPost","changed","ambiguous"]);
  const errors=new Set(["invalidInput","invalidResponse","unsafePath","unsafeFile","collision","invalidSchema","integrity","database","busy","denied","readOnly","expired","replay","staleState","unsupported","interrupted","missingVolume","timedOut","cancelled","budgetExceeded","unavailable"]);
  const check=(value,code="invalidResponse")=>{if(!value)throw new M.ServiceError(code);};
  const errorCode=error=>error instanceof M.ServiceError&&errors.has(error.code)?error.code:"unavailable";
  function fields(value,names,optional=[],code="invalidResponse"){
    check(value&&Object.getPrototypeOf(value)===Object.prototype,code);
    const descriptors=Object.getOwnPropertyDescriptors(value),copy={};
    check(names.every(name=>Object.hasOwn(descriptors,name)),code);
    for(const key of Reflect.ownKeys(descriptors)){
      const d=descriptors[key];check(typeof key==="string"&&[...names,...optional].includes(key)&&d.enumerable&&Object.hasOwn(d,"value"),code);
      Object.defineProperty(copy,key,{value:d.value,enumerable:true});
    }
    return copy;
  }
  function id(value,code="invalidResponse"){
    check(typeof value==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value),code);return value;
  }
  function integer(value,min=0,max=Number.MAX_SAFE_INTEGER){check(Number.isSafeInteger(value)&&value>=min&&value<=max);return value;}
  function subject(value,code="invalidResponse"){
    check(typeof value==="string"&&value.length>0&&value.isWellFormed()&&!/[\0\r\n]/.test(value)&&encoder.encode(value).length<=128,code);return value;
  }
  const hex=value=>[...encoder.encode(value)].map(byte=>byte.toString(16).padStart(2,"0")).join("");
  function expected(value){
    const p=fields(value,["operationID","ownerUserID"],["entryID"],"invalidInput");
    id(p.operationID,"invalidInput");subject(p.ownerUserID,"invalidInput");
    if(Object.hasOwn(p,"entryID"))id(p.entryID,"invalidInput");return Object.freeze(p);
  }
  function record(value,binding){
    const p=fields(value,["operationID","entryID","kind","phase","revision","entryRevision","chargeState","chargedBytes","ownerUserHex","intentSHA256"]);
    id(p.operationID);id(p.entryID);check(p.operationID===binding.operationID&&(!binding.entryID||p.entryID===binding.entryID));
    check(["recycle","restore"].includes(p.kind)&&phases.has(p.phase));integer(p.revision,1);integer(p.entryRevision,1);
    check(["reserved","retained","released"].includes(p.chargeState));integer(p.chargedBytes,0,fileBytes);
    check(typeof p.ownerUserHex==="string"&&p.ownerUserHex===hex(binding.ownerUserID));
    check(typeof p.intentSHA256==="string"&&/^[0-9a-f]{64}$/.test(p.intentSHA256));
    if(p.chargeState==="released")check(p.chargedBytes===0);
    if(p.kind==="restore"){
      check(p.chargeState!=="reserved");
      if(p.phase==="completed")check(p.chargeState==="released");
      else if(p.phase!=="cancelled")check(p.chargeState==="retained");
    }else if(p.phase==="cancelled")check(p.chargeState==="released");
    else if(p.phase==="completed")check(p.chargeState!=="reserved");
    else check(p.chargeState==="reserved");
    // A historical completed recycle or cancelled restore can now have a released entry.
    return Object.freeze(p);
  }
  function observation(value,scope){
    const binding=expected(scope),p=fields(value,["observationVersion","operationID","visibility","record","classification"]);
    check(p.observationVersion===1&&p.operationID===binding.operationID);id(p.operationID);
    check(["visible","notVisible"].includes(p.visibility)&&classifications.has(p.classification));
    if(p.visibility==="notVisible"){
      check(p.record===null&&p.classification==="notVisible");return Object.freeze(p);
    }
    check(p.classification!=="notVisible");const r=record(p.record,binding);
    if(p.classification==="matchedPost")check(["observed","uncertain","completed"].includes(r.phase));
    if(p.classification==="notObserved")check(["prepared","cancelled"].includes(r.phase));
    if(p.classification==="sourceOnly")check(!["prepared","cancelled","completed"].includes(r.phase));
    if(p.classification==="changed")check(r.phase==="completed");
    if(p.classification==="candidateMoved")check(!["observed","completed"].includes(r.phase));
    return Object.freeze({...p,record:r});
  }
  function summary(value,scope){
    const p=observation(value,scope),r=p.record;
    return Object.freeze({visibility:p.visibility,journalPhase:r?.phase??null,journalCompleted:r?.phase==="completed",
      classification:p.classification,chargeState:r?.chargeState??null,chargedBytes:r?.chargedBytes??null,
      requiresReview:!r||(["armed","observed","uncertain"].includes(r.phase)||["sourceOnly","candidateMoved","changed","ambiguous"].includes(p.classification))});
  }
  function createReadOnlyModel(options){
    const p=fields(options,["operationID","ownerUserID","read"],["entryID","onChange"],"invalidInput");
    const binding=expected({operationID:p.operationID,ownerUserID:p.ownerUserID,...(Object.hasOwn(p,"entryID")?{entryID:p.entryID}:{})});
    check(typeof p.read==="function"&&(!Object.hasOwn(p,"onChange")||typeof p.onChange==="function"),"invalidInput");
    let closed=false,busy=false,generation=0,lastVisible=null,view=Object.freeze({phase:"idle",busy:false,observation:null,error:null,stale:false});
    function update(patch){view=Object.freeze({...view,...patch});try{p.onChange?.(view);}catch{}return view;}
    return Object.freeze({snapshot:()=>view,
      async refresh(){
        check(!closed,"unavailable");check(!busy,"busy");busy=true;const epoch=++generation;
        update({phase:"reading",busy:true,error:null,stale:view.observation!==null});
        let failure=null;
        try{
          if(!closed&&epoch===generation){
            const raw=await p.read(binding.operationID);
            if(!closed&&epoch===generation){
              const value=observation(raw,binding),current=value.record;
              if(current){
                if(lastVisible){
                  check(["operationID","entryID","kind","ownerUserHex","intentSHA256"].every(key=>current[key]===lastVisible[key]));
                  check(current.revision>=lastVisible.revision&&current.entryRevision>=lastVisible.entryRevision);
                  if(current.revision===lastVisible.revision)check(current.phase===lastVisible.phase);
                  if(current.entryRevision===lastVisible.entryRevision)check(current.chargeState===lastVisible.chargeState&&current.chargedBytes===lastVisible.chargedBytes);
                  if(lastVisible.chargeState==="released")check(current.chargeState==="released");
                  if(["completed","cancelled"].includes(lastVisible.phase))check(current.phase===lastVisible.phase);
                }
                lastVisible=current;
              }
              update({phase:"ready",observation:value,error:null,stale:false});
            }
          }
        }catch(error){
          if(!closed&&epoch===generation){
            update({phase:"failed",error:errorCode(error),stale:view.observation!==null});failure=new M.ServiceError(errorCode(error));
          }
        }finally{busy=false;if(!closed&&epoch===generation)update({busy:false});}
        if(failure)throw failure;return view;
      },
      dispose(){if(closed)return;closed=true;generation++;lastVisible=null;update({phase:"closed",busy:false,observation:null,error:null,stale:false});}
    });
  }
  return {observation,summary,createReadOnlyModel};
});
