(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"),require("./file-operations.js"),require("./file-copies.js"),require("./sha256.js"));
  else root.MacNASFileCopyFixture=Object.freeze(factory(root.MacNASModel,root.MacNASFileOperations,root.MacNASFileCopies,root.MacNASSHA256));
})(globalThis,function(M,O,C,H){
  "use strict";
  const chunkBytes=32768,fileBytes=16*1024*1024,reservedBytes=64*1024*1024;
  const errors=new Set(["invalidInput","invalidResponse","unsafePath","unsafeFile","collision","invalidSchema","integrity","database","busy","denied","readOnly","expired","replay","staleState","unsupported","interrupted","missingVolume","timedOut","cancelled","budgetExceeded","unavailable"]);
  const check=(value,code="invalidResponse")=>{if(!value)throw new M.ServiceError(code);};
  const errorCode=error=>error instanceof M.ServiceError&&errors.has(error.code)?error.code:"unavailable";
  function createFixtureSource(context,store,{monotonicNow=()=>performance.now()}={}){
    const entries=new Map();let closed=false;
    const clock=()=>{const value=monotonicNow();check(Number.isFinite(value)&&value>=0,"unavailable");return value;};
    const terminal=e=>["completed","cancelled","failed","uncertain"].includes(e.state);
    function end(e,state,error=null){
      e.state=state;e.error=error;e.deadline=clock()+300000;store.release?.(e.id);e.reserved=0;e.buffer=null;e.file=null;e.hash=null;return e;
    }
    function reclaim(){
      const now=clock();
      for(const [id,e]of entries)if(now>=e.deadline||!terminal(e)&&now>=e.absolute){if(terminal(e))entries.delete(id);else end(e,"failed","expired");}
      const receipts=[...entries.values()].filter(terminal).sort((a,b)=>a.deadline-b.deadline);
      for(const e of receipts.slice(0,Math.max(0,receipts.length-32)))entries.delete(e.id);
    }
    function get(id){O.id(id,"invalidInput");reclaim();const e=entries.get(id);check(e,"replay");return e;}
    function dto(e){return{copyVersion:1,copyID:e.id,state:e.state,intent:e.intent,totalBytes:e.totalBytes,copiedBytes:e.offset,chunkBytes,sha256:e.sha256,error:e.error};}
    function live(e){check(!closed,"unavailable");check(clock()<e.deadline&&clock()<e.absolute,"expired");}
    function endpoints(e){
      check(store.readSource(e.intent)===e.file&&store.sourceVersion(e.intent)===e.sourceVersion,"staleState");
      check(store.parentExists(e.intent)&&store.targetVersion(e.intent)===e.targetVersion,"staleState");
    }
    function fail(e,error){if(!terminal(e))end(e,"failed",errorCode(error));reclaim();return dto(e);}
    return C.createSource(context,{
      isClosed:()=>closed,
      dispose(){if(closed)return;closed=true;for(const e of entries.values()){store.release?.(e.id);e.buffer=null;e.file=null;e.hash=null;}entries.clear();},
      async preview(p){
        await store.authorizeCopy(p);reclaim();check(!closed,"unavailable");
        const file=store.readSource(p);check(file instanceof Uint8Array,"denied");check(file.length<=fileBytes,"budgetExceeded");check(store.parentExists(p),"staleState");
        const same=p.sourceLibraryID===p.targetLibraryID&&p.sourcePath===(p.parentPath?p.parentPath+"/":"")+p.name;
        const state=same?"unchanged":store.exists(p)?"conflict":"ready",id=crypto.randomUUID();
        if(state==="ready"){
          check([...entries.values()].filter(e=>!terminal(e)).length<8,"budgetExceeded");const time=clock();
          entries.set(id,{id,intent:p,state:"ready",file,sourceSHA:H.digest(file),sourceVersion:store.sourceVersion(p),targetVersion:store.targetVersion(p),totalBytes:file.length,offset:0,lastOffset:null,sha256:null,error:null,reserved:0,buffer:null,hash:null,deadline:time+30000,absolute:time+1800000});
        }
        return{copyVersion:1,copyID:id,intent:p,state,totalBytes:file.length,chunkBytes,expiresInSeconds:state==="ready"?30:0};
      },
      async begin(id){
        const e=get(id);await store.authorizeCopy(e.intent);check(!closed,"unavailable");if(e.state!=="ready")return dto(e);
        try{
          live(e);endpoints(e);check(H.digest(e.file)===e.sourceSHA,"staleState");
          check(e.totalBytes<=reservedBytes-[...entries.values()].reduce((sum,x)=>sum+x.reserved,0),"budgetExceeded");
          store.reserve?.(id,e.totalBytes);e.reserved=e.totalBytes;e.buffer=new Uint8Array(e.totalBytes);e.hash=new H.SHA256();e.state="copying";e.deadline=clock()+60000;
          return dto(e);
        }catch(error){return fail(e,error);}
      },
      async chunk(id,offset){
        const e=get(id);check(Number.isSafeInteger(offset)&&offset>=0&&offset<=fileBytes,"invalidInput");await store.authorizeCopy(e.intent);check(!closed,"unavailable");
        if(e.lastOffset===offset){if(!terminal(e)){try{live(e);endpoints(e);}catch(error){return fail(e,error);}}return dto(e);}
        check(e.state==="copying"&&offset===e.offset,"replay");
        let published=false;
        try{
          live(e);endpoints(e);const bytes=e.file.slice(offset,Math.min(offset+chunkBytes,e.totalBytes));e.buffer.set(bytes,offset);e.hash.update(bytes);e.offset+=bytes.length;e.lastOffset=offset;e.deadline=clock()+60000;
          endpoints(e);
          if(e.offset===e.totalBytes){
            const digest=e.hash.hex();check(digest===e.sourceSHA&&H.digest(e.file)===digest&&H.digest(e.buffer)===digest,"integrity");
            live(e);endpoints(e);check(!store.exists(e.intent),"collision");store.publish(e.intent,e.buffer,e.id);published=true;e.sha256=digest;
            if(store.readTarget)check(store.readTarget(e.intent)===e.buffer&&H.digest(e.buffer)===digest,"integrity");
            check(store.readSource(e.intent)===e.file&&H.digest(e.file)===digest,"staleState");live(e);end(e,"completed");
          }
          reclaim();return dto(e);
        }catch(error){if(published){end(e,"uncertain",errorCode(error));reclaim();return dto(e);}return fail(e,error);}
      },
      async status(id){
        O.id(id,"invalidInput");await store.authorizeSession();check(!closed,"unavailable");reclaim();const e=entries.get(id);
        if(!e)return{copyVersion:1,copyID:id,state:"notVisible",intent:null,totalBytes:null,copiedBytes:null,chunkBytes,sha256:null,error:null};
        await store.authorizeCopy(e.intent);check(!closed,"unavailable");return dto(e);
      },
      async cancel(id){const e=get(id);await store.authorizeSession();check(!closed,"unavailable");if(!terminal(e))end(e,"cancelled");reclaim();return dto(e);},
      discard(id){const e=entries.get(id);return e&&terminal(e)?entries.delete(id):false;}
    });
  }
  return {createFixtureSource};
});
