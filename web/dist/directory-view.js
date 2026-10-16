(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./model.js"),require("./file-operations.js"),require("./file-transfers.js"),require("./file-copies.js"),require("./file-copy-fixture.js"));
  else root.MacNASDirectoryView = Object.freeze(factory(root.MacNASModel,root.MacNASFileOperations,root.MacNASFileTransfers,root.MacNASFileCopies,root.MacNASFileCopyFixture));
})(globalThis, function (M,O,T,C,F) {
  "use strict";
  const sources = new WeakSet(), encoder = new TextEncoder(), fixtureTreeBytes = 64 * 1024 * 1024;
  const errors = new Set(["invalidInput","invalidResponse","unsupported","denied","readOnly","unavailable","budgetExceeded","replay","collision","missingVolume","unsafePath","unsafeFile","integrity","database","busy","expired","staleState","interrupted","timedOut","cancelled","pluginFailed","invalidSchema"]);
  const volumeStates = ["missing","ambiguous","systemVolume","authorizationRequired","readOnly","needsBinding","identityChanged","readyReadOnly","readyReadWrite"];
  const check = (value, code = "invalidResponse") => { if (!value) throw new M.ServiceError(code); };
  const errorCode = error => error instanceof M.ServiceError && errors.has(error.code) ? error.code : "unavailable";
  const freeze = value => { if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); } return value; };
  function fields(value, required, optional = [], code = "invalidResponse") {
    check(value && Object.getPrototypeOf(value) === Object.prototype, code);
    const descriptors = Object.getOwnPropertyDescriptors(value), keys = Reflect.ownKeys(descriptors);
    check(keys.every(key => typeof key === "string" && [...required, ...optional].includes(key)), code);
    check(required.every(key => Object.hasOwn(descriptors, key)), code);
    const result = {};
    for (const key of keys) {
      const property = descriptors[key]; check(property.enumerable && Object.hasOwn(property, "value"), code);
      Object.defineProperty(result, key, { value: property.value, enumerable: true });
    }
    return result;
  }
  function text(value, bytes = 128, { empty = false, nul = false, code = "invalidResponse" } = {}) {
    check(typeof value === "string" && (empty || value.length > 0) && value.length <= bytes, code);
    for (let i = 0; i < value.length; i++) {
      const unit = value.charCodeAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) { const next = value.charCodeAt(++i); check(next >= 0xDC00 && next <= 0xDFFF, code); }
      else check(!(unit >= 0xDC00 && unit <= 0xDFFF), code);
    }
    check((nul || !value.includes("\0")) && encoder.encode(value).length <= bytes, code); return value;
  }
  function integer(value, min = 0, max = Number.MAX_SAFE_INTEGER, code = "invalidResponse") {
    check(Number.isSafeInteger(value) && value >= min && value <= max, code); return value;
  }
  function path(value, empty = true, code = "invalidResponse") {
    text(value, 4096, { empty, code }); if (empty && value === "") return value;
    const parts = value.split("/");
    check(parts.length <= 128 && !value.includes("\\") && parts.every(part => part && part !== "." && part !== ".." && !part.includes(":")), code); return value;
  }
  function token(value, code = "invalidResponse") {
    check(typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value), code); return value;
  }
  function location(value, optional = [], required = []) {
    const p = fields(value, ["libraryID", ...required], ["relativePath", ...optional], "invalidInput");
    text(p.libraryID, 128, { code: "invalidInput" });
    return { ...p, relativePath: path(Object.hasOwn(p, "relativePath") ? p.relativePath : "", true, "invalidInput") };
  }
  function byteOrder(a, b) {
    const x = encoder.encode(a), y = encoder.encode(b);
    for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] - y[i];
    return x.length - y.length;
  }
  function context(info, kind) {
    check(info && info.source === kind && info.apiVersion === 1 && (kind === "fixture" ? info.databaseSchema === 3 : [3,4,5,6].includes(info.databaseSchema)) && info.physicalPool === "unbound");
    text(info.userID); check(["administrator", "reader"].includes(info.role) && ["synthetic_development", "read_only_recovery", "rolled_back_recovery"].includes(info.mode));
    return freeze({ source: kind, userID: info.userID, role: info.role, mode: info.mode });
  }
  const sameLocation = (a, b) => a.libraryID === b.libraryID && a.relativePath === b.relativePath && a.pageSize === b.pageSize;
  const previewable = item => item.kind === "file" && ["txt", "md", "json", "csv", "log"].includes(item.name.split(".").at(-1).toLowerCase()) && item.bytes <= 65536;
  function entry(raw, parent, fixture) {
    const v = fields(raw, ["name", "relativePath", "kind", "modifiedAt"], ["bytes"]);
    text(v.name, 1024); path(v.relativePath, false);
    check(!v.name.includes("/") && v.relativePath === (parent ? parent + "/" : "") + v.name && ["file", "directory"].includes(v.kind));
    if (v.kind === "file") integer(v.bytes); else check(!Object.hasOwn(v, "bytes"));
    if (fixture) check(v.modifiedAt === null);
    else {
      text(v.modifiedAt, 20); check(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(v.modifiedAt));
      const date = new Date(v.modifiedAt); check(Number.isFinite(date.getTime()) && date.toISOString().slice(0, 19) + "Z" === v.modifiedAt);
    }
    return freeze({ name: v.name, relativePath: v.relativePath, kind: v.kind, bytes: v.bytes ?? null, modifiedAt: v.modifiedAt, canPreview: previewable(v) });
  }
  async function makeSource(kind, operations) {
    let closed = false, pendingHeads = 0;
    const cursors = new Map(), busy = new Set();
    function alive() { check(!closed && !operations.isClosed?.(), "unavailable"); }
    async function call(operation) { alive(); try { const result = await operation(); alive(); return result; } catch (error) { throw new M.ServiceError(errorCode(error)); } }
    // The desktop owns the provider. Disposing this source never closes its shared session/client.
    function discard(cursor) {
      if (!cursors.has(cursor) || busy.has(cursor)) return false;
      cursors.delete(cursor); try { return operations.discard(cursor); } catch { return false; }
    }
    function dispose() { if (closed) return; closed = true; for (const cursor of cursors.keys()) discard(cursor); fileOperations?.dispose();fileTransfers?.dispose();fileCopies?.dispose(); operations.dispose?.(); }
    const binding = context(await call(operations.overview), kind), fixture = kind === "fixture";
    const fileOperations=operations.previewOperation ? O.createSource(binding,{preview:operations.previewOperation,commit:operations.commitOperation,status:operations.operationStatus,discard:operations.discardOperation,isClosed:()=>closed||!!operations.isClosed?.()}) : null;
    const fileTransfers=operations.transferStore?T.createFixtureSource(binding,operations.transferStore,{monotonicNow:operations.transferClock}):operations.transferMethods?T.createSource(binding,operations.transferMethods):null;
    const fileCopies=operations.copyStore?F.createFixtureSource(binding,operations.copyStore,{monotonicNow:operations.transferClock}):operations.copyMethods?C.createSource(binding,operations.copyMethods):null;
    const source = Object.freeze({
      context: binding, fileOperations,fileTransfers,fileCopies, get closed() { return closed || !!operations.isClosed?.(); }, dispose, discardCursor: discard,
      async libraries() {
        const raw = await call(operations.libraries);
        try {
          check(Array.isArray(raw) && raw.length <= 1024);
          const items = raw.map(item => {
            const v = fields(item, ["libraryID", "state", "estimatedBytes"], fixture ? [] : ["volumeID"]);
            text(v.libraryID); check(fixture ? v.state === "synthetic" && v.estimatedBytes === null : volumeStates.includes(v.state));
            if (!fixture) { integer(v.estimatedBytes); token(v.volumeID.toLowerCase()); }
            return freeze({ libraryID: v.libraryID, state: v.state, estimatedBytes: v.estimatedBytes });
          });
          check(new Set(items.map(item => item.libraryID)).size === items.length); return freeze(items);
        } catch { dispose(); throw new M.ServiceError("invalidResponse"); }
      },
      async page(params) {
        alive(); const p = location(params, ["pageSize", "cursor"]);
        p.pageSize = integer(Object.hasOwn(p, "pageSize") ? p.pageSize : 50, 1, 100, "invalidInput");
        const previous = Object.hasOwn(p, "cursor") ? cursors.get(token(p.cursor, "invalidInput")) : null;
        if (Object.hasOwn(p, "cursor")) { check(previous && sameLocation(previous, p), "denied"); check(!busy.has(p.cursor), "busy"); busy.add(p.cursor); }
        else { check(cursors.size + pendingHeads < 64, "budgetExceeded"); pendingHeads++; }
        let received;
        try {
          const raw = await operations.page(p); received = raw?.nextCursor; alive();
          const v = fields(raw, ["pageVersion", "order", "consistency", "libraryID", "relativePath", "pageSize", "items", "nextCursor"]);
          check(v.pageVersion === 1 && v.order === "name-utf8" && v.consistency === (fixture ? "synthetic-fixed-directory" : "directory-stamped-live-metadata") && sameLocation(v, p));
          check(Array.isArray(v.items) && v.items.length <= p.pageSize);
          const items = v.items.map(item => entry(item, p.relativePath, fixture));
          check(new Set(items.map(item => item.name.normalize("NFC").toLowerCase())).size === items.length);
          let after = previous?.after;
          for (const item of items) { if (after !== undefined) check(byteOrder(after, item.name) < 0); after = item.name; }
          if (v.nextCursor !== null) { token(v.nextCursor); check(items.length === p.pageSize && v.nextCursor !== p.cursor && !cursors.has(v.nextCursor)); }
          if (p.cursor !== undefined) cursors.delete(p.cursor);
          if (v.nextCursor !== null) cursors.set(v.nextCursor, { ...p, after });
          return freeze({ viewVersion: 1, libraryID: p.libraryID, relativePath: p.relativePath, pageSize: p.pageSize, items, nextCursor: v.nextCursor });
        } catch (error) {
          // A successfully delivered page may already have consumed its old capability. Always reread explicitly.
          if (received) { try { operations.discard(received); } catch {} }
          if (p.cursor !== undefined) { busy.delete(p.cursor); discard(p.cursor); }
          const code = errorCode(error); if (code === "invalidResponse") dispose(); throw new M.ServiceError(code);
        } finally { busy.delete(p.cursor); if (p.cursor === undefined) pendingHeads--; if (closed) discard(p.cursor); }
      },
      async preview(params) {
        const p = location(params); path(p.relativePath, false, "invalidInput");
        check(["txt", "md", "json", "csv", "log"].includes(p.relativePath.split(".").at(-1).toLowerCase()), "invalidInput");
        const raw = await call(() => operations.preview({ ...p, maximumBytes: 65536 }));
        try {
          const v = fields(raw, ["libraryID", "relativePath", "text", "utf8Bytes"]);
          check(v.libraryID === p.libraryID && v.relativePath === p.relativePath); text(v.text, 65536, { empty: true, nul: true });
          integer(v.utf8Bytes, 0, 65536); check(encoder.encode(v.text).length === v.utf8Bytes);
          return freeze({ libraryID: v.libraryID, relativePath: v.relativePath, text: v.text, utf8Bytes: v.utf8Bytes });
        } catch { dispose(); throw new M.ServiceError("invalidResponse"); }
      }
    });
    sources.add(source); return source;
  }
  async function createClientDirectorySource(client) {
    check(client?.source === "fixture-host-client" && !client.closed && ["overview", "listLibraries", "listFilesPage", "previewFile", "discardFilePage"].every(key => typeof client[key] === "function"), "unavailable");
    const mutation= ["previewFileOperation","commitFileOperation","fileOperationStatus"].every(key=>typeof client[key]==="function") ? {
      previewOperation:p=>client.previewFileOperation(p),commitOperation:value=>client.commitFileOperation(value),operationStatus:value=>client.fileOperationStatus(value),discardOperation:value=>client.discardFileOperation?.(value)
    } : {};
    const transferMethods=["previewUpload","beginUpload","appendUpload","finishUpload","beginDownload","readDownloadChunk","transferStatus","cancelTransfer"].every(key=>typeof client[key]==="function")?{
      transferMethods:{previewUpload:p=>client.previewUpload(p),beginUpload:id=>client.beginUpload(id),appendUpload:(transferID,offset,parts)=>client.appendUpload({transferID,offset,parts}),finishUpload:(transferID,sha256)=>client.finishUpload({transferID,sha256}),
        beginDownload:p=>client.beginDownload(p),readDownloadChunk:(transferID,offset)=>client.readDownloadChunk({transferID,offset}),status:id=>client.transferStatus(id),cancel:id=>client.cancelTransfer(id),discard:id=>client.discardTransfer(id),isClosed:()=>client.closed}
    }:{};
    const copyMethods=["previewFileCopy","beginFileCopy","copyFileChunk","fileCopyStatus","cancelFileCopy"].every(key=>typeof client[key]==="function")?{
      copyMethods:{preview:p=>client.previewFileCopy(p),begin:id=>client.beginFileCopy(id),chunk:(id,offset)=>client.copyFileChunk({copyID:id,offset}),status:id=>client.fileCopyStatus(id),cancel:id=>client.cancelFileCopy(id),discard:id=>client.discardFileCopy?.(id),isClosed:()=>client.closed}
    }:{};
    return makeSource("fixture-host", { overview: () => client.overview(), libraries: () => client.listLibraries(), page: p => client.listFilesPage(p),
      preview: p => client.previewFile(p), discard: cursor => client.discardFilePage(cursor), isClosed: () => client.closed,...mutation,...transferMethods,...copyMethods });
  }
  async function createFixtureDirectorySource(api, session, options = {}) {
    check(api?.source === "fixture" && typeof api.overview === "function", "unavailable");
    const config = fields(options, [], ["monotonicNow", "maximumTreeBytes"], "invalidInput");
    const now = Object.hasOwn(config, "monotonicNow") ? config.monotonicNow : (() => performance.now()); check(typeof now === "function", "invalidInput");
    const maximumTreeBytes = Object.hasOwn(config, "maximumTreeBytes") ? integer(config.maximumTreeBytes, 1, fixtureTreeBytes, "invalidInput") : fixtureTreeBytes;
    let who, revoke = () => {}, unsubscribe = () => {};
    try { who = context(await api.overview(session), "fixture"); } catch (error) { throw new M.ServiceError(errorCode(error)); }
    async function authorized() {
      try {
        const info = await api.overview(session), current = context(info, "fixture");
        check(["userID", "role", "mode"].every(key => who[key] === current[key]), "denied"); return info;
      } catch (error) { revoke(); throw error; }
    }
    // Fixed synthetic tree, independent of the legacy translated fixture files. No disk approval, scan or timestamps.
    const data = new Map(), directories = new Set(["shared/", "shared/Notes", "shared/Empty", "personal/", "personal/Travel"]);
    for (const [id, value] of [
      ["shared/01-Welcome.txt", "MacNAS 合成文件 / サンプルファイル\n这里仅演示当前页浏览。NAS 未连接。\n"],
      ["shared/02-Guide.md", "# 当前页 / このページ\n搜索与类型过滤只检查当前页。翻页会替换显示的文件。\n"],
      ["shared/03-Data.json", "{\"source\":\"synthetic\",\"NAS\":\"unconnected\"}\n"],
      ["shared/04-Table.csv", "name,source\nMacNAS,synthetic\n"],
      ["shared/05-Event.log", "synthetic fixture; no real NAS events\n"],
      ["shared/jobHash.txt", "jobHash\n<script>只是文字 / テキストのみ</script>\n"],
      ["shared/Notes/Readme.txt", "嵌套目录合成样例 / 入れ子のサンプル\n"],
      ["personal/Private.txt", "仅所有者的合成文字 / オーナー用のサンプル\n"],
      ["personal/Travel/List.txt", "合成旅行清单 / 旅行リストのサンプル\n"]
    ]) data.set(id, encoder.encode(value));
    let publishedBytes = [...data.values()].reduce((sum, bytes) => sum + bytes.length, 0), reservedBytes = 0;
    const reservations = new Map();
    check(publishedBytes <= maximumTreeBytes, "budgetExceeded");
    function reserve(id, bytes) {
      integer(bytes, 0, T.fileBytes, "invalidInput");
      const previous = reservations.get(id);
      if (previous !== undefined) { check(previous === bytes, "collision"); return; }
      check(bytes <= maximumTreeBytes - publishedBytes - reservedBytes, "budgetExceeded");
      reservations.set(id, bytes); reservedBytes += bytes;
    }
    function release(id) { if (reservations.has(id)) { reservedBytes -= reservations.get(id); reservations.delete(id); } }
    const pending = new Map(), consumed = new Map(),revisions=new Map(),directoryIdentities=new Map([...directories].map(key=>[key,crypto.randomUUID()])),operationPreviews=new Map(),operationReceipts=new Map();
    const visible = libraryID => libraryID === "shared" || libraryID === "personal" && who.role === "administrator";
    function clock() { const time = now(); check(Number.isFinite(time) && time >= 0, "unavailable"); return time; }
    function reclaim(time) { for (const [id, item] of pending) if (time >= item.expires) { pending.delete(id); consumed.set(id, "expired"); } while (consumed.size > 64) consumed.delete(consumed.keys().next().value); }
    async function mutationAuthorized(p) {await authorized();check(who.mode==="synthetic_development","readOnly");check(who.role==="administrator"&&visible(p.libraryID),"denied");}
    const directoryKey=p=>p.libraryID+"/"+p.parentPath;
    const directoryVersion = key => directoryIdentities.get(key) + ":" + (revisions.get(key) || 0);
    function saveOperation(value){if(operationReceipts.size>=32)operationReceipts.delete(operationReceipts.keys().next().value);operationReceipts.set(value.operationID,{value,expires:clock()+300000});return value;}
    function reclaimOperations(){const time=clock();for(const [id,item]of operationReceipts)if(time>=item.expires)operationReceipts.delete(id);for(const [id,item]of operationPreviews)if(time>=item.expires){operationPreviews.delete(id);saveOperation({resultVersion:1,operationID:id,state:"failed",intent:item.intent,error:"expired"});}}
    function operationResult(id,p,state,error=null){return {resultVersion:1,operationID:id,state,intent:p,error};}
    function collision(p){const key=directoryKey(p)+(p.parentPath?"/":""),wanted=p.name.normalize("NFC").toLowerCase();return [...directories,...data.keys()].some(value=>{if(!value.startsWith(key))return false;const name=value.slice(key.length);return name&&!name.includes("/")&&name.normalize("NFC").toLowerCase()===wanted;});}
    function publish(p, bytes, reservationID) {
      check(bytes instanceof Uint8Array && reservations.has(reservationID) && reservations.get(reservationID) === bytes.length, "integrity");
      check(directories.has(directoryKey(p)), "staleState"); check(!collision(p), "collision");
      check(directories.size + data.size < 4096, "budgetExceeded");
      const key = directoryKey(p), revision = (revisions.get(key) || 0) + 1;
      check(Number.isSafeInteger(revision) && publishedBytes + reservedBytes <= maximumTreeBytes, "budgetExceeded");
      data.set(p.libraryID + "/" + T.target(p), bytes); release(reservationID); publishedBytes += bytes.length; revisions.set(key, revision);
    }
    const targetIntent = p => ({ libraryID: p.targetLibraryID, parentPath: p.parentPath, name: p.name });
    const sourceParent = p => p.sourceLibraryID + "/" + p.sourcePath.split("/").slice(0,-1).join("/");
    const source = await makeSource("fixture", {
      overview: authorized,
      transferClock:now,
      transferStore:{authorizeSession:authorized,authorizeUpload:mutationAuthorized,async authorizeRead(p){await authorized();check(visible(p.libraryID),"denied");},
        parentExists:p=>directories.has(directoryKey(p)),version:p=>directoryVersion(directoryKey(p)),exists:collision,
        read:p=>data.get(p.libraryID+"/"+p.relativePath), reserve, release, publish},
      copyStore:{authorizeSession:authorized, async authorizeCopy(p){await mutationAuthorized({libraryID:p.targetLibraryID});check(visible(p.sourceLibraryID),"denied");},
        readSource:p=>data.get(p.sourceLibraryID+"/"+p.sourcePath), sourceVersion:p=>directoryVersion(sourceParent(p)),
        parentExists:p=>directories.has(directoryKey(targetIntent(p))), targetVersion:p=>directoryVersion(directoryKey(targetIntent(p))),
        exists:p=>collision(targetIntent(p)),readTarget:p=>data.get(p.targetLibraryID+"/"+T.target(p)), reserve, release, publish:(p,bytes,id)=>publish(targetIntent(p),bytes,id)},
      async libraries() { await authorized(); return ["shared", "personal"].filter(visible).map(libraryID => ({ libraryID, state: "synthetic", estimatedBytes: null })); },
      async page(p) {
        await authorized(); check(visible(p.libraryID), "denied");
        const directory = p.libraryID + "/" + p.relativePath; check(directories.has(directory), "denied");const version=directoryVersion(directory);
        const time = clock(); reclaim(time); let after, expires = time + 60000;
        if (p.cursor !== undefined) { const saved = pending.get(p.cursor); check(saved, consumed.get(p.cursor) || "denied"); check(sameLocation(saved, p), "denied");check(saved.revision===directoryVersion(directory),"staleState"); after = saved.after; expires = saved.expires; }
        const prefix = directory + (p.relativePath ? "/" : ""), items = [];
        for (const id of [...directories, ...data.keys()]) {
          if (!id.startsWith(prefix)) continue;
          const name = id.slice(prefix.length); if (!name || name.includes("/")) continue;
          const kind = directories.has(id) ? "directory" : "file";
          items.push({ name, relativePath: (p.relativePath ? p.relativePath + "/" : "") + name, kind, modifiedAt: null, ...(kind === "file" ? { bytes: data.get(id).length } : {}) });
        }
        items.sort((a, b) => byteOrder(a.name, b.name));
        const remaining = items.filter(item => after === undefined || byteOrder(item.name, after) > 0), page = remaining.slice(0, p.pageSize);
        let nextCursor = null;
        if (remaining.length > p.pageSize) { check(pending.size - (p.cursor ? 1 : 0) < 64, "budgetExceeded"); nextCursor = crypto.randomUUID(); }
        await authorized(); check(clock() < expires, "expired");check(directories.has(directory)&&directoryVersion(directory)===version,"staleState");
        if (p.cursor !== undefined) { pending.delete(p.cursor); consumed.set(p.cursor, "replay"); }
        if (nextCursor) pending.set(nextCursor, { ...p, after: page.at(-1).name, expires,revision:version });
        reclaim(clock());
        return { pageVersion: 1, order: "name-utf8", consistency: "synthetic-fixed-directory", libraryID: p.libraryID, relativePath: p.relativePath, pageSize: p.pageSize, items: page, nextCursor };
      },
      async preview(p) {
        await authorized(); check(visible(p.libraryID), "denied");
        const value = data.get(p.libraryID + "/" + p.relativePath); check(value !== undefined, "denied");
        check(value.length <= p.maximumBytes, "budgetExceeded"); await authorized();check(data.get(p.libraryID + "/" + p.relativePath)===value,"staleState");let decoded;
        try{decoded=new TextDecoder("utf-8",{fatal:true}).decode(value);}catch{throw new M.ServiceError("unsupported");}
        return { libraryID: p.libraryID, relativePath: p.relativePath, text: decoded, utf8Bytes: value.length };
      },
      async previewOperation(p){
        await mutationAuthorized(p);reclaimOperations();check(directories.has(directoryKey(p)),"staleState");
        const prefix=directoryKey(p)+(p.parentPath?"/":""),old=p.sourceName===null?null:prefix+p.sourceName;
        if(old!==null)check(directories.has(old)||data.has(old),"staleState");
        const state=p.sourceName===p.name?"unchanged":collision(p)?"conflict":"ready",operationID=crypto.randomUUID();
        if(state==="ready"){check(operationPreviews.size<32,"budgetExceeded");operationPreviews.set(operationID,{intent:p,revision:directoryVersion(directoryKey(p)),expires:clock()+30000});}
        return {previewVersion:1,operationID,intent:p,state,expiresInSeconds:state==="ready"?30:0};
      },
      async commitOperation(id){
        await authorized();reclaimOperations();const cached=operationReceipts.get(id);if(cached){await mutationAuthorized(cached.value.intent);return cached.value;}
        const saved=operationPreviews.get(id);check(saved,"replay");await mutationAuthorized(saved.intent);
        // Authorization yields. Another submission may have completed this exact operation meanwhile.
        const completed=operationReceipts.get(id);if(completed)return completed.value;
        check(operationPreviews.get(id)===saved,"replay");operationPreviews.delete(id);const p=saved.intent;
        try{
          check(clock()<saved.expires,"expired");const parent=directoryKey(p),prefix=parent+(p.parentPath?"/":""),target=prefix+p.name;
          check(directories.has(parent)&&directoryVersion(parent)===saved.revision,"staleState");check(!collision(p),"collision");
          check(directories.size+data.size<4096,"budgetExceeded");const revision=(revisions.get(parent)||0)+1;check(Number.isSafeInteger(revision),"budgetExceeded");
          if(p.kind==="createDirectory"){const identity=crypto.randomUUID();directories.add(target);directoryIdentities.set(target,identity);}
          else{
            const old=prefix+p.sourceName;check(directories.has(old)||data.has(old),"staleState");
            const affected=[...directories,...data.keys()].filter(value=>value===old||value.startsWith(old+"/"));
            for(const value of affected){const next=target+value.slice(old.length);if(directories.delete(value)){directories.add(next);directoryIdentities.set(next,directoryIdentities.get(value));directoryIdentities.delete(value);if(revisions.has(value)){revisions.set(next,revisions.get(value));revisions.delete(value);}}else{const text=data.get(value);data.delete(value);data.set(next,text);}}
          }
          revisions.set(parent,revision);return saveOperation(operationResult(id,p,"completed"));
        }catch(error){return saveOperation(operationResult(id,p,"failed",errorCode(error)));}
      },
      async operationStatus(id){await authorized();reclaimOperations();const record=operationReceipts.get(id);if(record){check(visible(record.value.intent.libraryID),"denied");return record.value;}const saved=operationPreviews.get(id);return saved?operationResult(id,saved.intent,"ready"):operationResult(id,null,"notVisible");},
      discard: cursor => pending.delete(cursor),dispose:()=>{unsubscribe();pending.clear();consumed.clear();operationPreviews.clear();operationReceipts.clear();data.clear();directories.clear();reservations.clear();revisions.clear();directoryIdentities.clear();publishedBytes=0;reservedBytes=0;}
    });
    revoke = () => source.dispose();
    if (typeof api.observeFixtureSessionEnd === "function") {
      try { unsubscribe = api.observeFixtureSessionEnd(session, revoke); } catch (error) { source.dispose(); throw error; }
    }
    return source;
  }
  function createDirectoryPager({ source, pageSize = 50 } = {}) {
    check(sources.has(source), "invalidInput"); integer(pageSize, 1, 100, "invalidInput");
    let cursor = null, generation = 0;
    let view = freeze({ phase: "idle", libraryID: null, relativePath: "", items: [], pageNumber: 0, hasNext: false, error: null, requiresReload: false });
    const update = values => { view = freeze({ ...view, ...values }); return view; };
    const alive = () => check(view.phase !== "closed", "unavailable");
    const ready = () => { alive(); check(!["loading", "previewing"].includes(view.phase), "busy"); };
    function fail(error) { source.discardCursor(cursor); cursor = null; update({ phase: "error", hasNext: false, requiresReload: true, error: errorCode(error) }); }
    async function load(reset) {
      const epoch = ++generation, previous = cursor, target = { libraryID: view.libraryID, relativePath: view.relativePath, pageSize };
      if (reset) { source.discardCursor(previous); cursor = null; }
      update({ phase: "loading", error: null, requiresReload: true });
      try {
        const page = await source.page(reset ? target : { ...target, cursor: previous });
        if (epoch !== generation) { source.discardCursor(page.nextCursor); source.discardCursor(previous); return view; }
        cursor = page.nextCursor;
        return update({ phase: "ready", items: page.items, pageNumber: reset ? 1 : view.pageNumber + 1, hasNext: cursor !== null, error: null, requiresReload: false });
      } catch (error) {
        source.discardCursor(previous); if (epoch !== generation) return view;
        fail(error); throw new M.ServiceError(view.error);
      }
    }
    return Object.freeze({
      snapshot: () => view,
      open(params) {
        alive(); const p = location(params); generation++; source.discardCursor(cursor); cursor = null;
        update({ ...p, items: [], pageNumber: 0, hasNext: false }); return load(true);
      },
      reload() { ready(); check(view.libraryID !== null, "denied"); return load(true); },
      next() { ready(); check(view.phase === "ready" && cursor !== null && !view.requiresReload && view.pageNumber < 4096, "denied"); return load(false); },
      async preview(relativePath) {
        ready(); path(relativePath, false, "invalidInput");
        check(view.phase === "ready" && !view.requiresReload && view.items.some(item => item.relativePath === relativePath && item.canPreview), "denied");
        const epoch = generation, target = { libraryID: view.libraryID, relativePath }; update({ phase: "previewing", error: null });
        try { const result = await source.preview(target); if (epoch !== generation) return null; update({ phase: "ready" }); return result; }
        catch (error) { if (epoch !== generation) return null; fail(error); throw new M.ServiceError(view.error); }
      },
      dispose() { if (view.phase === "closed") return; generation++; source.discardCursor(cursor); cursor = null; update({ phase: "closed", items: [], pageNumber: 0, hasNext: false, error: null, requiresReload: false }); }
    });
  }
  function filterFiles(items, { filter = "all", search = "" } = {}) {
    check(Array.isArray(items) && items.length <= 100 && ["all", "directory", "file"].includes(filter) && typeof search === "string" && search.length <= 256, "invalidInput");
    const query = search.trim().toLocaleLowerCase();
    return items.filter(item => (filter === "all" || item.kind === filter) && item.name.toLocaleLowerCase().includes(query));
  }
  return { createFixtureDirectorySource, createClientDirectorySource, createDirectoryPager, filterFiles, fixtureTreeBytes };
});
