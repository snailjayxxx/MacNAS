"use strict";
// Called only by the guarded Swift test harness with an explicitly approved new synthetic library.
// stdout is exclusively NDJSON requests; no database configuration or signing key is inherited.
const assert=require("node:assert/strict"),{createInterface}=require("node:readline");
const M=require("../web/dist/model.js"),C=require("../web/dist/bridge-client.js");
const libraryID=process.argv[2],lines=createInterface({input:process.stdin,crlfDelay:Infinity});
let waiting;
const timer=setTimeout(()=>{process.stderr.write("directory-page-pipe: timed out\n");process.exit(1);},30000);
lines.on("line",line=>{const item=waiting;waiting=undefined;if(!item)throw Error("unexpected response");try{item.resolve(JSON.parse(line));}catch(error){item.reject(error);}});
const transport=request=>new Promise((resolve,reject)=>{assert.equal(waiting,undefined);waiting={resolve,reject};process.stdout.write(JSON.stringify(request)+"\n");});
const client=C.createDesktopClient({transport,timeoutMs:20000}),raw=M.createBridgeAdapter(transport);
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
(async()=>{
  await client.overview();
  const first=await client.listFilesPage({libraryID,pageSize:2});assert.deepEqual(first.items.map(x=>x.name),["a.txt","b.txt"]);assert.ok(first.nextCursor);
  const last=await client.listFilesPage({libraryID,pageSize:2,cursor:first.nextCursor});assert.deepEqual(last.items.map(x=>x.name),["c.txt"]);assert.equal(last.nextCursor,null);
  const changing=await client.listFilesPage({libraryID,pageSize:1}); // Harness creates d.txt after encoding this response.
  await assert.rejects(client.listFilesPage({libraryID,pageSize:1,cursor:changing.nextCursor}),code("staleState"));
  await assert.rejects(client.listFilesPage({libraryID,pageSize:1,cursor:changing.nextCursor}),code("denied"));
  const restarted=await client.listFilesPage({libraryID,pageSize:100});assert.deepEqual(restarted.items.map(x=>x.name),["a.txt","b.txt","c.txt","d.txt"]);
  assert.equal(restarted.nextCursor,null);assert.ok(Object.isFrozen(restarted.items));
  await assert.rejects(raw.request("listFilesPage",{libraryID:"not-authorized"}),code("denied"));
  process.stderr.write("directory-page-pipe: PASS (ordered pages, terminal null, mutation refusal, explicit restart, authority)\n");
})().catch(error=>{process.stderr.write("directory-page-pipe: FAIL "+error.message+"\n");process.exitCode=1;}).finally(()=>{client.close();clearTimeout(timer);lines.close();process.stdin.destroy();process.stdout.end();});
