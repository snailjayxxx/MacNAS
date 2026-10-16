(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"),require("./file-operations.js"),require("./file-transfers.js"));
  else root.MacNASFileCopies=Object.freeze(factory(root.MacNASModel,root.MacNASFileOperations,root.MacNASFileTransfers));
})(globalThis,function(M,O,T){
  "use strict";
  const chunkBytes=32768,fileBytes=16*1024*1024,sources=new WeakSet();
  const errors=new Set(["invalidInput","invalidResponse","unsafePath","unsafeFile","collision","invalidSchema","integrity","database","busy","denied","readOnly","expired","replay","staleState","unsupported","interrupted","missingVolume","timedOut","cancelled","budgetExceeded","unavailable"]);
  const check=(value,code="invalidResponse")=>{if(!value)throw new M.ServiceError(code);};
  const errorCode=error=>error instanceof M.ServiceError&&errors.has(error.code)?error.code:"unavailable";
  function freeze(value){if(value&&typeof value==="object"){Object.values(value).forEach(freeze);Object.freeze(value);}return value;}
  function fields(value,required,optional=[],code="invalidResponse"){
    check(value&&Object.getPrototypeOf(value)===Object.prototype,code);const ds=Object.getOwnPropertyDescriptors(value),copy={};check(required.every(key=>Object.hasOwn(ds,key)),code);
    for(const key of Reflect.ownKeys(ds)){const d=ds[key];check(typeof key==="string"&&[...required,...optional].includes(key)&&d.enumerable&&Object.hasOwn(d,"value"),code);Object.defineProperty(copy,key,{value:d.value,enumerable:true});}return copy;
  }
  function integer(value,max=fileBytes,code="invalidResponse"){check(Number.isSafeInteger(value)&&value>=0&&value<=max,code);return value;}
  const target=p=>(p.parentPath?p.parentPath+"/":"")+p.name;
  function intent(value,request=false){
    const code=request?"invalidInput":"invalidResponse",p=fields(value,["sourceLibraryID","sourcePath","targetLibraryID","name",...(request?[]:["parentPath"])],request?["parentPath"]:[],code);
    try{
      const from=T.downloadIntent({libraryID:p.sourceLibraryID,relativePath:p.sourcePath}),to=O.intent({libraryID:p.targetLibraryID,parentPath:Object.hasOwn(p,"parentPath")?p.parentPath:"",kind:"createDirectory",name:p.name},true);
      return freeze({sourceLibraryID:from.libraryID,sourcePath:from.relativePath,targetLibraryID:to.libraryID,parentPath:to.parentPath,name:to.name});
    }catch{throw new M.ServiceError(code);}
  }
  const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
  function preview(value,expected){
    const p=fields(value,["copyVersion","copyID","intent","state","totalBytes","chunkBytes","expiresInSeconds"]),captured=intent(p.intent);O.id(p.copyID);
    check(p.copyVersion===1&&p.chunkBytes===chunkBytes&&["ready","conflict","unchanged"].includes(p.state)&&p.expiresInSeconds===(p.state==="ready"?30:0));integer(p.totalBytes);
    check((p.state==="unchanged")===(captured.sourceLibraryID===captured.targetLibraryID&&captured.sourcePath===target(captured)));
    if(expected)check(same(captured,expected));return freeze({...p,intent:captured});
  }
  function status(value,id,expected){
    const p=fields(value,["copyVersion","copyID","state","intent","totalBytes","copiedBytes","chunkBytes","sha256","error"]);O.id(p.copyID);
    check(p.copyVersion===1&&p.copyID===id&&p.chunkBytes===chunkBytes&&["ready","copying","completed","cancelled","failed","uncertain","notVisible"].includes(p.state));
    if(p.state==="notVisible"){check(["intent","totalBytes","copiedBytes","sha256","error"].every(key=>p[key]===null));return freeze(p);}
    const captured=intent(p.intent);integer(p.totalBytes);integer(p.copiedBytes,p.totalBytes);
    if(expected){check(same(captured,expected.intent));if(expected.totalBytes!==undefined)check(p.totalBytes===expected.totalBytes);}
    if(p.state==="ready")check(p.copiedBytes===0);
    if(["completed","uncertain"].includes(p.state))check(p.copiedBytes===p.totalBytes&&typeof p.sha256==="string"&&/^[0-9a-f]{64}$/.test(p.sha256));else check(p.sha256===null);
    if(["failed","uncertain"].includes(p.state))check(errors.has(p.error));else check(p.error===null);
    return freeze({...p,intent:captured});
  }
  function createSource(context,operations){
    check(context&&["fixture","fixture-host"].includes(context.source)&&["administrator","reader"].includes(context.role));
    const binding=freeze({...context}),owned=new Map(),busyIDs=new Map();let closed=false,heads=0;
    const alive=()=>check(!closed&&!operations.isClosed?.(),"unavailable");
    const writable=()=>{alive();check(binding.mode==="synthetic_development","readOnly");check(binding.role==="administrator","denied");};
    function trimReceipts(){
      const receipts=[...owned].filter(([,entry])=>entry.terminal);let excess=receipts.length-32;
      for(const [id,entry]of receipts){if(excess<=0)break;if(entry.cleaning||busyIDs.has(id))continue;try{operations.discard?.(id);owned.delete(id);excess--;}catch{}}
    }
    async function cleanup(id){
      const entry=owned.get(id);if(!entry||entry.cleaning||busyIDs.has(id))return;entry.cleaning=true;
      try{await operations.cancel(id);}catch{}finally{try{operations.discard?.(id);}catch{}owned.delete(id);}
    }
    async function call(operation,id){
      alive();const tracked=owned.has(id);if(tracked)busyIDs.set(id,(busyIDs.get(id)||0)+1);
      try{let value=await operation();if(tracked){value=status(value,id,owned.get(id).expected);owned.get(id).terminal=["completed","cancelled","failed","uncertain","notVisible"].includes(value.state);}alive();return value;}catch(error){throw new M.ServiceError(errorCode(error));}
      finally{if(tracked){const count=busyIDs.get(id)-1;if(count)busyIDs.set(id,count);else busyIDs.delete(id);if(closed||operations.isClosed?.())await cleanup(id);else trimReceipts();}}
    }
    async function head(p){
      alive();trimReceipts();check(owned.size+heads<40,"budgetExceeded");heads++;
      try{
        const value=preview(await operations.preview(p),p);
        if(value.state==="ready"){check(!owned.has(value.copyID));owned.set(value.copyID,{cleaning:false,terminal:false,expected:{intent:p,totalBytes:value.totalBytes}});}
        if(closed||operations.isClosed?.()){if(value.state==="ready")await cleanup(value.copyID);throw new M.ServiceError("unavailable");}
        return value;
      }catch(error){throw new M.ServiceError(errorCode(error));}finally{heads--;}
    }
    const source=Object.freeze({context:binding,get closed(){return closed||!!operations.isClosed?.();},get canCopy(){return !this.closed&&binding.mode==="synthetic_development"&&binding.role==="administrator";},
      preview(p){writable();return head(intent(p,true));},
      begin(id){writable();O.id(id,"invalidInput");return call(()=>operations.begin(id),id);},
      chunk(id,offset){writable();O.id(id,"invalidInput");integer(offset,fileBytes,"invalidInput");return call(()=>operations.chunk(id,offset),id);},
      status(id){alive();O.id(id,"invalidInput");return call(()=>operations.status(id),id);},
      cancel(id){alive();O.id(id,"invalidInput");return call(()=>operations.cancel(id),id);},
      discard(id){O.id(id,"invalidInput");if(busyIDs.has(id))return false;try{const removed=operations.discard?.(id)??false,local=owned.get(id)?.terminal===true;if(removed||local)owned.delete(id);return removed||local;}catch{return false;}},
      dispose(){if(closed)return;closed=true;for(const id of owned.keys())void cleanup(id);operations.dispose?.();}
    });sources.add(source);return source;
  }
  async function createClientSource(client){
    check(client?.source==="fixture-host-client"&&!client.closed&&["overview","previewFileCopy","beginFileCopy","copyFileChunk","fileCopyStatus","cancelFileCopy","discardFileCopy"].every(key=>typeof client[key]==="function"),"unavailable");
    const who=await client.overview();return createSource({source:"fixture-host",userID:who.userID,role:who.role,mode:who.mode},{preview:p=>client.previewFileCopy(p),begin:id=>client.beginFileCopy(id),chunk:(id,offset)=>client.copyFileChunk({copyID:id,offset}),status:id=>client.fileCopyStatus(id),cancel:id=>client.cancelFileCopy(id),discard:id=>client.discardFileCopy(id),isClosed:()=>client.closed});
  }
  function createController(source,{onChange=()=>{}}={}){
    check(sources.has(source)&&!source.closed&&typeof onChange==="function","invalidInput");let busy=false,cancelled=false,closed=false,epoch=0;
    let view=freeze({phase:"idle",busy:false,preview:null,result:null,copyID:null,intent:null,totalBytes:0,copiedBytes:0,error:null});
    function update(p){if(closed&&p.phase!=="closed")return view;view=freeze({...view,...p});try{onChange(view);}catch{}return view;}
    function ready(){check(!closed&&!source.closed,"unavailable");check(!busy,"busy");}
    const expected=()=>({intent:view.intent,totalBytes:view.totalBytes});
    async function cancelID(id,binding){
      try{const value=status(await source.cancel(id),id,binding);check(["cancelled","completed","failed","uncertain"].includes(value.state));return value;}catch{return null;}
    }
    function finish(value){return update({phase:value?.state||"uncertain",result:value,copiedBytes:value?.copiedBytes??view.copiedBytes,error:value?value.error:"unavailable"});}
    async function release(id,binding){const value=await cancelID(id,binding);source.discard(id);return value;}
    const yieldChunk=()=>new Promise(resolve=>setTimeout(resolve,0));
    return Object.freeze({snapshot:()=>view,get canCopy(){return source.canCopy;},
      async prepare(params){
        ready();check(view.phase!=="uncertain","staleState");const p=intent(params,true),previousID=view.copyID,previous=view.phase,previousBinding=expected();busy=true;cancelled=false;const generation=++epoch;update({busy:true});
        try{
          if(previousID){if(previous==="ready"){const ended=await release(previousID,previousBinding);if(!ended&&!closed)return finish(null);}else source.discard(previousID);}
          if(closed||cancelled)return update({phase:closed?"closed":"cancelled"});
          update({phase:"previewing",preview:null,result:null,copyID:null,intent:p,totalBytes:0,copiedBytes:0,error:null});
          const value=preview(await source.preview(p),p);
          if(closed||cancelled||generation!==epoch){
            const ended=value.state==="ready"?await release(value.copyID,{intent:p,totalBytes:value.totalBytes}):null;
            if(closed)return view;
            return value.state==="ready"?update({phase:ended?.state||"uncertain",copyID:!ended||ended.state==="uncertain"?value.copyID:null,preview:!ended||ended.state==="uncertain"?value:null,result:ended,totalBytes:value.totalBytes,error:ended?ended.error:"unavailable"}):update({phase:"cancelled",copyID:null,preview:null});
          }
          return update({phase:value.state,preview:value,copyID:value.state==="ready"?value.copyID:null,totalBytes:value.totalBytes});
        }catch(error){update({phase:"failed",error:errorCode(error)});throw error;}finally{busy=false;update({phase:closed?"closed":view.phase,busy:false});}
      },
      async confirm(){
        ready();check(view.phase==="ready"&&view.copyID,"denied");busy=true;cancelled=false;const id=view.copyID,binding=expected();let submitted=false,released=false;update({phase:"copying",busy:true,error:null});
        try{
          submitted=true;let value=status(await source.begin(id),id,binding);check(["copying","cancelled","failed"].includes(value.state)&&value.copiedBytes===0);
          if(value.state!=="copying")return finish(value);
          let offset=0;
          do{
            if(cancelled||closed)break;
            value=status(await source.chunk(id,offset),id,binding);check(["copying","completed","failed","uncertain","cancelled"].includes(value.state));
            if(value.state==="copying"||value.state==="completed")check(value.copiedBytes===Math.min(binding.totalBytes,offset+chunkBytes));
            if(value.state!=="copying")return finish(value);
            check(value.copiedBytes>offset&&value.copiedBytes<binding.totalBytes);offset=value.copiedBytes;update({copiedBytes:offset});await yieldChunk();
          }while(true);
          const result=await cancelID(id,binding);if(closed){source.discard(id);released=true;}return finish(result);
        }catch(error){update({phase:submitted?"uncertain":"failed",error:errorCode(error)});throw error;}finally{busy=false;if(closed&&!released){await release(id,binding);}update({phase:closed?"closed":view.phase,busy:false});}
      },
      async cancel(){
        check(!closed,"unavailable");cancelled=true;if(busy)return update({phase:"cancelling"});
        if(view.copyID&&["ready","copying","uncertain"].includes(view.phase)){busy=true;update({busy:true});try{return finish(await cancelID(view.copyID,expected()));}finally{busy=false;update({busy:false});}}return view;
      },
      async check(){
        ready();check(view.phase==="uncertain"&&view.copyID,"denied");busy=true;update({phase:"checking",busy:true});
        try{const value=status(await source.status(view.copyID),view.copyID,expected());return update({phase:["completed","failed","cancelled"].includes(value.state)?value.state:"uncertain",result:value,copiedBytes:value.copiedBytes??view.copiedBytes,error:value.error});}
        catch(error){update({phase:"uncertain",error:errorCode(error)});throw error;}finally{busy=false;update({phase:closed?"closed":view.phase,busy:false});}
      },
      dispose(){if(closed)return;const id=view.copyID,binding=expected(),previous=view.phase;closed=true;cancelled=true;epoch++;if(!busy&&id){if(["ready","copying","uncertain"].includes(previous))void release(id,binding);else source.discard(id);}update({phase:"closed",preview:null,result:null,busy:false});}
    });
  }
  return {chunkBytes,fileBytes,target,intent,preview,status,createSource,createClientSource,createController};
});
