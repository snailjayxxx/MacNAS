"use strict";
// Called only by the guarded Swift test harness with an explicitly approved new synthetic library.
// stdout is exclusively NDJSON requests; no database configuration or signing key is inherited.
const assert=require("node:assert/strict"),{createInterface}=require("node:readline");
const M=require("../web/dist/model.js"),C=require("../web/dist/bridge-client.js"),F=require("../web/dist/directory-view.js");
const libraryID=process.argv[2],lines=createInterface({input:process.stdin,crlfDelay:Infinity});
let waiting;
const timer=setTimeout(()=>{process.stderr.write("directory-page-pipe: timed out\n");process.exit(1);},30000);
lines.on("line",line=>{const item=waiting;waiting=undefined;if(!item)throw Error("unexpected response");try{item.resolve(JSON.parse(line));}catch(error){item.reject(error);}});
const transport=request=>new Promise((resolve,reject)=>{assert.equal(waiting,undefined);waiting={resolve,reject};process.stdout.write(JSON.stringify(request)+"\n");});
const client=C.createDesktopClient({transport,timeoutMs:20000}),raw=M.createBridgeAdapter(transport);
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
(async()=>{
  const source=await F.createClientDirectorySource(client),pager=F.createDirectoryPager({source,pageSize:2});
  const first=await pager.open({libraryID});assert.deepEqual(first.items.map(x=>x.name),["a.txt","b.txt"]);assert.equal(first.hasNext,true);
  const last=await pager.next();assert.deepEqual(last.items.map(x=>x.name),["c.txt"]);assert.equal(last.hasNext,false);assert.equal(last.pageNumber,2);
  const changingPager=F.createDirectoryPager({source,pageSize:1}),changing=await changingPager.open({libraryID}); // Harness creates d.txt after encoding this response.
  await assert.rejects(changingPager.next(),code("staleState"));
  assert.deepEqual(changingPager.snapshot().items,changing.items);assert.equal(changingPager.snapshot().requiresReload,true);
  assert.throws(()=>changingPager.next(),code("denied"));
  const restarted=await source.page({libraryID,pageSize:100});assert.deepEqual(restarted.items.map(x=>x.name),["a.txt","b.txt","c.txt","d.txt"]);
  assert.equal(restarted.nextCursor,null);assert.ok(Object.isFrozen(restarted.items));assert.equal(restarted.items[0].canPreview,true);
  await assert.rejects(raw.request("listFilesPage",{libraryID:"not-authorized"}),code("denied"));
  pager.dispose();changingPager.dispose();source.dispose();assert.equal(client.closed,false);
  process.stderr.write("directory-page-pipe: PASS (borrowed source, ordered current pages, terminal, labelled stale view, explicit restart, authority)\n");
})().catch(error=>{process.stderr.write("directory-page-pipe: FAIL "+error.message+"\n");process.exitCode=1;}).finally(()=>{client.close();clearTimeout(timer);lines.close();process.stdin.destroy();process.stdout.end();});
