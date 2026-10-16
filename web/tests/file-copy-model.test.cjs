"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),crypto=require("node:crypto");
const M=require("../dist/model.js"),D=require("../dist/directory-view.js"),C=require("../dist/file-copies.js"),F=require("../dist/file-copy-fixture.js"),T=require("../dist/file-transfers.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const bytes=n=>Uint8Array.from({length:n},(_,i)=>i%251),digest=value=>crypto.createHash("sha256").update(value).digest("hex");
const intent=(patch={})=>({sourceLibraryID:"shared",sourcePath:"01-Welcome.txt",targetLibraryID:"personal",parentPath:"",name:"copy.txt",...patch});
async function fixture(options={},scenario="owner"){
 const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(scenario),directory=await D.createFixtureDirectorySource(api,session,options);
 return{api,session,directory,copy:directory.fileCopies,transfer:directory.fileTransfers};
}
async function initialBytes(){
 const f=await fixture();let total=0;
 for(const [libraryID,relativePath]of [["shared",""],["shared","Notes"],["personal",""],["personal","Travel"]])for(const item of (await f.directory.page({libraryID,relativePath})).items)if(item.kind==="file")total+=item.bytes;
 f.directory.dispose();return total;
}
async function upload(f,name,data,libraryID="shared",parentPath=""){
 const p=await f.transfer.previewUpload({libraryID,parentPath,name,totalBytes:data.length});assert.equal(p.state,"ready");const begun=await f.transfer.beginUpload(p.transferID);if(begun.state!=="uploading")return begun;
 for(let offset=0;offset<data.length;offset+=32768)await f.transfer.appendUpload(p.transferID,offset,T.parts(data.subarray(offset,offset+32768)));
 return f.transfer.finishUpload(p.transferID,digest(data));
}
async function complete(copy,p){
 const preview=C.preview(await copy.preview(p),C.intent(p,true));assert.equal(preview.state,"ready");let result=C.status(await copy.begin(preview.copyID),preview.copyID,{intent:preview.intent,totalBytes:preview.totalBytes});
 while(result.state==="copying")result=C.status(await copy.chunk(preview.copyID,result.copiedBytes),preview.copyID,{intent:preview.intent,totalBytes:preview.totalBytes});
 return result;
}
async function download(transfer,libraryID,relativePath){
 const head=await transfer.beginDownload({libraryID,relativePath}),blocks=[];let offset=0;
 while(true){const part=await transfer.readDownloadChunk(head.transferID,offset);blocks.push(T.decodeParts(part.parts,true));offset=part.nextOffset;if(part.eof)return Buffer.concat(blocks);}
}
test("fixture copy fixes both ends, publishes verified bytes, preserves source, and invalidates old target pages",async()=>{
 const f=await fixture(),source=await f.directory.preview({libraryID:"shared",relativePath:"01-Welcome.txt"}),old=await f.directory.page({libraryID:"personal",pageSize:1});
 const result=await complete(f.copy,intent());assert.equal(result.state,"completed");assert.equal(result.sha256,digest(Buffer.from(source.text)));assert.equal(result.copiedBytes,source.utf8Bytes);
 assert.equal((await f.directory.preview({libraryID:"personal",relativePath:"copy.txt"})).text,source.text);
 assert.equal((await f.directory.preview({libraryID:"shared",relativePath:"01-Welcome.txt"})).text,source.text);
 await assert.rejects(f.directory.page({libraryID:"personal",pageSize:1,cursor:old.nextCursor}),code("staleState"));
 assert.ok((await f.directory.page({libraryID:"personal"})).items.some(x=>x.name==="copy.txt"));f.directory.dispose();
});
test("binary copy advances only confirmed 32 KiB blocks and explicit last-block replay never republishes",async()=>{
 const f=await fixture(),data=bytes(70001);assert.equal((await upload(f,"source.bin",data)).state,"completed");
 const p=C.preview(await f.copy.preview(intent({sourcePath:"source.bin",name:"target.bin"})));assert.equal((await f.copy.begin(p.copyID)).copiedBytes,0);
 await assert.rejects(f.copy.chunk(p.copyID,1),code("replay"));const first=await f.copy.chunk(p.copyID,0);assert.equal(first.state,"copying");assert.equal(first.copiedBytes,32768);
 assert.deepEqual(await f.copy.chunk(p.copyID,0),first);assert.equal((await f.directory.page({libraryID:"personal"})).items.some(x=>x.name==="target.bin"),false);
 const second=await f.copy.chunk(p.copyID,32768);assert.equal(second.copiedBytes,65536);const last=await f.copy.chunk(p.copyID,65536);assert.equal(last.state,"completed");assert.equal(last.sha256,digest(data));
 assert.deepEqual(await f.copy.chunk(p.copyID,65536),last);await assert.rejects(f.copy.chunk(p.copyID,0),code("replay"));
 assert.deepEqual(await download(f.transfer,"personal","target.bin"),Buffer.from(data));assert.deepEqual(await download(f.transfer,"shared","source.bin"),Buffer.from(data));f.directory.dispose();
});
test("zero-byte copies publish only after begin and an explicit offset-zero chunk",async()=>{
 const f=await fixture();await upload(f,"empty.bin",new Uint8Array());const p=await f.copy.preview(intent({sourcePath:"empty.bin",name:"empty-copy.bin"}));
 assert.equal(p.totalBytes,0);assert.equal((await f.copy.begin(p.copyID)).state,"copying");assert.equal((await f.directory.page({libraryID:"personal"})).items.some(x=>x.name==="empty-copy.bin"),false);
 const r=C.status(await f.copy.chunk(p.copyID,0),p.copyID);assert.equal(r.state,"completed");assert.equal(r.sha256,digest(Buffer.alloc(0)));f.directory.dispose();
});
test("same source-target is unchanged and normalized conflicts grant no copying capability",async()=>{
 const f=await fixture(),same=await f.copy.preview(intent({targetLibraryID:"shared",name:"01-Welcome.txt"}));assert.equal(C.preview(same).state,"unchanged");await assert.rejects(f.copy.begin(same.copyID),code("replay"));
 const conflict=await f.copy.preview(intent({targetLibraryID:"shared",name:"01-welcome.TXT"}));assert.equal(C.preview(conflict).state,"conflict");await assert.rejects(f.copy.begin(conflict.copyID),code("replay"));
 assert.equal((await f.directory.page({libraryID:"shared"})).items.length,8);f.directory.dispose();
});
test("source rename and replacement target directory invalidate pinned copies without creating targets",async()=>{
 for(const side of ["source","target"]){
  const f=await fixture(),p=await f.copy.preview(intent({targetLibraryID:"shared",parentPath:"Empty"}));
  const rename=await f.directory.fileOperations.preview({libraryID:"shared",kind:"rename",sourceName:side==="source"?"01-Welcome.txt":"Empty",name:"renamed"});await f.directory.fileOperations.commit(rename.operationID);
  if(side==="target"){const replace=await f.directory.fileOperations.preview({libraryID:"shared",kind:"createDirectory",name:"Empty"});await f.directory.fileOperations.commit(replace.operationID);}
  const r=await f.copy.begin(p.copyID);assert.equal(r.state,"failed");assert.equal(r.error,"staleState");assert.equal((await f.directory.page({libraryID:"shared",relativePath:"Empty"})).items.length,0);f.directory.dispose();
 }
});
test("cancelled copies preserve all source bytes and cancel-after-publication preserves the result",async()=>{
 const f=await fixture(),data=bytes(70001);await upload(f,"source.bin",data);const p=await f.copy.preview(intent({sourcePath:"source.bin",name:"cancel.bin"}));await f.copy.begin(p.copyID);await f.copy.chunk(p.copyID,0);
 assert.equal((await f.copy.cancel(p.copyID)).state,"cancelled");assert.equal((await f.directory.page({libraryID:"personal"})).items.some(x=>x.name==="cancel.bin"),false);assert.deepEqual(await download(f.transfer,"shared","source.bin"),Buffer.from(data));
 const finished=await complete(f.copy,intent({sourcePath:"source.bin",name:"kept.bin"}));assert.equal((await f.copy.cancel(finished.copyID)).state,"completed");assert.deepEqual(await download(f.transfer,"personal","kept.bin"),Buffer.from(data));f.directory.dispose();
});
test("reader/recovery fixtures never gain independent copy permission and invalid inputs never touch the provider",async()=>{
 for(const [scenario,error]of [["reader","denied"],["recovery","readOnly"]]){const f=await fixture({},scenario);assert.equal(f.copy.canCopy,false);await assert.rejects(async()=>f.copy.preview(intent()),code(error));f.directory.dispose();}
 const f=await fixture();let accessed=0;
 for(const value of [{...intent(),parentPath:null},{...intent(),name:"../escape"},{...intent(),sourcePath:"/etc/passwd"},{...intent(),root:"/"},{...intent(),get sourcePath(){accessed++;return"01-Welcome.txt";}}])await assert.rejects(async()=>f.copy.preview(value),code("invalidInput"));
 assert.equal(accessed,0);f.directory.dispose();
});
test("copy previews, buffers, and bounded receipts expire without retaining tree reservations",async()=>{
 const initial=await initialBytes();let time=0;const f=await fixture({monotonicNow:()=>time,maximumTreeBytes:initial+100});const p=await f.copy.preview(intent());assert.equal((await f.copy.begin(p.copyID)).state,"copying");time=60000;
 assert.equal((await f.copy.status(p.copyID)).error,"expired");assert.equal((await upload(f,"available.bin",bytes(100),"personal")).state,"completed");time=360001;assert.equal((await f.copy.status(p.copyID)).state,"notVisible");f.directory.dispose();
});
test("tree quota includes exact initial UTF-8 bytes in every library and can only be tightened",async()=>{
 const initial=await initialBytes();assert.equal(D.fixtureTreeBytes,64*1024*1024);const api=M.createFixtureAdapter(),session=await api.beginFixtureSession("owner");
 await assert.rejects(D.createFixtureDirectorySource(api,session,{maximumTreeBytes:initial-1}),code("budgetExceeded"));
 for(const value of [0,1.1,null,D.fixtureTreeBytes+1])await assert.rejects(D.createFixtureDirectorySource(api,session,{maximumTreeBytes:value}),code("invalidInput"));
 let access=0;await assert.rejects(D.createFixtureDirectorySource(api,session,{get maximumTreeBytes(){access++;return initial;}}),code("invalidInput"));assert.equal(access,0);
 await assert.rejects(D.createFixtureDirectorySource(api,session,{maximumTreeBytes:initial,extra:true}),code("invalidInput"));
 const f=await fixture({maximumTreeBytes:initial}),p=await f.transfer.previewUpload({libraryID:"personal",name:"one.bin",totalBytes:1});assert.equal((await f.transfer.beginUpload(p.transferID)).error,"budgetExceeded");
 assert.equal((await f.directory.page({libraryID:"personal"})).items.length,2);assert.equal((await upload(f,"zero.bin",new Uint8Array())).state,"completed");f.directory.dispose();await api.endSession(session);
});
test("upload and copy compete atomically for one tree quota, including both libraries and all reservations",async()=>{
 const initial=await initialBytes(),f=await fixture({maximumTreeBytes:initial+120});const copy=await f.copy.preview(intent());
 const up=await f.transfer.previewUpload({libraryID:"shared",name:"reserved.bin",totalBytes:60});const results=await Promise.all([f.transfer.beginUpload(up.transferID),f.copy.begin(copy.copyID)]);
 assert.equal(results.filter(r=>["uploading","copying"].includes(r.state)).length,1);assert.equal(results.filter(r=>r.error==="budgetExceeded").length,1);
 if(results[0].state==="uploading")await f.transfer.cancel(up.transferID);else await f.copy.cancel(copy.copyID);
 const next=await upload(f,"all-remaining.bin",bytes(120),"personal");assert.equal(next.state,"completed");const denied=await f.transfer.previewUpload({libraryID:"shared",name:"overflow.bin",totalBytes:1});assert.equal((await f.transfer.beginUpload(denied.transferID)).error,"budgetExceeded");f.directory.dispose();
});
test("publication converts its existing reservation without double counting, and failed uploads release it",async()=>{
 const initial=await initialBytes(),f=await fixture({maximumTreeBytes:initial+100});const p=await f.transfer.previewUpload({libraryID:"shared",name:"bad.bin",totalBytes:100});await f.transfer.beginUpload(p.transferID);await f.transfer.appendUpload(p.transferID,0,T.parts(bytes(100)));
 assert.equal((await f.transfer.finishUpload(p.transferID,"0".repeat(64))).error,"integrity");assert.equal((await upload(f,"full.bin",bytes(100),"personal")).state,"completed");
 const other=await f.transfer.previewUpload({libraryID:"shared",name:"other.bin",totalBytes:1});assert.equal((await f.transfer.beginUpload(other.transferID)).error,"budgetExceeded");assert.equal((await f.directory.page({libraryID:"shared"})).items.some(x=>x.name==="bad.bin"),false);f.directory.dispose();
});
test("copy publication charges its bytes once and cannot reuse the released reservation as free capacity",async()=>{
 const initial=await initialBytes(),probe=await fixture(),size=(await probe.directory.preview({libraryID:"shared",relativePath:"01-Welcome.txt"})).utf8Bytes;probe.directory.dispose();
 const f=await fixture({maximumTreeBytes:initial+size});assert.equal((await complete(f.copy,intent())).state,"completed");
 const next=await f.transfer.previewUpload({libraryID:"shared",name:"overflow.bin",totalBytes:1});assert.equal((await f.transfer.beginUpload(next.transferID)).error,"budgetExceeded");
 assert.equal((await f.directory.preview({libraryID:"personal",relativePath:"copy.txt"})).utf8Bytes,size);f.directory.dispose();
});
test("copy cancellation and failed source checks release their entire shared tree reservation",async()=>{
 const initial=await initialBytes(),probe=await fixture(),size=(await probe.directory.preview({libraryID:"shared",relativePath:"01-Welcome.txt"})).utf8Bytes;probe.directory.dispose();
 for(const reason of ["cancel","changed"]){
  const f=await fixture({maximumTreeBytes:initial+size}),p=await f.copy.preview(intent());assert.equal((await f.copy.begin(p.copyID)).state,"copying");
  if(reason==="cancel")assert.equal((await f.copy.cancel(p.copyID)).state,"cancelled");
  else{const rename=await f.directory.fileOperations.preview({libraryID:"shared",kind:"rename",sourceName:"01-Welcome.txt",name:"renamed.txt"});await f.directory.fileOperations.commit(rename.operationID);assert.equal((await f.copy.chunk(p.copyID,0)).error,"staleState");}
  assert.equal((await upload(f,"reused.bin",bytes(size),"personal")).state,"completed");f.directory.dispose();
 }
});
test("an expired upload frees shared tree capacity for a later copy",async()=>{
 const initial=await initialBytes();let time=0;const f=await fixture({maximumTreeBytes:initial+100,monotonicNow:()=>time});
 const up=await f.transfer.previewUpload({libraryID:"shared",name:"expired.bin",totalBytes:100});await f.transfer.beginUpload(up.transferID);time=60000;assert.equal((await f.transfer.status(up.transferID)).error,"expired");
 assert.equal((await complete(f.copy,intent())).state,"completed");f.directory.dispose();
});
test("copy active capabilities and short-lived results stay bounded without automatic takeover",async()=>{
 const f=await fixture(),ids=[];for(let n=0;n<8;n++)ids.push((await f.copy.preview(intent({name:"copy-"+n}))).copyID);
 await assert.rejects(f.copy.preview(intent({name:"ninth"})),code("budgetExceeded"));for(const id of ids)await f.copy.cancel(id);
 for(let n=0;n<40;n++){const p=await f.copy.preview(intent({name:"cancel-"+n}));await f.copy.cancel(p.copyID);}
 assert.equal((await f.copy.status(ids[0])).state,"notVisible");assert.equal((await f.directory.page({libraryID:"personal"})).items.length,2);f.directory.dispose();
});
test("copy fixture enforces the 16 MiB single-file limit before retaining a source capability",async()=>{
 const store={async authorizeCopy(){},readSource:()=>new Uint8Array(C.fileBytes+1),parentExists:()=>true};
 const source=F.createFixtureSource({source:"fixture",userID:"fixture-owner",role:"administrator",mode:"synthetic_development"},store);
 await assert.rejects(source.preview(intent()),code("budgetExceeded"));source.dispose();
});
test("ended fixture sessions immediately dispose directory, copy, and transfer resources",async()=>{
 const f=await fixture();const cp=await f.copy.preview(intent());await f.copy.begin(cp.copyID);const up=await f.transfer.previewUpload({libraryID:"shared",name:"held.bin",totalBytes:32768});await f.transfer.beginUpload(up.transferID);
 await f.api.endSession(f.session);assert.equal(f.directory.closed,true);assert.equal(f.copy.closed,true);assert.equal(f.transfer.closed,true);await assert.rejects(async()=>f.copy.status(cp.copyID),code("unavailable"));
 assert.throws(()=>f.api.observeFixtureSessionEnd(f.session,()=>{}),code("denied"));
});
test("copy provider rejects changing content and records post-publication failure as uncertain",async()=>{
 for(const afterPublication of [false,true]){
  const data=bytes(4),reservations=new Map();let target=null,releaseCount=0;
  const store={async authorizeSession(){},async authorizeCopy(){},readSource:()=>data,sourceVersion:()=>0,parentExists:()=>true,targetVersion:()=>0,exists:()=>false,
   reserve:(id,n)=>reservations.set(id,n),release:id=>{if(reservations.delete(id))releaseCount++;},publish:(p,value)=>{target=value;if(afterPublication)data[0]^=1;},readTarget:()=>target};
  const source=F.createFixtureSource({source:"fixture",userID:"fixture-owner",role:"administrator",mode:"synthetic_development"},store),p=await source.preview(intent());await source.begin(p.copyID);if(!afterPublication)data[0]^=1;
  const result=C.status(await source.chunk(p.copyID,0),p.copyID);assert.equal(result.state,afterPublication?"uncertain":"failed");assert.equal(result.error,afterPublication?"staleState":"integrity");assert.equal(releaseCount,1);assert.equal(reservations.size,0);assert.equal(target!==null,afterPublication);
  if(afterPublication)assert.equal((await source.cancel(p.copyID)).state,"uncertain");source.dispose();
 }
});
test("fixture session-end observers are isolated, removable and cannot cross sessions",async()=>{
 const api=M.createFixtureAdapter(),a=await api.beginFixtureSession("owner"),b=await api.beginFixtureSession("owner");let calls=0;
 const remove=api.observeFixtureSessionEnd(a,()=>{calls++;});remove();api.observeFixtureSessionEnd(a,()=>{throw Error("observer");});api.observeFixtureSessionEnd(a,()=>{calls++;});api.observeFixtureSessionEnd(b,()=>{calls+=10;});
 assert.throws(()=>api.observeFixtureSessionEnd({...a},()=>{}),code("denied"));await api.endSession(a);assert.equal(calls,1);await api.endSession(a);assert.equal(calls,1);await api.endSession(b);assert.equal(calls,11);
});
