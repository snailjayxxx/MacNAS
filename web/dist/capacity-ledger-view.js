(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"));
  else root.MacNASCapacityLedgerView=Object.freeze(factory(root.MacNASModel));
})(globalThis,function(M){
  "use strict";
  // Proposed read-only ledger contract. No physical observation or approval is created.
  const encoder=new TextEncoder(),fileBytes=16*1024*1024,limitBytes=64*1024*1024;
  const states=new Set(["reserved","armed","owned","cancelled"]);
  const errors=new Set(["invalidInput","invalidResponse","busy","denied","readOnly","expired","staleState","unsupported","interrupted","timedOut","cancelled","budgetExceeded","unavailable","database","integrity","unsafeFile","invalidSchema"]);
  const check=(value,code="invalidResponse")=>{if(!value)throw new M.ServiceError(code);};
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
  function uuid(value,code="invalidResponse"){
    check(typeof value==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value),code);return value;
  }
  function number(value,min=0,max=Number.MAX_SAFE_INTEGER){check(Number.isSafeInteger(value)&&value>=min&&value<=max);return value;}
  function subject(value){
    check(typeof value==="string"&&value.isWellFormed()&&value.length>0&&!/[\0\r\n]/.test(value)&&encoder.encode(value).length<=128,"invalidInput");return value;
  }
  function hash(value,code="invalidResponse"){check(typeof value==="string"&&/^[0-9a-f]{64}$/.test(value),code);return value;}
  const hex=value=>[...encoder.encode(value)].map(byte=>byte.toString(16).padStart(2,"0")).join("");
  function binding(value){const b=fields(value,["scopeID","ownerUserID","sourceID"],[],"invalidInput");uuid(b.scopeID,"invalidInput");subject(b.ownerUserID);hash(b.sourceID,"invalidInput");return Object.freeze(b);}
  function dense(value){
    check(Array.isArray(value)&&Object.getPrototypeOf(value)===Array.prototype);
    const d=Object.getOwnPropertyDescriptors(value),length=d.length;
    check(length&&Object.hasOwn(length,"value")&&!length.enumerable);number(length.value,0,64);
    check(Reflect.ownKeys(d).length===length.value+1);
    const result=[];
    for(let n=0;n<length.value;n++){const item=d[String(n)];check(item&&item.enumerable&&Object.hasOwn(item,"value"));result.push(item.value);}
    return result;
  }
  function allocation(value){
    const p=fields(value,["allocationID","origin","intentSHA256","declaredBytes","state","revision","sha256"]);
    uuid(p.allocationID);check(["upload","copy"].includes(p.origin));hash(p.intentSHA256);number(p.declaredBytes,0,fileBytes);check(states.has(p.state));
    number(p.revision,1,3);check(p.revision===({reserved:1,armed:2,owned:3,cancelled:2})[p.state]);
    if(p.state==="owned")hash(p.sha256);else check(p.sha256===null);
    return Object.freeze(p);
  }
  function listSnapshot(value,expected){
    const b=binding(expected),p=fields(value,["listVersion","scopeID","ownerUserHex","sourceID","evidence","limitBytes","totals","items"]);
    check(p.listVersion===1&&p.evidence==="ledgerOnly"&&p.limitBytes===limitBytes);
    uuid(p.scopeID);hash(p.sourceID);check(p.scopeID===b.scopeID&&p.ownerUserHex===hex(b.ownerUserID)&&p.sourceID===b.sourceID);
    const rows=dense(p.items).map(allocation);
    for(let i=1;i<rows.length;i++)check(rows[i-1].allocationID<rows[i].allocationID);
    const t=fields(p.totals,["reservedBytes","unresolvedBytes","ownedBytes","allocatedBytes","historyCount","unresolvedCount"]);
    for(const name of ["reservedBytes","unresolvedBytes","ownedBytes","allocatedBytes"])number(t[name],0,limitBytes);
    number(t.historyCount,0,64);number(t.unresolvedCount,0,8);
    const computed={reservedBytes:0,unresolvedBytes:0,ownedBytes:0,allocatedBytes:0,historyCount:rows.length,unresolvedCount:0};
    let active=0;
    for(const row of rows){
      if(row.state==="reserved"){computed.reservedBytes+=row.declaredBytes;active++;}
      if(row.state==="armed"){computed.unresolvedBytes+=row.declaredBytes;computed.unresolvedCount++;active++;}
      if(row.state==="owned")computed.ownedBytes+=row.declaredBytes;
      if(row.state!=="cancelled")computed.allocatedBytes+=row.declaredBytes;
    }
    check(active<=8&&computed.allocatedBytes<=limitBytes);
    check(Object.keys(computed).every(name=>computed[name]===t[name]));
    return Object.freeze({...p,totals:Object.freeze(t),items:Object.freeze(rows)});
  }
  function summarize(value,expected){
    const p=listSnapshot(value,expected);
    return Object.freeze({evidence:p.evidence,allocatedBytes:p.totals.allocatedBytes,
      reservedBytes:p.totals.reservedBytes,unresolvedBytes:p.totals.unresolvedBytes,ownedBytes:p.totals.ownedBytes,
      historyCount:p.items.length,admissionBlockedByArmed:p.totals.unresolvedCount>0,
      filesystemVerified:false,executionAuthorized:false});
  }
  function progression(previous,current){
    const currentRows=new Map(current.items.map(item=>[item.allocationID,item]));
    for(const old of previous.items){
      const next=currentRows.get(old.allocationID);check(next);
      check(["allocationID","origin","intentSHA256","declaredBytes"].every(name=>old[name]===next[name]));
      check(next.revision>=old.revision);
      if(next.revision===old.revision)check(next.state===old.state&&next.sha256===old.sha256);
      if(old.state==="armed")check(["armed","owned"].includes(next.state));
      if(["owned","cancelled"].includes(old.state))check(next.state===old.state&&next.sha256===old.sha256);
    }
  }
  function createReadOnlyModel(options){
    const p=fields(options,["scopeID","ownerUserID","sourceID","read"],["onChange"],"invalidInput"),b=binding({scopeID:p.scopeID,ownerUserID:p.ownerUserID,sourceID:p.sourceID});
    check(typeof p.read==="function"&&(!Object.hasOwn(p,"onChange")||typeof p.onChange==="function"),"invalidInput");
    let closed=false,busy=false,epoch=0,last=null,view=Object.freeze({phase:"idle",busy:false,list:null,error:null,stale:false});
    const update=patch=>{view=Object.freeze({...view,...patch});try{p.onChange?.(view);}catch{}return view;};
    return Object.freeze({snapshot:()=>view,
      async refresh(){
        check(!closed,"unavailable");check(!busy,"busy");busy=true;const current=++epoch;
        update({phase:"reading",busy:true,error:null,stale:last!==null});
        if(closed||current!==epoch)return view;
        let failure=null;
        try{
          const raw=await p.read(b.scopeID);
          if(!closed&&current===epoch){const value=listSnapshot(raw,b);if(last)progression(last,value);last=value;update({phase:"ready",list:value,error:null,stale:false});}
        }catch(error){
          if(!closed&&current===epoch){const code=error instanceof M.ServiceError&&errors.has(error.code)?error.code:"unavailable";failure=new M.ServiceError(code);update({phase:"error",error:code,stale:last!==null});}
        }finally{if(!closed&&current===epoch){busy=false;update({busy:false});}}
        if(failure)throw failure;return view;
      },
      dispose(){if(closed)return;closed=true;epoch++;busy=false;last=null;update({phase:"closed",busy:false,list:null,error:null,stale:false});}
    });
  }
  return Object.freeze({listSnapshot,summarize,createReadOnlyModel});
});
