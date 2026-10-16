"use strict";
// The XCTest host alone approves a newly-created synthetic directory and its independent target copy grant.
const assert=require("node:assert/strict"),{createInterface}=require("node:readline"),{createHash}=require("node:crypto");
const M=require("../web/dist/model.js"),C=require("../web/dist/bridge-client.js"),Copies=require("../web/dist/file-copies.js");
const libraryID=process.argv[2],lines=createInterface({input:process.stdin,crlfDelay:Infinity});let waiting,mask=false;
const timer=setTimeout(()=>{process.stderr.write("file-copy-pipe: timed out\n");process.exit(1);},170000);
lines.on("line",line=>{const item=waiting;waiting=undefined;if(!item)throw Error("unexpected response");try{item.resolve(JSON.parse(line));}catch(error){item.reject(error);}});
const transport=async request=>{
  assert.ok(Buffer.byteLength(JSON.stringify(request))<=65536);
  const reply=await new Promise((resolve,reject)=>{assert.equal(waiting,undefined);waiting={resolve,reject};process.stdout.write(JSON.stringify(request)+"\n");});
  if(mask&&request.method==="copyFileChunk"){mask=false;assert.equal(reply.data.state,"completed");return{apiVersion:1,requestId:request.requestId,error:{code:"budgetExceeded"}};}return reply;
};
const client=C.createDesktopClient({transport,timeoutMs:60000}),raw=M.createBridgeAdapter(transport),code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const intent=(sourcePath,name)=>({sourceLibraryID:libraryID,sourcePath,targetLibraryID:libraryID,name});
(async()=>{
  await client.overview();
  const unknown="55555555-0000-0000-0000-000000000000";
  assert.equal((await client.fileCopyStatus(unknown)).state,"notVisible");await assert.rejects(client.beginFileCopy(unknown),code("denied"));
  const p=await client.previewFileCopy(intent("binary.bin","中日-copy.bin"));assert.equal(p.state,"ready");assert.equal(p.totalBytes,70001);
  assert.equal((await client.beginFileCopy(p.copyID)).state,"copying");
  let status;
  for(const offset of [0,32768,65536]){
    status=await client.copyFileChunk({copyID:p.copyID,offset});assert.equal(status.copiedBytes,Math.min(offset+32768,70001));
    assert.equal((await raw.request("copyFileChunk",{copyID:p.copyID,offset})).copiedBytes,status.copiedBytes);
  }
  assert.equal(status.state,"completed");assert.equal(status.sha256,createHash("sha256").update(Uint8Array.from({length:70001},(_,i)=>i%251)).digest("hex"));
  assert.equal((await raw.request("beginFileCopy",{copyID:p.copyID,confirmed:true})).state,"completed");
  const conflict=await client.previewFileCopy(intent("a.txt","中日-copy.bin"));assert.equal(conflict.state,"conflict");await assert.rejects(client.beginFileCopy(conflict.copyID),code("denied"));
  const same=await client.previewFileCopy(intent("a.txt","a.txt"));assert.equal(same.state,"unchanged");
  const copySource=await Copies.createClientSource(client),controller=Copies.createController(copySource);
  await controller.prepare(intent("empty.bin","empty-copy.bin"));const empty={copyID:controller.snapshot().copyID};await controller.confirm();
  assert.equal(controller.snapshot().phase,"completed");assert.equal(controller.snapshot().result.sha256,createHash("sha256").update(Buffer.alloc(0)).digest("hex"));
  controller.dispose();copySource.dispose();assert.equal(client.closed,false);
  const cancelled=await client.previewFileCopy(intent("binary.bin","cancelled.bin"));await client.beginFileCopy(cancelled.copyID);
  await client.copyFileChunk({copyID:cancelled.copyID,offset:0});assert.equal((await client.cancelFileCopy(cancelled.copyID)).state,"cancelled");
  const lost=await client.previewFileCopy(intent("a.txt","lost-copy.txt"));await client.beginFileCopy(lost.copyID);mask=true;
  await assert.rejects(client.copyFileChunk({copyID:lost.copyID,offset:0}),code("budgetExceeded"));
  await assert.rejects(client.copyFileChunk({copyID:lost.copyID,offset:0}),code("denied"));
  assert.equal((await client.fileCopyStatus(lost.copyID)).state,"completed");
  await assert.rejects(raw.request("previewFileCopy",{...intent("a.txt","bad"),root:"/tmp"}),code("invalidInput"));
  await assert.rejects(raw.request("previewFileCopy",intent("../outside","bad")),code("unsafePath"));
  await assert.rejects(raw.request("beginFileCopy",{copyID:lost.copyID,confirmed:1}),code("invalidInput"));
  const denied=await transport({apiVersion:1,requestId:"copy-grant-denied-1",method:"authorizeFixtureLibraryCopies",params:{libraryID}});assert.equal(denied.error.code,"unsupported");
  const rows=await raw.request("listFilesPage",{libraryID});
  assert.deepEqual(rows.items.map(x=>x.name),["a.txt","binary.bin","empty-copy.bin","empty.bin","lost-copy.txt","中日-copy.bin"]);
  for(const item of [p,empty,cancelled,lost])client.discardFileCopy(item.copyID);
  process.stderr.write("file-copy-pipe: PASS (70001 binary bytes, source retained, server-only chunks, empty file, no overwrite, cancel cleanup, masked publication receipt, no copy approval RPC)\n");
})().catch(error=>{process.stderr.write("file-copy-pipe: FAIL "+error.stack+"\n");process.exitCode=1;}).finally(()=>{client.close();clearTimeout(timer);lines.close();process.stdin.destroy();process.stdout.end();});
