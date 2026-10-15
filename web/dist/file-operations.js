(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"));
  else root.MacNASFileOperations=Object.freeze(factory(root.MacNASModel));
})(globalThis,function(M){
  "use strict";
  const encoder=new TextEncoder(),sources=new WeakSet();
  const check=(value,code="invalidResponse")=>{if(!value)throw new M.ServiceError(code);};
  const freeze=value=>{if(value&&typeof value==="object"){Object.values(value).forEach(freeze);Object.freeze(value);}return value;};
  const errors=new Set(["unsafePath","unsafeFile","collision","invalidSchema","integrity","database","busy","denied","readOnly","expired","replay","staleState","unsupported","interrupted","missingVolume","timedOut","cancelled","budgetExceeded","unavailable"]);
  const errorCode=error=>error instanceof M.ServiceError&&errors.has(error.code)?error.code:"unavailable";
  function fields(value,required,optional=[],code="invalidResponse"){
    check(value&&Object.getPrototypeOf(value)===Object.prototype,code);const descriptors=Object.getOwnPropertyDescriptors(value),copy={};
    check(required.every(key=>Object.hasOwn(descriptors,key)),code);
    for(const key of Reflect.ownKeys(descriptors)){const d=descriptors[key];check(typeof key==="string"&&[...required,...optional].includes(key)&&d.enumerable&&Object.hasOwn(d,"value"),code);Object.defineProperty(copy,key,{value:d.value,enumerable:true});}return copy;
  }
  function text(value,max,empty=false,code="invalidResponse"){check(typeof value==="string"&&(empty||value.length>0)&&value.isWellFormed()&&!value.includes("\0")&&encoder.encode(value).length<=max,code);return value;}
  function component(value,code){text(value,255,false,code);check(value.trim()&&!/[\\/:]/.test(value)&&value!=="."&&value!=="..",code);return value;}
  function id(value,code="invalidResponse"){check(typeof value==="string"&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value),code);return value;}
  function intent(value,request=false){
    const code=request?"invalidInput":"invalidResponse",p=fields(value,request?["libraryID","kind","name"]:["libraryID","kind","name","parentPath","sourceName"],request?["parentPath","sourceName"]:[],code);
    text(p.libraryID,128,false,code);check(["createDirectory","rename"].includes(p.kind),code);component(p.name,code);
    const parentPath=Object.hasOwn(p,"parentPath")?text(p.parentPath,4096,true,code):"";
    check(!parentPath||parentPath.split("/").length<128&&!parentPath.includes("\\")&&parentPath.split("/").every(part=>part&&part!=="."&&part!==".."&&!part.includes(":")),code);
    const sourceName=Object.hasOwn(p,"sourceName")?p.sourceName:null;
    if(p.kind==="rename")component(sourceName,code);else check(sourceName===null,code);
    text(parentPath?parentPath+"/"+p.name:p.name,4096,false,code);
    return freeze({libraryID:p.libraryID,parentPath,kind:p.kind,sourceName,name:p.name});
  }
  const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
  function preview(value,expected){
    const p=fields(value,["previewVersion","operationID","intent","state","expiresInSeconds"]);id(p.operationID);
    check(p.previewVersion===1&&["ready","conflict","unchanged"].includes(p.state)&&p.expiresInSeconds===(p.state==="ready"?30:0));
    const valueIntent=intent(p.intent);if(expected)check(same(valueIntent,expected));return freeze({...p,intent:valueIntent});
  }
  function result(value,operationID,expected){
    const p=fields(value,["resultVersion","operationID","state","intent","error"]);id(p.operationID);
    check(p.resultVersion===1&&p.operationID===operationID&&["ready","completed","failed","uncertain","notVisible"].includes(p.state));
    if(p.state==="notVisible")check(p.intent===null&&p.error===null);
    else{const captured=intent(p.intent);if(expected)check(same(captured,expected));if(["failed","uncertain"].includes(p.state))check(errors.has(p.error));else check(p.error===null);return freeze({...p,intent:captured});}
    return freeze(p);
  }
  function createSource(context,operations){
    check(context&&["fixture","fixture-host"].includes(context.source)&&["administrator","reader"].includes(context.role)&&typeof context.userID==="string");
    const binding=freeze({...context});let closed=false;
    const alive=()=>check(!closed&&!operations.isClosed?.(),"unavailable");
    const writable=()=>{alive();check(binding.mode==="synthetic_development","readOnly");check(binding.role==="administrator","denied");};
    async function call(operation,decode){
      alive();try{const value=await operation();alive();return decode(value);}catch(error){const code=errorCode(error);if(code==="invalidResponse")closed=true;throw new M.ServiceError(code);}
    }
    const source=Object.freeze({context:binding,get closed(){return closed||!!operations.isClosed?.();},get canWrite(){return !this.closed&&binding.mode==="synthetic_development"&&binding.role==="administrator";},
      preview(params){writable();const captured=intent(params,true);return call(()=>operations.preview(captured),value=>preview(value,captured));},
      commit(operationID){writable();id(operationID,"invalidInput");return call(()=>operations.commit(operationID),value=>result(value,operationID));},
      status(operationID){alive();id(operationID,"invalidInput");return call(()=>operations.status(operationID),value=>result(value,operationID));},
      discard(operationID){id(operationID,"invalidInput");try{operations.discard?.(operationID);}catch{}},dispose(){closed=true;}
    });sources.add(source);return source;
  }
  async function createClientSource(client){
    check(client?.source==="fixture-host-client"&&!client.closed&&["overview","previewFileOperation","commitFileOperation","fileOperationStatus"].every(key=>typeof client[key]==="function"),"unavailable");
    const who=await client.overview();return createSource({source:"fixture-host",userID:who.userID,role:who.role,mode:who.mode},{preview:p=>client.previewFileOperation(p),commit:value=>client.commitFileOperation(value),status:value=>client.fileOperationStatus(value),discard:value=>client.discardFileOperation?.(value),isClosed:()=>client.closed});
  }
  function createController(source){
    check(sources.has(source)&&!source.closed,"invalidInput");let generation=0,busy=false;
    let view=freeze({phase:"idle",preview:null,result:null,error:null});
    const update=patch=>(view=freeze({...view,...patch})),ready=()=>{check(view.phase!=="closed"&&!source.closed,"unavailable");check(!busy,"busy");};
    return Object.freeze({snapshot:()=>view,get canWrite(){return source.canWrite;},
      async prepare(params){
        ready();check(view.phase!=="uncertain","staleState");const captured=intent(params,true),epoch=++generation;
        if(view.preview)source.discard(view.preview.operationID);busy=true;update({phase:"previewing",preview:null,result:null,error:null});
        try{const value=await source.preview(captured);if(epoch!==generation)return view;return update({phase:value.state,preview:value});}
        catch(error){if(epoch!==generation)return view;update({phase:"failed",error:errorCode(error)});throw error;}finally{busy=false;}
      },
      async commit(){
        ready();check(view.phase==="ready"&&view.preview,"denied");const captured=view.preview,epoch=generation;busy=true;update({phase:"committing",error:null});
        try{const value=await source.commit(captured.operationID);if(epoch!==generation)return view;result(value,captured.operationID,captured.intent);check(["completed","failed","uncertain"].includes(value.state));return update({phase:value.state,result:value,error:value.error});}
        catch(error){if(epoch!==generation)return view;update({phase:"uncertain",error:errorCode(error)});throw error;}finally{busy=false;}
      },
      async check(){
        ready();check(view.phase==="uncertain"&&view.preview,"denied");const captured=view.preview,epoch=generation;busy=true;update({phase:"checking",error:null});
        try{const value=await source.status(captured.operationID);if(epoch!==generation)return view;result(value,captured.operationID,captured.intent);return update({phase:["ready","notVisible"].includes(value.state)?"uncertain":value.state,result:value,error:value.error});}
        catch(error){if(epoch!==generation)return view;update({phase:"uncertain",error:errorCode(error)});throw error;}finally{busy=false;}
      },
      dispose(){generation++;if(view.preview)source.discard(view.preview.operationID);update({phase:"closed",preview:null,result:null,error:null});}
    });
  }
  return {intent,preview,result,id,createSource,createClientSource,createController};
});
