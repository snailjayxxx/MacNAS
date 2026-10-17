(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"));
  else root.MacNASManagedExecutionConfirmation=Object.freeze(factory(root.MacNASModel));
})(globalThis,function(M){
  "use strict";
  // Proposed presentation only. No host grant, source generator, transport or filesystem action.
  const encoder=new TextEncoder(),modes=new Set(["synthetic_development","read_only_recovery","rolled_back_recovery"]);
  const errors=new Set(["invalidInput","invalidResponse","unsafePath","unsafeFile","collision","invalidSchema","integrity","database","busy","denied","readOnly","expired","replay","staleState","unsupported","interrupted","missingVolume","timedOut","cancelled","budgetExceeded","unavailable"]);
  const check=(value,code="invalidResponse")=>{if(!value)throw new M.ServiceError(code);};
  function fields(value,names,optional=[],code="invalidResponse"){
    check(value&&Object.getPrototypeOf(value)===Object.prototype,code);
    const descriptors=Object.getOwnPropertyDescriptors(value),copy={};check(names.every(key=>Object.hasOwn(descriptors,key)),code);
    for(const key of Reflect.ownKeys(descriptors)){
      const d=descriptors[key];check(typeof key==="string"&&[...names,...optional].includes(key)&&d.enumerable&&Object.hasOwn(d,"value"),code);
      Object.defineProperty(copy,key,{value:d.value,enumerable:true});
    }
    return copy;
  }
  function id(v,c="invalidResponse"){check(typeof v==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v),c);return v;}
  function hash(v,c="invalidResponse"){check(typeof v==="string"&&/^[0-9a-f]{64}$/.test(v),c);return v;}
  function subject(v,c="invalidInput"){check(typeof v==="string"&&v.length>0&&v.length<=128&&v.isWellFormed()&&!/[\0\r\n]/.test(v)&&encoder.encode(v).length<=128,c);return v;}
  function integer(v,min,max,c="invalidResponse"){check(Number.isSafeInteger(v)&&v>=min&&v<=max,c);return v;}
  function expected(value){
    const b=fields(value,["scopeID","sourceID","ownerUserID","mode"],[],"invalidInput");
    id(b.scopeID,"invalidInput");hash(b.sourceID,"invalidInput");subject(b.ownerUserID);check(modes.has(b.mode),"invalidInput");return Object.freeze(b);
  }
  function intent(value){
    const p=fields(value,["kind","allocationID","entryID","declaredBytes","allocationIntentSHA256","sha256"],[],"invalidInput");
    check(["recycle","restore"].includes(p.kind),"invalidInput");id(p.allocationID,"invalidInput");
    if(p.kind==="recycle")check(p.entryID===null,"invalidInput");else id(p.entryID,"invalidInput");
    integer(p.declaredBytes,0,16777216,"invalidInput");hash(p.allocationIntentSHA256,"invalidInput");hash(p.sha256,"invalidInput");return Object.freeze(p);
  }
  function context(value,b){
    const p=fields(value,["executionContextVersion","source","purpose","scopeID","sourceID","userID","role","mode"]);
    check(p.executionContextVersion===1&&p.source==="fixture-host"&&p.purpose==="managed-execution"&&p.role==="administrator");
    id(p.scopeID);hash(p.sourceID);subject(p.userID,"invalidResponse");
    check(p.scopeID===b.scopeID&&p.sourceID===b.sourceID&&p.userID===b.ownerUserID&&p.mode===b.mode&&p.mode==="synthetic_development");return Object.freeze(p);
  }
  function previewSnapshot(value,binding,selected){
    const b=expected(binding),i=intent(selected);check(b.mode==="synthetic_development","readOnly");
    const p=fields(value,["previewVersion","context","previewID","operationID","entryID","kind","allocationID","declaredBytes","allocationIntentSHA256","operationIntentSHA256","sha256","expiresAfterMilliseconds","confirmationRequired"]);
    check(p.previewVersion===1&&p.confirmationRequired===true);id(p.previewID);id(p.operationID);id(p.entryID);hash(p.operationIntentSHA256);
    integer(p.expiresAfterMilliseconds,1,60000);check(["kind","allocationID","declaredBytes","allocationIntentSHA256","sha256"].every(key=>p[key]===i[key]));
    if(i.kind==="restore")check(p.entryID===i.entryID);
    return Object.freeze({...p,context:context(p.context,b)});
  }
  function resultSnapshot(value,preview,binding,selected){
    const b=expected(binding),prior=previewSnapshot(preview,b,selected),p=fields(value,["resultVersion","context","previewID","operationID","entryID","kind","allocationID","operationIntentSHA256","state"]);
    check(p.resultVersion===1&&["completed","uncertain"].includes(p.state));
    check(["previewID","operationID","entryID","kind","allocationID","operationIntentSHA256"].every(key=>p[key]===prior[key]));
    return Object.freeze({...p,context:context(p.context,b)});
  }
  function errorCode(error){
    try{if(error instanceof M.ServiceError){const d=Object.getOwnPropertyDescriptor(error,"code");if(d&&Object.hasOwn(d,"value")&&errors.has(d.value))return d.value;}}catch{}
    return "unavailable";
  }
  function createConfirmationModel(options){
    const p=fields(options,["scopeID","sourceID","ownerUserID","mode","intent","prepare","confirm","now"],["onChange"],"invalidInput");
    const b=expected({scopeID:p.scopeID,sourceID:p.sourceID,ownerUserID:p.ownerUserID,mode:p.mode}),selected=intent(p.intent);
    check([p.prepare,p.confirm,p.now].every(v=>typeof v==="function")&&(!Object.hasOwn(p,"onChange")||typeof p.onChange==="function"),"invalidInput");
    let closed=false,busy=false,epoch=0,attempts=0,lastClock=-1,deadline=null;
    const previews=new Set(),operations=new Set();
    let view=Object.freeze({phase:"idle",busy:false,preview:null,result:null,error:null,stale:false,confirmationDispatched:false,requiresReview:false,filesystemVerified:false,executionAuthorized:false,capacityReleaseAuthorized:false});
    function update(patch){view=Object.freeze({...view,...patch});try{Promise.resolve(p.onChange?.(view)).catch(()=>{});}catch{}return view;}
    function time(){
      let current;try{current=p.now();}catch{throw new M.ServiceError("unavailable");}
      check(Number.isFinite(current)&&current>=0&&current<=Number.MAX_SAFE_INTEGER&&current>=lastClock,"unavailable");lastClock=current;return current;
    }
    return Object.freeze({snapshot:()=>view,
      async preparePreview(){
        check(!closed,"unavailable");check(!busy,"busy");check(!view.confirmationDispatched,"replay");check(b.mode==="synthetic_development","readOnly");
        check(view.preview===null,"busy");check(attempts<16,"budgetExceeded");const started=time(),token=++epoch;busy=true;
        update({phase:"preparing",busy:true,preview:null,result:null,error:null,stale:false,requiresReview:false});if(closed||token!==epoch)return view;
        let failure=null;
        try{
          attempts++;const raw=await p.prepare(Object.freeze({scopeID:b.scopeID,sourceID:b.sourceID,...selected}));
          if(!closed&&token===epoch){
            const value=previewSnapshot(raw,b,selected);check(!previews.has(value.previewID)&&!operations.has(value.operationID));previews.add(value.previewID);operations.add(value.operationID);
            deadline=started+value.expiresAfterMilliseconds;check(Number.isFinite(deadline)&&deadline<=Number.MAX_SAFE_INTEGER&&time()<deadline,"expired");
            update({phase:"ready",preview:value,error:null,stale:false,requiresReview:false});
          }
        }catch(error){if(!closed&&token===epoch){const code=errorCode(error);failure=new M.ServiceError(code);deadline=null;update({phase:"error",preview:null,error:code,stale:false,requiresReview:false});}}
        finally{if(!closed&&token===epoch){busy=false;update({busy:false});}}
        if(failure)throw failure;return view;
      },
      discardPreview(){
        check(!closed,"unavailable");check(!busy,"busy");check(!view.confirmationDispatched,"replay");deadline=null;
        return update({phase:"idle",preview:null,result:null,error:null,stale:false,requiresReview:false});
      },
      async confirmPreview(value){
        const input=fields(value,["previewID","confirmed"],[],"invalidInput");id(input.previewID,"invalidInput");check(input.confirmed===true,"invalidInput");
        check(!closed,"unavailable");check(!busy,"busy");check(!view.confirmationDispatched,"replay");check(b.mode==="synthetic_development","readOnly");
        const saved=view.preview;check(saved&&input.previewID===saved.previewID,"denied");
        if(!(time()<deadline)){deadline=null;update({phase:"error",preview:null,error:"expired",stale:false,requiresReview:false});throw new M.ServiceError("expired");}
        const token=++epoch;busy=true;update({phase:"confirming",busy:true,confirmationDispatched:true,error:null,requiresReview:false});if(closed||token!==epoch)return view;
        let failure=null;
        try{
          const raw=await p.confirm(Object.freeze({scopeID:b.scopeID,sourceID:b.sourceID,previewID:saved.previewID,confirmed:true}));
          if(!closed&&token===epoch){const result=resultSnapshot(raw,saved,b,selected);update({phase:result.state,result,error:null,stale:false,requiresReview:result.state==="uncertain"});}
        }catch(error){if(!closed&&token===epoch){const code=errorCode(error);failure=new M.ServiceError(code);update({phase:"uncertain",result:null,error:code,stale:true,requiresReview:true});}}
        finally{if(!closed&&token===epoch){busy=false;update({busy:false});}}
        if(failure)throw failure;return view;
      },
      dispose(){if(closed)return;closed=true;epoch++;busy=false;deadline=null;previews.clear();operations.clear();update({phase:"closed",busy:false,preview:null,result:null,error:null,stale:false,confirmationDispatched:false,requiresReview:false});}
    });
  }
  return Object.freeze({previewSnapshot,resultSnapshot,createConfirmationModel});
});
