(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"),require("./file-operations.js"),require("./sha256.js"));
  else root.MacNASFileTransfers=Object.freeze(factory(root.MacNASModel,root.MacNASFileOperations,root.MacNASSHA256));
})(globalThis,function(M,O,H){
  "use strict";
  const chunkBytes=32768,fileBytes=16*1024*1024,reservedBytes=64*1024*1024,sources=new WeakSet(),encoder=new TextEncoder();
  const errors=new Set(["invalidInput","invalidResponse","unsafePath","unsafeFile","collision","invalidSchema","integrity","database","busy","denied","readOnly","expired","replay","staleState","unsupported","interrupted","missingVolume","timedOut","cancelled","budgetExceeded","unavailable"]);
  const check=(value,code="invalidResponse")=>{if(!value)throw new M.ServiceError(code);};
  const errorCode=error=>error instanceof M.ServiceError&&errors.has(error.code)?error.code:"unavailable";
  function freeze(value){if(value&&typeof value==="object"&&!(value instanceof Uint8Array)){Object.values(value).forEach(freeze);Object.freeze(value);}return value;}
  function fields(value,required,optional=[],code="invalidResponse"){
    check(value&&Object.getPrototypeOf(value)===Object.prototype,code);const ds=Object.getOwnPropertyDescriptors(value),copy={};
    check(required.every(key=>Object.hasOwn(ds,key)),code);
    for(const key of Reflect.ownKeys(ds)){const d=ds[key];check(typeof key==="string"&&[...required,...optional].includes(key)&&d.enumerable&&Object.hasOwn(d,"value"),code);Object.defineProperty(copy,key,{value:d.value,enumerable:true});}return copy;
  }
  function integer(value,max=fileBytes,code="invalidResponse"){check(Number.isSafeInteger(value)&&value>=0&&value<=max,code);return value;}
  function text(value,max,empty=false,code="invalidResponse"){check(typeof value==="string"&&(empty||value.length>0)&&value.isWellFormed()&&!value.includes("\0")&&encoder.encode(value).length<=max,code);return value;}
  function path(value,code="invalidResponse"){text(value,4096,false,code);check(value.split("/").length<=128&&!value.includes("\\")&&value.split("/").every(x=>x&&x!=="."&&x!==".."&&!x.includes(":")),code);return value;}
  function hash(value,code="invalidResponse"){check(typeof value==="string"&&/^[0-9a-f]{64}$/.test(value),code);return value;}
  function intentFields(p,request,code){
    const valid=O.intent({libraryID:p.libraryID,parentPath:Object.hasOwn(p,"parentPath")?p.parentPath:"",kind:"createDirectory",name:p.name},true);
    integer(p.totalBytes,fileBytes,code);return freeze({libraryID:valid.libraryID,parentPath:valid.parentPath,name:valid.name,totalBytes:p.totalBytes});
  }
  function uploadIntent(value,request=false){
    const code=request?"invalidInput":"invalidResponse",p=fields(value,["libraryID","name","totalBytes",...(request?[]:["parentPath"])],request?["parentPath"]:[],code);
    try{return intentFields(p,request,code);}catch(error){throw new M.ServiceError(code);}
  }
  const target=p=>(p.parentPath?p.parentPath+"/":"")+p.name;
  function downloadIntent(value){const p=fields(value,["libraryID","relativePath"],[],"invalidInput");text(p.libraryID,128,false,"invalidInput");path(p.relativePath,"invalidInput");return freeze({...p});}
  function preview(value,expected){
    const p=fields(value,["transferVersion","transferID","intent","state","chunkBytes","expiresInSeconds"]);O.id(p.transferID);
    check(p.transferVersion===1&&p.chunkBytes===chunkBytes&&["ready","conflict"].includes(p.state)&&p.expiresInSeconds===(p.state==="ready"?30:0));
    const captured=uploadIntent(p.intent);if(expected)check(JSON.stringify(captured)===JSON.stringify(expected));return freeze({...p,intent:captured});
  }
  function status(value,id,expected){
    const p=fields(value,["transferVersion","transferID","state","direction","libraryID","relativePath","totalBytes","transferredBytes","chunkBytes","sha256","lastChunkSHA256","error"]);
    O.id(p.transferID);check(p.transferVersion===1&&p.transferID===id&&p.chunkBytes===chunkBytes&&["ready","uploading","downloading","completed","cancelled","failed","uncertain","notVisible"].includes(p.state));
    if(p.state==="notVisible"){check(["direction","libraryID","relativePath","totalBytes","transferredBytes","sha256","lastChunkSHA256","error"].every(key=>p[key]===null));return freeze(p);}
    check(["upload","download"].includes(p.direction));text(p.libraryID,128);path(p.relativePath);integer(p.totalBytes);integer(p.transferredBytes,p.totalBytes);
    if(expected)check(p.direction===expected.direction&&p.libraryID===expected.libraryID&&p.relativePath===expected.relativePath&&(expected.totalBytes===undefined||p.totalBytes===expected.totalBytes));
    if(p.state==="ready")check(p.direction==="upload"&&p.transferredBytes===0);
    if(p.state==="uploading")check(p.direction==="upload");if(p.state==="downloading")check(p.direction==="download");
    if(p.lastChunkSHA256!==null)hash(p.lastChunkSHA256);if(p.transferredBytes>0)check(p.lastChunkSHA256!==null);
    if(p.state==="completed"||p.state==="uncertain"){hash(p.sha256);check(p.transferredBytes===p.totalBytes);if(p.state==="uncertain")check(p.direction==="upload");}
    else check(p.sha256===null);
    if(["failed","uncertain"].includes(p.state))check(errors.has(p.error));else check(p.error===null);
    return freeze(p);
  }
  function parts(bytes){
    check(bytes instanceof Uint8Array&&bytes.length>0&&bytes.length<=chunkBytes,"invalidInput");const result=[];
    for(let i=0;i<bytes.length;i+=2048){let raw="";for(const byte of bytes.subarray(i,i+2048))raw+=String.fromCharCode(byte);result.push(btoa(raw));}return result;
  }
  function decodeParts(values,empty=false,code="invalidResponse"){
    check(Array.isArray(values)&&Object.getPrototypeOf(values)===Array.prototype,code);
    const ds=Object.getOwnPropertyDescriptors(values),length=ds.length?.value;check(Number.isInteger(length)&&length<=16&&(empty||length>0)&&Reflect.ownKeys(ds).length===length+1,code);
    const captured=Array.from({length},(_,index)=>{const d=ds[index];check(d&&d.enumerable&&Object.hasOwn(d,"value"),code);return d.value;});
    const result=new Uint8Array(length*2048);let loaded=0;
    for(const [index,value]of captured.entries()){
      check(typeof value==="string"&&value.length<=2732,code);let raw;try{raw=atob(value);}catch{throw new M.ServiceError(code);}
      check(raw.length>0&&raw.length<=2048&&(index===length-1||raw.length===2048)&&btoa(raw)===value,code);
      for(let i=0;i<raw.length;i++)result[loaded++]=raw.charCodeAt(i);
    }return result.slice(0,loaded);
  }
  function chunk(value,id,offset,total){
    const p=fields(value,["transferVersion","transferID","offset","nextOffset","parts","eof","chunkSHA256","sha256"]);
    check(p.transferVersion===1&&p.transferID===id&&p.offset===offset&&typeof p.eof==="boolean");integer(p.nextOffset,total);
    const bytes=decodeParts(p.parts,true);check(bytes.length===Math.min(chunkBytes,total-offset)&&p.nextOffset===offset+bytes.length&&p.eof===(p.nextOffset===total));
    hash(p.chunkSHA256);check(H.digest(bytes)===p.chunkSHA256,"integrity");if(p.eof)hash(p.sha256);else check(p.sha256===null);return freeze({...p,parts:[...p.parts]});
  }
  function createSource(context,operations){
    check(context&&["fixture","fixture-host"].includes(context.source)&&["administrator","reader"].includes(context.role));
    const binding=freeze({...context});let closed=false;const alive=()=>check(!closed&&!operations.isClosed?.(),"unavailable");
    const writable=()=>{alive();check(binding.mode==="synthetic_development","readOnly");check(binding.role==="administrator","denied");};
    const call=async operation=>{alive();try{const value=await operation();alive();return value;}catch(error){throw new M.ServiceError(errorCode(error));}};
    const source=Object.freeze({context:binding,get closed(){return closed||!!operations.isClosed?.();},get canUpload(){return !this.closed&&binding.mode==="synthetic_development"&&binding.role==="administrator";},
      previewUpload(p){writable();return call(()=>operations.previewUpload(uploadIntent(p,true)));},
      beginUpload(id){writable();O.id(id,"invalidInput");return call(()=>operations.beginUpload(id));},
      appendUpload(id,offset,values){writable();O.id(id,"invalidInput");integer(offset,fileBytes,"invalidInput");return call(()=>operations.appendUpload(id,offset,values));},
      finishUpload(id,digest){writable();O.id(id,"invalidInput");hash(digest,"invalidInput");return call(()=>operations.finishUpload(id,digest));},
      beginDownload(p){alive();return call(()=>operations.beginDownload(downloadIntent(p)));},
      readDownloadChunk(id,offset){alive();O.id(id,"invalidInput");integer(offset,fileBytes,"invalidInput");return call(()=>operations.readDownloadChunk(id,offset));},
      status(id){alive();O.id(id,"invalidInput");return call(()=>operations.status(id));},
      cancel(id){alive();O.id(id,"invalidInput");return call(()=>operations.cancel(id));},
      discard(id){O.id(id,"invalidInput");try{return operations.discard?.(id)??false;}catch{return false;}},
      dispose(){closed=true;operations.dispose?.();}
    });sources.add(source);return source;
  }
  async function createClientSource(client){
    check(client?.source==="fixture-host-client"&&!client.closed&&["overview","previewUpload","beginUpload","appendUpload","finishUpload","beginDownload","readDownloadChunk","transferStatus","cancelTransfer"].every(key=>typeof client[key]==="function"),"unavailable");
    const who=await client.overview();return createSource({source:"fixture-host",userID:who.userID,role:who.role,mode:who.mode},{
      previewUpload:p=>client.previewUpload(p),beginUpload:id=>client.beginUpload(id),appendUpload:(id,offset,values)=>client.appendUpload({transferID:id,offset,parts:values}),finishUpload:(id,sha256)=>client.finishUpload({transferID:id,sha256}),
      beginDownload:p=>client.beginDownload(p),readDownloadChunk:(id,offset)=>client.readDownloadChunk({transferID:id,offset}),status:id=>client.transferStatus(id),cancel:id=>client.cancelTransfer(id),discard:id=>client.discardTransfer(id),isClosed:()=>client.closed
    });
  }
  function createFixtureSource(context,store,{monotonicNow=()=>performance.now()}={}){
    const entries=new Map();let closed=false;
    const clock=()=>{const value=monotonicNow();check(Number.isFinite(value)&&value>=0,"unavailable");return value;};
    const terminal=e=>["completed","cancelled","failed","uncertain"].includes(e.state);
    function end(e,state,error=null){e.state=state;e.error=error;e.deadline=clock()+300000;e.buffer=null;e.file=null;e.reserved=0;if(state!=="completed")e.last=null;return e;}
    function reclaim(){const now=clock();for(const [id,e]of entries)if(now>=e.deadline||!terminal(e)&&now>=e.absolute){if(terminal(e))entries.delete(id);else end(e,"failed","expired");}
      const receipts=[...entries.values()].filter(terminal).sort((a,b)=>a.deadline-b.deadline);for(const e of receipts.slice(0,Math.max(0,receipts.length-32)))entries.delete(e.id);}
    const active=()=>[...entries.values()].filter(e=>!terminal(e)).length;
    function get(id){O.id(id,"invalidInput");reclaim();const e=entries.get(id);check(e,"replay");return e;}
    function dto(e){return {transferVersion:1,transferID:e.id,state:e.state,direction:e.direction,libraryID:e.libraryID,relativePath:e.relativePath,totalBytes:e.totalBytes,transferredBytes:e.offset,chunkBytes,sha256:e.sha256,lastChunkSHA256:e.lastSHA,error:e.error};}
    function entry(direction,p,totalBytes){const time=clock();return{id:crypto.randomUUID(),direction,libraryID:p.libraryID,relativePath:direction==="upload"?target(p):p.relativePath,totalBytes,offset:0,state:direction==="upload"?"ready":"downloading",deadline:time+(direction==="upload"?30000:60000),absolute:time+1800000,sha256:null,lastSHA:null,error:null,reserved:0,intent:p};}
    function parent(e){check(store.parentExists(e.intent)&&store.version(e.intent)===e.version,"staleState");}
    function live(e){check(clock()<e.deadline&&clock()<e.absolute,"expired");}
    function read(e){check(store.read(e.intent)===e.file,"staleState");}
    return createSource(context,{
      isClosed:()=>closed,dispose(){closed=true;entries.clear();},
      async previewUpload(p){await store.authorizeUpload(p);reclaim();check(store.parentExists(p),"staleState");
        const e=entry("upload",p,p.totalBytes),state=store.exists(p)?"conflict":"ready";
        if(state==="ready"){check(active()<8,"budgetExceeded");e.version=store.version(p);entries.set(e.id,e);}
        return {transferVersion:1,transferID:e.id,intent:p,state,chunkBytes,expiresInSeconds:state==="ready"?30:0};
      },
      async beginUpload(id){const e=get(id);check(e.direction==="upload","denied");await store.authorizeUpload(e.intent);
        if(e.state!=="ready")return dto(e);
        try{live(e);parent(e);check(e.totalBytes<=reservedBytes-[...entries.values()].reduce((sum,x)=>sum+x.reserved,0),"budgetExceeded");e.buffer=new Uint8Array(e.totalBytes);e.reserved=e.totalBytes;e.state="uploading";e.deadline=clock()+60000;}
        catch(error){end(e,"failed",errorCode(error));}reclaim();return dto(e);
      },
      async appendUpload(id,offset,values){const bytes=decodeParts(values,false,"invalidInput"),e=get(id);check(e.direction==="upload","denied");await store.authorizeUpload(e.intent);
        if(e.last?.offset===offset){check(e.last.sha256===H.digest(bytes)&&JSON.stringify(e.last.parts)===JSON.stringify(values),"collision");if(!terminal(e)){live(e);parent(e);}return dto(e);}
        check(e.state==="uploading"&&offset===e.offset,"replay");check(bytes.length===Math.min(chunkBytes,e.totalBytes-offset),"invalidInput");
        try{live(e);parent(e);e.buffer.set(bytes,offset);e.offset+=bytes.length;e.lastSHA=H.digest(bytes);e.last={offset,parts:[...values],sha256:e.lastSHA};e.deadline=clock()+60000;}
        catch(error){end(e,"failed",errorCode(error));}reclaim();return dto(e);
      },
      async finishUpload(id,digest){const e=get(id);check(e.direction==="upload","denied");await store.authorizeUpload(e.intent);
        if(e.expected)check(e.expected===digest,"collision");if(terminal(e))return dto(e);check(e.state==="uploading"&&e.offset===e.totalBytes,"invalidInput");e.expected=digest;
        try{live(e);parent(e);check(H.digest(e.buffer)===digest,"integrity");check(!store.exists(e.intent),"collision");store.publish(e.intent,e.buffer);e.sha256=digest;end(e,"completed");}
        catch(error){end(e,"failed",errorCode(error));}reclaim();return dto(e);
      },
      async beginDownload(p){await store.authorizeRead(p);reclaim();const bytes=store.read(p);check(bytes instanceof Uint8Array,"denied");check(bytes.length<=fileBytes&&active()<8,"budgetExceeded");
        const e=entry("download",p,bytes.length);e.file=bytes;e.hash=new H.SHA256();entries.set(e.id,e);return dto(e);
      },
      async readDownloadChunk(id,offset){const e=get(id);check(e.direction==="download","denied");await store.authorizeRead(e.intent);
        if(e.last?.offset===offset){if(!terminal(e)){live(e);read(e);}return e.last;}
        check(e.state==="downloading"&&offset===e.offset,"replay");
        try{live(e);read(e);const bytes=e.file.slice(offset,Math.min(offset+chunkBytes,e.totalBytes));e.hash.update(bytes);e.offset+=bytes.length;
          const eof=e.offset===e.totalBytes,value={transferVersion:1,transferID:id,offset,nextOffset:e.offset,parts:bytes.length?parts(bytes):[],eof,chunkSHA256:H.digest(bytes),sha256:eof?e.hash.hex():null};
          e.lastSHA=value.chunkSHA256;e.last=value;e.deadline=clock()+60000;if(eof){e.sha256=value.sha256;end(e,"completed");}reclaim();return value;
        }catch(error){end(e,"failed",errorCode(error));throw error;}
      },
      async status(id){await store.authorizeSession();reclaim();const e=entries.get(id);if(!e)return{transferVersion:1,transferID:id,state:"notVisible",direction:null,libraryID:null,relativePath:null,totalBytes:null,transferredBytes:null,chunkBytes,sha256:null,lastChunkSHA256:null,error:null};
        await(e.direction==="upload"?store.authorizeUpload(e.intent):store.authorizeRead(e.intent));return dto(e);
      },
      async cancel(id){const e=get(id);await store.authorizeSession();if(!terminal(e))end(e,"cancelled");reclaim();return dto(e);},
      discard(id){const e=entries.get(id);return e&&terminal(e)?entries.delete(id):false;}
    });
  }
  function createController(source,{onChange=()=>{}}={}){
    check(sources.has(source)&&!source.closed&&typeof onChange==="function","invalidInput");let busy=false,cancelled=false,closed=false,file=null,epoch=0;
    let view=freeze({phase:"idle",preview:null,result:null,transferID:null,direction:null,location:null,totalBytes:0,transferredBytes:0,error:null});
    function update(p){if(closed&&p.phase!=="closed")return view;view=freeze({...view,...p});try{onChange(view);}catch{}return view;}
    function ready(){check(!closed&&!source.closed,"unavailable");check(!busy,"busy");}
    async function cancelOwned(){if(view.transferID&&!source.closed)try{const value=status(await source.cancel(view.transferID),view.transferID,expected());check(["cancelled","completed","failed","uncertain"].includes(value.state));return value;}catch{}return null;}
    const expected=()=>view.direction==="upload"&&view.location?{direction:"upload",libraryID:view.location.libraryID,relativePath:view.location.relativePath,totalBytes:view.totalBytes}:null;
    const yieldChunk=()=>new Promise(resolve=>setTimeout(resolve,0));
    return Object.freeze({snapshot:()=>view,get canUpload(){return source.canUpload;},
      async prepareUpload(params,blob){
        ready();check(view.phase!=="uncertain","staleState");check(blob instanceof Blob,"invalidInput");const p=uploadIntent(params,true);check(blob.size===p.totalBytes,"invalidInput");
        const previousReady=view.phase==="ready",previousID=view.transferID;busy=true;cancelled=false;const generation=++epoch;
        if(previousReady)await cancelOwned();if(closed||cancelled){busy=false;return update({phase:closed?"closed":"cancelled"});}file=blob;
        if(previousID)source.discard(previousID);
        update({phase:"previewing",preview:null,result:null,transferID:null,direction:"upload",location:{libraryID:p.libraryID,relativePath:target(p)},totalBytes:p.totalBytes,transferredBytes:0,error:null});
        try{const value=preview(await source.previewUpload(p),p);if(closed||generation!==epoch){if(value.state==="ready")try{await source.cancel(value.transferID);}catch{}return view;}
          if(cancelled){if(value.state==="ready")try{await source.cancel(value.transferID);}catch{}file=null;return update({phase:"cancelled",preview:null,transferID:null});}
          return update({phase:value.state,preview:value,transferID:value.transferID});}
        catch(error){update({phase:"failed",error:errorCode(error)});throw error;}finally{busy=false;}
      },
      async startUpload(){
        ready();check(view.phase==="ready"&&file,"denied");busy=true;cancelled=false;const id=view.transferID,p=view.preview,blob=file;let submitted=false;
        update({phase:"uploading",error:null});
        try{
          submitted=true;let value=status(await source.beginUpload(id),id,expected());check(["uploading","failed","cancelled"].includes(value.state));
          if(value.state!=="uploading")return update({phase:value.state,result:value,error:value.error});
          const digest=new H.SHA256();
          for(let offset=0;offset<p.intent.totalBytes;offset+=chunkBytes){
            if(cancelled||closed)break;
            const block=new Uint8Array(await blob.slice(offset,Math.min(offset+chunkBytes,blob.size)).arrayBuffer());
            check(block.length===Math.min(chunkBytes,blob.size-offset),"integrity");if(cancelled||closed)break;
            value=status(await source.appendUpload(id,offset,parts(block)),id,expected());
            if(value.state!=="uploading")return update({phase:value.state,result:value,error:value.error});
            check(value.transferredBytes===offset+block.length&&value.lastChunkSHA256===H.digest(block));digest.update(block);update({transferredBytes:value.transferredBytes});await yieldChunk();
          }
          if(cancelled||closed){value=await cancelOwned();return update({phase:value?.state||"uncertain",result:value,error:value?null:"unavailable"});}
          update({phase:"verifying"});value=status(await source.finishUpload(id,digest.hex()),id,expected());check(["completed","failed","uncertain"].includes(value.state));
          if(value.state==="completed")check(value.sha256===digest.hex(),"integrity");return update({phase:value.state,result:value,transferredBytes:value.transferredBytes,error:value.error});
        }catch(error){update({phase:submitted?"uncertain":"failed",error:errorCode(error)});throw error;}finally{busy=false;file=null;if(closed)source.discard(id);}
      },
      async download(params,sink){
        ready();check(view.phase!=="uncertain","staleState");const p=downloadIntent(params);check(sink&&["write","finish","abort"].every(key=>typeof sink[key]==="function"),"invalidInput");
        const previousReady=view.phase==="ready",previousID=view.transferID;busy=true;cancelled=false;if(previousReady)await cancelOwned();file=null;
        if(closed||cancelled){await sink.abort();busy=false;return update({phase:closed?"closed":"cancelled"});}
        if(previousID)source.discard(previousID);let ownedID=null;
        update({phase:"startingDownload",preview:null,result:null,transferID:null,direction:"download",location:p,totalBytes:0,transferredBytes:0,error:null});
        try{
          const begun=await source.beginDownload(p),id=O.id(begun.transferID);status(begun,id,{direction:"download",...p});check(begun.state==="downloading"&&begun.transferredBytes===0);
          ownedID=id;
          if(closed||cancelled){try{await source.cancel(id);}catch{}await sink.abort();return update({phase:"cancelled"});}
          update({phase:"downloading",transferID:id,totalBytes:begun.totalBytes});const digest=new H.SHA256();let offset=0;
          do{
            if(cancelled||closed)break;
            const block=chunk(await source.readDownloadChunk(id,offset),id,offset,begun.totalBytes),bytes=decodeParts(block.parts,true);digest.update(bytes);
            if(cancelled||closed)break;
            await sink.write(bytes);offset=block.nextOffset;update({transferredBytes:offset});await yieldChunk();
            if(block.eof){check(block.sha256===digest.hex(),"integrity");if(cancelled||closed)break;
              const result=status(await source.status(id),id,{direction:"download",...p,totalBytes:begun.totalBytes});check(result.state==="completed"&&result.sha256===digest.hex(),"integrity");
              if(cancelled||closed)break;await sink.finish();return update({phase:"completed",result});}
          }while(true);
          await sink.abort();const result=await cancelOwned();return update({phase:"cancelled",result,error:null});
        }catch(error){try{await sink.abort();}catch{}await cancelOwned();update({phase:"failed",error:errorCode(error)});throw error;}finally{busy=false;if(closed&&ownedID)source.discard(ownedID);}
      },
      async cancel(){
        check(!closed,"unavailable");cancelled=true;if(busy)return update({phase:"cancelling"});
        if(view.transferID&&["ready","uploading","downloading","uncertain"].includes(view.phase)){busy=true;try{const value=await cancelOwned();file=null;return update({phase:value?.state||"uncertain",result:value,error:value?null:"unavailable"});}finally{busy=false;}}return view;
      },
      async check(){
        ready();check(view.phase==="uncertain"&&view.transferID,"denied");busy=true;
        try{const value=status(await source.status(view.transferID),view.transferID,expected());
          return update({phase:["completed","failed","cancelled"].includes(value.state)?value.state:"uncertain",result:value,transferredBytes:value.transferredBytes??view.transferredBytes,error:value.error});}
        finally{busy=false;}
      },
      dispose(){if(closed)return;const id=view.transferID;cancelled=true;closed=true;epoch++;file=null;if(!busy&&id){if(["ready","uncertain"].includes(view.phase))void cancelOwned().finally(()=>source.discard(id));else source.discard(id);}update({phase:"closed",preview:null,result:null});}
    });
  }
  return {chunkBytes,fileBytes,reservedBytes,uploadIntent,downloadIntent,preview,status,chunk,parts,decodeParts,target,createSource,createClientSource,createFixtureSource,createController};
});
