"use strict";
// The XCTest host alone approves a synthetic library and its independent upload grant.
const assert=require("node:assert/strict"),{createInterface}=require("node:readline"),{createHash}=require("node:crypto");
const M=require("../web/dist/model.js"),C=require("../web/dist/bridge-client.js"),D=require("../web/dist/directory-view.js"),T=require("../web/dist/file-transfers.js");
const libraryID=process.argv[2],lines=createInterface({input:process.stdin,crlfDelay:Infinity});let waiting,mask=false;
const timer=setTimeout(()=>{process.stderr.write("file-transfers-pipe: timed out\n");process.exit(1);},170000);
lines.on("line",line=>{const item=waiting;waiting=undefined;if(!item)throw Error("unexpected response");try{item.resolve(JSON.parse(line));}catch(error){item.reject(error);}});
const transport=async request=>{
  assert.ok(Buffer.byteLength(JSON.stringify(request))<=65536);
  const reply=await new Promise((resolve,reject)=>{assert.equal(waiting,undefined);waiting={resolve,reject};process.stdout.write(JSON.stringify(request)+"\n");});
  if(mask&&request.method==="finishUpload"){mask=false;assert.equal(reply.data.state,"completed");return{apiVersion:1,requestId:request.requestId,error:{code:"budgetExceeded"}};}return reply;
};
const client=C.createDesktopClient({transport,timeoutMs:60000}),raw=M.createBridgeAdapter(transport),code=value=>error=>error instanceof M.ServiceError&&error.code===value;
(async()=>{
  const source=await D.createClientDirectorySource(client),controller=T.createController(source.fileTransfers),data=Uint8Array.from({length:70001},(_,i)=>i%251);
  const unknown="55555555-0000-0000-0000-000000000000";
  assert.equal((await client.transferStatus(unknown)).state,"notVisible");await assert.rejects(client.beginUpload(unknown),code("denied"));
  await controller.prepareUpload({libraryID,name:"中日.bin",totalBytes:data.length},new Blob([data]));
  assert.deepEqual((await source.page({libraryID})).items.map(x=>x.name),["a.txt"]);
  await controller.startUpload();assert.equal(controller.snapshot().phase,"completed");
  const uploadID=controller.snapshot().transferID;
  assert.equal((await raw.request("appendUpload",{transferID:uploadID,offset:65536,parts:T.parts(data.subarray(65536))})).state,"completed");
  assert.equal((await raw.request("finishUpload",{transferID:uploadID,sha256:createHash("sha256").update(data).digest("hex")})).state,"completed");
  const blocks=[];let finished=0;
  await controller.download({libraryID,relativePath:"中日.bin"},{async write(bytes){blocks.push(bytes);},async finish(){finished++;},async abort(){blocks.length=0;}});
  assert.equal(controller.snapshot().phase,"completed");assert.equal(finished,1);assert.deepEqual(Buffer.concat(blocks),Buffer.from(data));
  await controller.prepareUpload({libraryID,name:"中日.bin",totalBytes:1},new Blob(["x"]));assert.equal(controller.snapshot().phase,"conflict");await assert.rejects(controller.startUpload(),code("denied"));
  await controller.prepareUpload({libraryID,name:"empty.bin",totalBytes:0},new Blob([]));await controller.startUpload();assert.equal(controller.snapshot().phase,"completed");
  await controller.download({libraryID,relativePath:"empty.bin"},{async write(bytes){assert.equal(bytes.length,0);},async finish(){},async abort(){}});assert.equal(controller.snapshot().phase,"completed");
  const cancelled=await client.previewUpload({libraryID,name:"cancelled.bin",totalBytes:4});await client.beginUpload(cancelled.transferID);assert.equal((await client.cancelTransfer(cancelled.transferID)).state,"cancelled");
  await controller.prepareUpload({libraryID,name:"lost.bin",totalBytes:4},new Blob(["data"]));mask=true;
  await assert.rejects(controller.startUpload(),code("budgetExceeded"));assert.equal(controller.snapshot().phase,"uncertain");await controller.check();assert.equal(controller.snapshot().phase,"completed");
  await assert.rejects(raw.request("previewUpload",{libraryID,name:"bad",totalBytes:1,root:"/tmp"}),code("invalidInput"));
  await assert.rejects(raw.request("beginDownload",{libraryID,relativePath:"../outside"}),code("unsafePath"));
  const denied=await transport({apiVersion:1,requestId:"upload-grant-denied-1",method:"authorizeFixtureLibraryUploads",params:{libraryID}});assert.equal(denied.error.code,"unsupported");
  assert.deepEqual((await source.page({libraryID})).items.map(x=>x.name),["a.txt","empty.bin","lost.bin","中日.bin"]);
  controller.dispose();source.dispose();assert.equal(client.closed,false);
  process.stderr.write("file-transfers-pipe: PASS (70001 binary bytes, bounded parts, empty file, no overwrite, cancel cleanup, masked publish receipt, no approval RPC)\n");
})().catch(error=>{process.stderr.write("file-transfers-pipe: FAIL "+error.stack+"\n");process.exitCode=1;}).finally(()=>{client.close();clearTimeout(timer);lines.close();process.stdin.destroy();process.stdout.end();});
