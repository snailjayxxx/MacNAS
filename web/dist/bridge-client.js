(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./model.js"),require("./file-operations.js"),require("./file-transfers.js"),require("./sha256.js"),require("./file-copies.js"),require("./recycle-observation.js"));
  else root.MacNASBridgeClient = Object.freeze(factory(root.MacNASModel,root.MacNASFileOperations,root.MacNASFileTransfers,root.MacNASSHA256,root.MacNASFileCopies,root.MacNASRecycleObservation));
})(globalThis, function (M,O,T,H,C,R) {
  "use strict";
  const fail = code => { throw new M.ServiceError(code); };
  const check = (value, code = "invalidResponse") => { if (!value) fail(code); };
  const encoder = new TextEncoder();
  const volumeStates = ["missing","ambiguous","systemVolume","authorizationRequired","readOnly","needsBinding","identityChanged","readyReadOnly","readyReadWrite"];
  const modes = ["synthetic_development","read_only_recovery","rolled_back_recovery"];
  const lastErrors = ["unsafePath","unsafeFile","collision","invalidSchema","integrity","database","busy","denied","expired","replay","staleState","unsupported","interrupted","missingVolume","timedOut","cancelled","budgetExceeded","pluginFailed","unavailable"];

  function fields(value, required, optional = [], code = "invalidResponse") {
    check(value && Object.getPrototypeOf(value) === Object.prototype, code);
    const descriptors = Object.getOwnPropertyDescriptors(value), keys = Reflect.ownKeys(descriptors);
    check(keys.every(key => typeof key === "string" && [...required,...optional].includes(key)), code);
    check(required.every(key => Object.hasOwn(descriptors,key)), code);
    const result = {};
    for (const key of keys) {
      const property = descriptors[key];
      check(property.enumerable && Object.hasOwn(property,"value"), code);
      Object.defineProperty(result,key,{value:property.value,enumerable:true});
    }
    return result;
  }
  function text(value, bytes = 128, { empty = false, nul = false, code = "invalidResponse" } = {}) {
    check(typeof value === "string" && (empty || value.length > 0) && value.length <= bytes, code);
    for (let i=0;i<value.length;i++) {
      const unit=value.charCodeAt(i);
      if (unit>=0xD800 && unit<=0xDBFF) { const next=value.charCodeAt(++i);check(next>=0xDC00 && next<=0xDFFF,code); }
      else check(!(unit>=0xDC00 && unit<=0xDFFF),code);
    }
    check((nul || !value.includes("\0")) && encoder.encode(value).length <= bytes, code);
    return value;
  }
  function integer(value, minimum = 0, maximum = Number.MAX_SAFE_INTEGER, code = "invalidResponse") {
    check(Number.isSafeInteger(value) && value >= minimum && value <= maximum, code);return value;
  }
  function array(value, maximum) { check(Array.isArray(value) && value.length <= maximum);return value; }
  function freeze(value) { if (value && typeof value === "object") { for (const item of Object.values(value)) freeze(item);Object.freeze(value); }return value; }
  function path(value, empty = false, code = "invalidResponse") {
    text(value,4096,{empty,code});if (empty && value === "") return value;
    const parts=value.split("/");
    check(parts.length<=128 && !value.includes("\\") && parts.every(part=>part && part!=="." && part!==".." && !part.includes(":")),code);
    return value;
  }
  function unique(values, key) { const keys=values.map(key);check(new Set(keys).size===keys.length);return values; }
  function cursorToken(value,code="invalidResponse") {
    check(typeof value==="string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value),code);return value;
  }
  function byteOrder(a,b) {
    const x=encoder.encode(a),y=encoder.encode(b),length=Math.min(x.length,y.length);
    for(let i=0;i<length;i++)if(x[i]!==y[i])return x[i]-y[i];return x.length-y.length;
  }
  function library(value) {
    const v=fields(value,["libraryID","volumeID","estimatedBytes","state"]);
    text(v.libraryID);text(v.volumeID,36);check(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v.volumeID));
    integer(v.estimatedBytes);check(volumeStates.includes(v.state));return value;
  }
  function libraries(value) { return unique(array(value,1024).map(library),v=>v.libraryID); }
  function overview(value) {
    const v=fields(value,["apiVersion","source","userID","role","mode","languages","databaseSchema","active","completed","logicalReferenceBytes","physicalPool","taskTimestampsAvailable","libraries"]);
    check(v.apiVersion===1 && v.source==="fixture-host" && [3,4,5,6].includes(v.databaseSchema) && v.physicalPool==="unbound" && v.taskTimestampsAvailable===false);
    text(v.userID);check(["administrator","reader"].includes(v.role) && modes.includes(v.mode));
    check(Array.isArray(v.languages) && v.languages.length>=1 && v.languages.length<=2 && v.languages.every(x=>["zh-CN","ja-JP"].includes(x)) && new Set(v.languages).size===v.languages.length);
    integer(v.active);integer(v.completed);integer(v.logicalReferenceBytes);
    const sum=libraries(v.libraries).reduce((total,lib)=>integer(total+lib.estimatedBytes),0);
    check(sum===v.logicalReferenceBytes);return value;
  }
  function job(value, binding) {
    const v=fields(value,["id","idempotency_key","kind","owner_user","titleKey","state","attempts","max_attempts","effects","revision","checkpoint"],["app_id","title","last_error"]);
    text(v.id);text(v.idempotency_key);check(v.owner_user===binding.userID && (!Object.hasOwn(v,"app_id") || v.app_id===null));
    check(["label","fixtureHash"].includes(v.kind) && M.states.includes(v.state));
    check(v.titleKey===(v.kind==="label"?"jobLabels":"jobHash"));
    if (v.kind==="label") text(v.title,1024,{empty:true});else check(!Object.hasOwn(v,"title"));
    integer(v.max_attempts,1,8);integer(v.attempts,0,v.max_attempts);integer(v.effects,0,1);integer(v.revision,1);
    if (Object.hasOwn(v,"last_error")) check(lastErrors.includes(v.last_error));
    const checkpoint=fields(v.checkpoint,[],["step","sha256","bytes"]);
    if (Object.hasOwn(checkpoint,"step")) check(["prepared","completed"].includes(checkpoint.step));
    if (Object.hasOwn(checkpoint,"sha256")) check(v.kind==="fixtureHash" && typeof checkpoint.sha256==="string" && /^[0-9a-f]{64}$/.test(checkpoint.sha256));
    if (Object.hasOwn(checkpoint,"bytes")) check(v.kind==="fixtureHash" && typeof checkpoint.bytes==="string" && /^(0|[1-9][0-9]{0,6})$/.test(checkpoint.bytes) && Number(checkpoint.bytes)<=1000000);
    check(v.state==="completed" ? v.effects===1 && checkpoint.step==="completed" && v.attempts>=1 : v.effects===0 && checkpoint.step!=="completed");
    if (v.state==="running") check(v.attempts>=1);
    return value;
  }
  function event(value) {
    const v=fields(value,["sequence","job_id","revision","type","state"]);
    integer(v.sequence,1);integer(v.revision,1);text(v.job_id);
    const states={queued:["queued"],claimed:["running"],checkpoint:["running"],completed:["completed"],cancelled:["cancelled"],deferred:["queued","waiting_for_volume","failed"],failed:["failed"]};
    check(typeof v.type==="string" && Object.hasOwn(states,v.type) && states[v.type].includes(v.state));return value;
  }
  function consumerStatus(value,consumerID) {
    const v=fields(value,["statusVersion","consumerID","visibility","acknowledgedThrough","deliveredThrough"]);
    check(v.statusVersion===1 && v.consumerID===consumerID && ["visible","notVisible"].includes(v.visibility));
    if(v.visibility==="visible") { integer(v.acknowledgedThrough);integer(v.deliveredThrough,v.acknowledgedThrough); }
    else check(v.acknowledgedThrough===null && v.deliveredThrough===null);
    return value;
  }
  function eventContext(value,binding) {
    const v=fields(value,["contextVersion","source","scopeID","userID","role","mode"]);
    check(v.contextVersion===1 && v.source==="fixture-host" && typeof v.scopeID==="string" && /^[0-9a-f]{64}$/.test(v.scopeID));
    check(["userID","role","mode"].every(key=>v[key]===binding[key]),"denied");
    return value;
  }
  function file(value, parent) {
    const v=fields(value,["name","relativePath","kind","modifiedAt"],["bytes"]);
    text(v.name,1024);check(!v.name.includes("/"));path(v.relativePath);check(v.relativePath===(parent?parent+"/":"")+v.name);
    check(["directory","file"].includes(v.kind));
    if (v.kind==="file") integer(v.bytes);else check(!Object.hasOwn(v,"bytes"));
    text(v.modifiedAt,20);check(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(v.modifiedAt));
    const time=new Date(v.modifiedAt);check(Number.isFinite(time.getTime()) && time.toISOString().slice(0,19)+"Z"===v.modifiedAt);
    return value;
  }
  function options(value = {}) {
    const v=fields(value,[],["signal"],"invalidInput");
    if (v.signal!==undefined) check(typeof AbortSignal!=="undefined" && v.signal instanceof AbortSignal,"invalidInput");
    return v;
  }
  function uuid() { check(typeof globalThis.crypto?.randomUUID==="function","unavailable");return globalThis.crypto.randomUUID(); }
  function labelParams(value) {
    const v=fields(value,["id","key","value"],[],"invalidInput");
    text(v.id,128,{code:"invalidInput"});text(v.key,128,{code:"invalidInput"});text(v.value,1024,{code:"invalidInput"});check(v.value.trim(),"invalidInput");
    // The host enforces its 80-grapheme limit; the client also checks when the platform provides segmentation.
    if (typeof Intl.Segmenter==="function") check([...new Intl.Segmenter(undefined,{granularity:"grapheme"}).segment(v.value)].length<=80,"invalidInput");
    return {id:v.id,key:v.key,value:v.value};
  }
  function prepareLabelJob(value) { return freeze(labelParams({id:"label-"+uuid(),key:"label-key-"+uuid(),value})); }

  function createDesktopClient(configuration = {}) {
    const config=fields(configuration,["transport"],["closeTransport","timeoutMs","maximumPending"],"invalidInput");
    const {transport,closeTransport}=config,timeoutMs=Object.hasOwn(config,"timeoutMs")?config.timeoutMs:15000,maximumPending=Object.hasOwn(config,"maximumPending")?config.maximumPending:32;
    check(typeof transport==="function" && (closeTransport===undefined || typeof closeTransport==="function"),"invalidInput");
    integer(timeoutMs,1,60000,"invalidInput");integer(maximumPending,1,128,"invalidInput");
    check(typeof AbortController!=="undefined","unavailable");
    const adapter=M.createBridgeAdapter(transport,{requestIdPrefix:"dc-"+uuid()}),pending=new Set(),consumers=new Map(),statusQueries=new Set(),pages=new Map(),busyPages=new Set(),directories=new Map(),busyDirectories=new Set(),fileOperations=new Map(),operationQueries=new Set();
    let operationHeads=0;
    const transfers=new Map(),busyTransfers=new Set();let transferHeads=0;
    const copies=new Map(),busyCopies=new Set();let copyHeads=0;
    let closed=false,binding,eventBinding,recycleObservationBinding;
    function close() {
      if (closed) return;closed=true;binding=undefined;eventBinding=undefined;recycleObservationBinding=undefined;consumers.clear();statusQueries.clear();pages.clear();busyPages.clear();directories.clear();busyDirectories.clear();fileOperations.clear();operationQueries.clear();
      for (const entry of [...pending]) entry.cancel();
      transfers.clear();busyTransfers.clear();copies.clear();busyCopies.clear();recycleObservationQueries.clear();
      if (closeTransport) { try { Promise.resolve(closeTransport()).catch(()=>{}); } catch {} }
    }
    function caller(write = false, administrator = false) {
      check(!closed && binding,"unavailable");
      if (write) check(binding.mode==="synthetic_development","readOnly");
      if (administrator) check(binding.role==="administrator","denied");
      return binding;
    }
    function invoke(method,params,validate,rawOptions) {
      const {signal}=options(rawOptions);check(!closed,"unavailable");check(!signal?.aborted,"cancelled");check(pending.size<maximumPending,"busy");
      return new Promise((resolve,reject)=>{
        const controller=new AbortController();let settled=false,timer;
        function finish(error,value) {
          if (settled) return;const result=error?undefined:freeze(value);
          settled=true;clearTimeout(timer);signal?.removeEventListener("abort",abort);pending.delete(entry);
          if (error) reject(error);else resolve(result);
        }
        function abort() { controller.abort();finish(new M.ServiceError("cancelled"));close(); }
        const entry={cancel(){controller.abort();finish(new M.ServiceError("cancelled"));}};
        pending.add(entry);signal?.addEventListener("abort",abort,{once:true});
        timer=setTimeout(()=>{controller.abort();finish(new M.ServiceError("timedOut"));close();},timeoutMs);
        adapter.request(method,params,{signal:controller.signal}).then(value=>{
          if (settled || closed) return;
          try { finish(null,validate(value)); }
          catch (error) { finish(new M.ServiceError(error instanceof M.ServiceError && error.code==="denied"?"denied":"invalidResponse"));close(); }
        },error=>{
          if (settled || closed) return;
          const code=error instanceof M.ServiceError?error.code:"unavailable";
          finish(new M.ServiceError(code));if (["unavailable","invalidResponse","timedOut"].includes(code)) close();
        });
      });
    }
    function consumer(id) {
      text(id,128,{code:"invalidInput"});
      check(!statusQueries.has(id),"busy");
      if (!consumers.has(id)) { check(consumers.size<32,"budgetExceeded");consumers.set(id,{ack:0,seen:new Map(),busy:false}); }
      const value=consumers.get(id);check(!value.busy,"busy");return value;
    }
    async function transferCall(id,operation){
      O.id(id,"invalidInput");check(!busyTransfers.has(id),"busy");busyTransfers.add(id);
      try{return await operation();}finally{busyTransfers.delete(id);}
    }
    async function copyCall(id,operation){
      O.id(id,"invalidInput");check(!busyCopies.has(id),"busy");busyCopies.add(id);
      try{return await operation();}finally{busyCopies.delete(id);}
    }
    function ownedCopy(id){O.id(id,"invalidInput");const saved=copies.get(id);check(saved,"denied");return saved;}
    function ownedTransfer(id,direction){
      O.id(id,"invalidInput");const saved=transfers.get(id);check(saved&&saved.expected.direction===direction,"denied");return saved;
    }
    const recycleObservationQueries=new Set();
    return Object.freeze({
      source:"fixture-host-client",get closed(){return closed;},close,
      async overview(opts) {
        return invoke("overview",{},value=>{
          overview(value);
          if (binding) check(["userID","role","mode","databaseSchema"].every(key=>binding[key]===value[key]),"denied");
          else binding=Object.freeze({userID:value.userID,role:value.role,mode:value.mode,databaseSchema:value.databaseSchema});
          return value;
        },opts);
      },
      async authorizeApp(id,opts) { caller();check(M.apps.includes(id),"invalidInput");return invoke("authorizeApp",{id},value=>{check(value===true);return value;},opts); },
      async listJobs(opts) {
        const who=caller();return invoke("listJobs",{},value=>{
          const jobs=array(value,4096).map(v=>job(v,who));unique(jobs,v=>v.id);unique(jobs,v=>v.idempotency_key);return jobs;
        },opts);
      },
      async listJobsPage(params={},opts) {
        const who=caller(),p=fields(params,[],["pageSize","cursor"],"invalidInput");
        const pageSize=integer(Object.hasOwn(p,"pageSize")?p.pageSize:50,1,100,"invalidInput");
        const cursor=Object.hasOwn(p,"cursor")?cursorToken(p.cursor,"invalidInput"):undefined;
        const previous=cursor===undefined?undefined:pages.get(cursor);
        if(cursor!==undefined) {
          check(previous && previous.pageSize===pageSize,"denied");check(!busyPages.has(cursor),"busy");
        } else check(pages.size<128,"budgetExceeded");
        if(cursor!==undefined)busyPages.add(cursor);
        try {return await invoke("listJobsPage",cursor===undefined?{pageSize}:{pageSize,cursor},value=>{
          const v=fields(value,["pageVersion","order","consistency","pageSize","items","nextCursor"]);
          check(v.pageVersion===1 && v.order==="id-utf8" && v.consistency==="live" && v.pageSize===pageSize);
          const items=array(v.items,pageSize).map(x=>job(x,who));unique(items,x=>x.id);unique(items,x=>x.idempotency_key);
          let after=previous?.after;
          for(const item of items) {if(after!==undefined)check(byteOrder(after,item.id)<0);after=item.id;}
          if(v.nextCursor!==null) {
            cursorToken(v.nextCursor);check(items.length===pageSize && v.nextCursor!==cursor && !pages.has(v.nextCursor));
            check(pages.size-(cursor===undefined?0:1)<128);
          }
          if(cursor!==undefined)pages.delete(cursor);
          if(v.nextCursor!==null)pages.set(v.nextCursor,{pageSize,after});
          return value;
        },opts);}catch(error){
          if(cursor!==undefined && ["expired","denied","replay"].includes(error.code))pages.delete(cursor);
          throw error;
        }finally{if(cursor!==undefined)busyPages.delete(cursor);}
      },
      discardJobPage(cursor) {
        caller();cursorToken(cursor,"invalidInput");check(!busyPages.has(cursor),"busy");
        return pages.delete(cursor); // Local ownership only; the host capability expires independently.
      },
      async submitLabelJob(params,opts) {
        const who=caller(true,true),p=labelParams(params);
        return invoke("submitLabelJob",p,value=>{job(value,who);check(value.kind==="label" && value.idempotency_key===p.key && value.title===p.value);return value;},opts);
      },
      async cancelJob(id,opts) {
        const who=caller(true);text(id,128,{code:"invalidInput"});
        return invoke("cancelJob",{id},value=>{job(value,who);check(value.id===id && ["completed","failed","cancelled"].includes(value.state));return value;},opts);
      },
      async pollEvents(consumerID,limit=50,opts) {
        caller(true);integer(limit,1,100,"invalidInput");const state=consumer(consumerID);state.busy=true;
        try { return await invoke("pollEvents",{consumerID,limit},value=>{
          const events=array(value,limit).map(event);let previous=state.ack;
          for (const item of events) {
            check(item.sequence>previous);previous=item.sequence;
            const old=state.seen.get(item.sequence);
            if (old) check(["job_id","revision","type","state"].every(key=>old[key]===item[key]));
          }
          const merged=new Map(state.seen);for(const item of events) merged.set(item.sequence,item);
          check(merged.size<=100);state.seen=merged;return events;
        },opts); } finally {state.busy=false;}
      },
      async acknowledgeEvents(consumerID,through,opts) {
        caller(true);integer(through,0,Number.MAX_SAFE_INTEGER,"invalidInput");text(consumerID,128,{code:"invalidInput"});
        check(consumers.has(consumerID),"denied");const state=consumer(consumerID);
        check(through>=state.ack && (through===state.ack || state.seen.has(through)),"denied");state.busy=true;
        try {return await invoke("acknowledgeEvents",{consumerID,through},value=>{
          check(value===true);state.ack=through;for(const sequence of state.seen.keys())if(sequence<=through)state.seen.delete(sequence);return true;
        },opts);}finally{state.busy=false;}
      },
      async eventConsumerStatus(consumerID,opts) {
        caller();text(consumerID,128,{code:"invalidInput"});
        check(!/[\r\n]/.test(consumerID),"invalidInput");
        check(!statusQueries.has(consumerID) && !consumers.get(consumerID)?.busy,"busy");statusQueries.add(consumerID);
        try {return await invoke("eventConsumerStatus",{consumerID},value=>consumerStatus(value,consumerID),opts);}
        finally{statusQueries.delete(consumerID);}
      },
      async eventConsumerObservation(consumerID,opts) {
        const who=caller();text(consumerID,128,{code:"invalidInput"});check(!/[\r\n]/.test(consumerID),"invalidInput");
        check(!statusQueries.has(consumerID) && !consumers.get(consumerID)?.busy,"busy");statusQueries.add(consumerID);
        try {return await invoke("eventConsumerObservation",{consumerID},value=>{
          const v=fields(value,["observationVersion","context","status"]);check(v.observationVersion===1);
          eventContext(v.context,who);consumerStatus(v.status,consumerID);
          if(eventBinding)check(v.context.scopeID===eventBinding.scopeID,"denied");
          else eventBinding=v.context;
          return value; // Source equality and durable observation only; never seed ACK/seen or authorize writes.
        },opts);}finally{statusQueries.delete(consumerID);}
      },
      async observeRecycleOperation(operationID,opts) {
        const who=caller(false,true);check([4,5,6].includes(who.databaseSchema),"unsupported");cursorToken(operationID,"invalidInput");
        check(!recycleObservationQueries.has(operationID),"busy");check(recycleObservationQueries.size<8,"budgetExceeded");
        recycleObservationQueries.add(operationID);
        try{return await invoke("observeRecycleOperation",{operationID},value=>{
          const v=fields(value,["observationEnvelopeVersion","context","observation"]);check(v.observationEnvelopeVersion===1);
          const context=fields(v.context,["contextVersion","source","scopeID","userID","role","mode"]);
          check(context.contextVersion===1&&context.source==="fixture-host"&&typeof context.scopeID==="string"&&/^[0-9a-f]{64}$/.test(context.scopeID));
          check(["userID","role","mode"].every(key=>context[key]===who[key]),"denied");
          const body=R.observation(v.observation,{operationID,ownerUserID:who.userID});
          if(recycleObservationBinding)check(context.scopeID===recycleObservationBinding.scopeID,"denied");
          else recycleObservationBinding=Object.freeze(context);
          return body;
        },opts);}
        finally{recycleObservationQueries.delete(operationID);}
      },
      async listLibraries(opts) { caller();return invoke("listLibraries",{},libraries,opts); },
      async listFiles(params,opts) {
        caller();const v=fields(params,["libraryID"],["relativePath","maximumEntries"],"invalidInput");
        const libraryID=text(v.libraryID,128,{code:"invalidInput"}),relativePath=path(Object.hasOwn(v,"relativePath")?v.relativePath:"",true,"invalidInput"),maximumEntries=integer(Object.hasOwn(v,"maximumEntries")?v.maximumEntries:1000,1,1000,"invalidInput");
        return invoke("listFiles",{libraryID,relativePath,maximumEntries},value=>unique(array(value,maximumEntries).map(v=>file(v,relativePath)),v=>v.name.normalize("NFC").toLowerCase()),opts);
      },
      async listFilesPage(params,opts) {
        caller();const p=fields(params,["libraryID"],["relativePath","pageSize","cursor"],"invalidInput");
        const libraryID=text(p.libraryID,128,{code:"invalidInput"}),relativePath=path(Object.hasOwn(p,"relativePath")?p.relativePath:"",true,"invalidInput");
        const pageSize=integer(Object.hasOwn(p,"pageSize")?p.pageSize:50,1,100,"invalidInput"),cursor=Object.hasOwn(p,"cursor")?cursorToken(p.cursor,"invalidInput"):undefined;
        const previous=cursor===undefined?undefined:directories.get(cursor);
        if(cursor!==undefined) { check(previous && previous.libraryID===libraryID && previous.relativePath===relativePath && previous.pageSize===pageSize,"denied");check(!busyDirectories.has(cursor),"busy"); }
        else check(directories.size<64,"budgetExceeded");
        if(cursor!==undefined)busyDirectories.add(cursor);
        try {return await invoke("listFilesPage",cursor===undefined?{libraryID,relativePath,pageSize}:{libraryID,relativePath,pageSize,cursor},value=>{
          const v=fields(value,["pageVersion","order","consistency","libraryID","relativePath","pageSize","items","nextCursor"]);
          check(v.pageVersion===1 && v.order==="name-utf8" && v.consistency==="directory-stamped-live-metadata" && v.libraryID===libraryID && v.relativePath===relativePath && v.pageSize===pageSize);
          const items=unique(array(v.items,pageSize).map(item=>file(item,relativePath)),item=>item.name.normalize("NFC").toLowerCase());
          let after=previous?.after;
          for(const item of items) { if(after!==undefined)check(byteOrder(after,item.name)<0);after=item.name; }
          if(v.nextCursor!==null) {
            cursorToken(v.nextCursor);check(items.length===pageSize && v.nextCursor!==cursor && !directories.has(v.nextCursor));
            check(directories.size-(cursor===undefined?0:1)<64);
          }
          if(cursor!==undefined)directories.delete(cursor);
          if(v.nextCursor!==null)directories.set(v.nextCursor,{libraryID,relativePath,pageSize,after});
          return value;
        },opts);}catch(error){
          if(cursor!==undefined && ["expired","denied","replay","staleState","missingVolume"].includes(error.code))directories.delete(cursor);
          throw error;
        }finally{if(cursor!==undefined)busyDirectories.delete(cursor);}
      },
      discardFilePage(cursor) {
        caller();cursorToken(cursor,"invalidInput");check(!busyDirectories.has(cursor),"busy");return directories.delete(cursor);
      },
      async previewFileOperation(params,opts) {
        caller(true,true);const captured=O.intent(params,true);check(fileOperations.size+operationHeads<32,"budgetExceeded");operationHeads++;
        const request={libraryID:captured.libraryID,parentPath:captured.parentPath,kind:captured.kind,name:captured.name};if(captured.sourceName!==null)request.sourceName=captured.sourceName;
        try{return await invoke("previewFileOperation",request,value=>{
          const p=O.preview(value,captured);check(!fileOperations.has(p.operationID));
          if(p.state==="ready")fileOperations.set(p.operationID,{intent:captured,submitted:false});return p;
        },opts);}finally{operationHeads--;}
      },
      async commitFileOperation(operationID,opts) {
        caller(true,true);O.id(operationID,"invalidInput");const saved=fileOperations.get(operationID);
        check(saved&&!saved.submitted,"denied");check(!operationQueries.has(operationID),"busy");
        saved.submitted=true;operationQueries.add(operationID);
        try{return await invoke("commitFileOperation",{operationID,confirmed:true},value=>{const p=O.result(value,operationID,saved.intent);check(["completed","failed","uncertain"].includes(p.state));return p;},opts);}
        finally{operationQueries.delete(operationID);}
      },
      async fileOperationStatus(operationID,opts) {
        caller();O.id(operationID,"invalidInput");check(!operationQueries.has(operationID),"busy");operationQueries.add(operationID);
        try{return await invoke("fileOperationStatus",{operationID},value=>O.result(value,operationID,fileOperations.get(operationID)?.intent),opts);}
        finally{operationQueries.delete(operationID);}
      },
      discardFileOperation(operationID) {O.id(operationID,"invalidInput");check(!operationQueries.has(operationID),"busy");return fileOperations.delete(operationID);},
      async previewUpload(params,opts){
        caller(true,true);const p=T.uploadIntent(params,true);check(transfers.size+transferHeads<40,"budgetExceeded");transferHeads++;
        try{return await invoke("previewUpload",p,value=>{
          const v=T.preview(value,p);check(!transfers.has(v.transferID));
          if(v.state==="ready")transfers.set(v.transferID,{expected:{direction:"upload",libraryID:p.libraryID,relativePath:T.target(p),totalBytes:p.totalBytes},state:"ready",offset:0,blocked:false});return v;
        },opts);}finally{transferHeads--;}
      },
      async beginUpload(transferID,opts){
        caller(true,true);const saved=ownedTransfer(transferID,"upload");check(saved.state==="ready"&&!saved.blocked,"denied");
        return transferCall(transferID,async()=>{saved.blocked=true;return invoke("beginUpload",{transferID,confirmed:true},value=>{
          const v=T.status(value,transferID,saved.expected);check(["uploading","failed","cancelled"].includes(v.state)&&v.transferredBytes===0);
          saved.state=v.state;saved.blocked=false;return v;
        },opts);});
      },
      async appendUpload(params,opts){
        caller(true,true);const p=fields(params,["transferID","offset","parts"],[],"invalidInput"),saved=ownedTransfer(p.transferID,"upload");
        integer(p.offset,0,T.fileBytes,"invalidInput");const bytes=T.decodeParts(p.parts,false,"invalidInput"),captured=[...p.parts];
        check(saved.state==="uploading"&&!saved.blocked&&p.offset===saved.offset,"denied");check(bytes.length===Math.min(T.chunkBytes,saved.expected.totalBytes-p.offset),"invalidInput");
        return transferCall(p.transferID,async()=>{saved.blocked=true;return invoke("appendUpload",{transferID:p.transferID,offset:p.offset,parts:captured},value=>{
          const v=T.status(value,p.transferID,saved.expected);check(["uploading","failed"].includes(v.state));
          if(v.state==="uploading")check(v.transferredBytes===p.offset+bytes.length&&v.lastChunkSHA256===H.digest(bytes));
          saved.state=v.state;saved.offset=v.transferredBytes;saved.blocked=false;return v;
        },opts);});
      },
      async finishUpload(params,opts){
        caller(true,true);const p=fields(params,["transferID","sha256"],[],"invalidInput"),saved=ownedTransfer(p.transferID,"upload");
        text(p.sha256,64,{code:"invalidInput"});check(/^[0-9a-f]{64}$/.test(p.sha256),"invalidInput");
        check(saved.state==="uploading"&&!saved.blocked&&saved.offset===saved.expected.totalBytes,"denied");
        return transferCall(p.transferID,async()=>{saved.blocked=true;return invoke("finishUpload",{transferID:p.transferID,sha256:p.sha256},value=>{
          const v=T.status(value,p.transferID,saved.expected);check(["completed","failed","uncertain"].includes(v.state));if(v.sha256!==null)check(v.sha256===p.sha256);
          saved.state=v.state;return v;
        },opts);});
      },
      async beginDownload(params,opts){
        caller();const p=T.downloadIntent(params);check(transfers.size+transferHeads<40,"budgetExceeded");transferHeads++;
        try{return await invoke("beginDownload",p,value=>{
          const id=cursorToken(value.transferID),v=T.status(value,id,{direction:"download",...p});check(!transfers.has(id)&&v.state==="downloading"&&v.transferredBytes===0);
          transfers.set(id,{expected:{direction:"download",...p,totalBytes:v.totalBytes},state:"downloading",offset:0,last:null});return v;
        },opts);}finally{transferHeads--;}
      },
      async readDownloadChunk(params,opts){
        caller();const p=fields(params,["transferID","offset"],[],"invalidInput"),saved=ownedTransfer(p.transferID,"download");integer(p.offset,0,T.fileBytes,"invalidInput");
        const replay=saved.last&&p.offset===saved.last.offset;check(!saved.blocked&&(replay||saved.state==="downloading"&&p.offset===saved.offset),"denied");
        return transferCall(p.transferID,async()=>{
          try{return await invoke("readDownloadChunk",{transferID:p.transferID,offset:p.offset},value=>{
            const v=T.chunk(value,p.transferID,p.offset,saved.expected.totalBytes);if(replay)check(JSON.stringify(v)===JSON.stringify(saved.last));
            saved.last=v;saved.offset=v.nextOffset;if(v.eof)saved.state="completed";return v;
          },opts);}catch(error){saved.blocked=true;throw error;}
        });
      },
      async transferStatus(transferID,opts){
        caller();return transferCall(transferID,()=>invoke("transferStatus",{transferID},value=>T.status(value,transferID,transfers.get(transferID)?.expected),opts));
      },
      async cancelTransfer(transferID,opts){
        caller();O.id(transferID,"invalidInput");const saved=transfers.get(transferID);check(saved,"denied");
        return transferCall(transferID,()=>invoke("cancelTransfer",{transferID},value=>{
          const v=T.status(value,transferID,saved.expected);check(["cancelled","failed","completed","uncertain"].includes(v.state));saved.state=v.state;saved.blocked=true;return v;
        },opts));
      },
      discardTransfer(transferID){O.id(transferID,"invalidInput");check(!busyTransfers.has(transferID),"busy");return transfers.delete(transferID);},
      async previewFileCopy(params,opts){
        caller(true,true);const p=C.intent(params,true);check(copies.size+copyHeads<40,"budgetExceeded");copyHeads++;
        try{return await invoke("previewFileCopy",p,value=>{
          const v=C.preview(value,p);check(!copies.has(v.copyID));
          if(v.state==="ready")copies.set(v.copyID,{expected:{intent:p,totalBytes:v.totalBytes},state:"ready",offset:0,blocked:false,lastOffset:null,last:null});return v;
        },opts);}finally{copyHeads--;}
      },
      async beginFileCopy(copyID,opts){
        caller(true,true);const saved=ownedCopy(copyID);check(saved.state==="ready"&&!saved.blocked,"denied");
        return copyCall(copyID,()=>{saved.blocked=true;return invoke("beginFileCopy",{copyID,confirmed:true},value=>{
          const v=C.status(value,copyID,saved.expected);check(["copying","failed","cancelled"].includes(v.state)&&v.copiedBytes===0);saved.state=v.state;saved.blocked=false;return v;
        },opts);});
      },
      async copyFileChunk(params,opts){
        caller(true,true);const p=fields(params,["copyID","offset"],[],"invalidInput"),saved=ownedCopy(p.copyID);integer(p.offset,0,C.fileBytes,"invalidInput");
        const replay=saved.lastOffset===p.offset;check(!saved.blocked&&(replay||saved.state==="copying"&&p.offset===saved.offset),"denied");
        return copyCall(p.copyID,()=>{saved.blocked=true;return invoke("copyFileChunk",{copyID:p.copyID,offset:p.offset},value=>{
          const v=C.status(value,p.copyID,saved.expected);check(["copying","completed","cancelled","failed","uncertain"].includes(v.state));
          if(replay)check(v.copiedBytes===saved.offset&&(JSON.stringify(v)===JSON.stringify(saved.last)||saved.state==="copying"&&["failed","cancelled"].includes(v.state)));
          else if(["copying","completed"].includes(v.state))check(v.copiedBytes===Math.min(saved.expected.totalBytes,p.offset+C.chunkBytes));
          if(v.state==="copying")check(v.copiedBytes<saved.expected.totalBytes);
          saved.state=v.state;saved.offset=v.copiedBytes;saved.lastOffset=p.offset;saved.last=v;saved.blocked=false;return v;
        },opts);});
      },
      async fileCopyStatus(copyID,opts){
        caller();return copyCall(copyID,()=>invoke("fileCopyStatus",{copyID},value=>C.status(value,copyID,copies.get(copyID)?.expected),opts));
      },
      async cancelFileCopy(copyID,opts){
        caller();const saved=ownedCopy(copyID);return copyCall(copyID,()=>invoke("cancelFileCopy",{copyID},value=>{
          const v=C.status(value,copyID,saved.expected);check(["cancelled","failed","completed","uncertain"].includes(v.state));saved.state=v.state;saved.blocked=true;return v;
        },opts));
      },
      discardFileCopy(copyID){O.id(copyID,"invalidInput");check(!busyCopies.has(copyID),"busy");return copies.delete(copyID);},
      async previewFile(params,opts) {
        caller();const v=fields(params,["libraryID","relativePath"],["maximumBytes"],"invalidInput");
        const libraryID=text(v.libraryID,128,{code:"invalidInput"}),relativePath=path(v.relativePath,false,"invalidInput"),maximumBytes=integer(Object.hasOwn(v,"maximumBytes")?v.maximumBytes:65536,1,65536,"invalidInput");
        check(["txt","md","json","csv","log"].includes(relativePath.split(".").at(-1).toLowerCase()),"invalidInput");
        return invoke("previewFile",{libraryID,relativePath,maximumBytes},value=>{
          const p=fields(value,["libraryID","relativePath","text","utf8Bytes"]);
          check(p.libraryID===libraryID && p.relativePath===relativePath);text(p.text,maximumBytes,{empty:true,nul:true});
          integer(p.utf8Bytes,0,maximumBytes);check(encoder.encode(p.text).length===p.utf8Bytes);return value;
        },opts);
      }
    });
  }
  async function createRecycleObservationModel(client,params,rawOptions={}) {
    const p=fields(params,["operationID"],["entryID"],"invalidInput"),opts=fields(rawOptions,[],["onChange"],"invalidInput");
    cursorToken(p.operationID,"invalidInput");if(Object.hasOwn(p,"entryID"))cursorToken(p.entryID,"invalidInput");
    check(!Object.hasOwn(opts,"onChange")||typeof opts.onChange==="function","invalidInput");
    check(client?.source==="fixture-host-client"&&!client.closed&&typeof client.overview==="function"&&typeof client.observeRecycleOperation==="function","unavailable");
    const who=await client.overview();check(!client.closed,"unavailable");check([4,5,6].includes(who.databaseSchema),"unsupported");check(who.role==="administrator","denied");
    // Capture this borrowed client by value; disposal never closes or cancels its transport.
    return R.createReadOnlyModel({operationID:p.operationID,ownerUserID:who.userID,...(Object.hasOwn(p,"entryID")?{entryID:p.entryID}:{}),
      read:id=>client.observeRecycleOperation(id),...(Object.hasOwn(opts,"onChange")?{onChange:opts.onChange}:{})});
  }
  return {createDesktopClient,prepareLabelJob,createRecycleObservationModel};
});
