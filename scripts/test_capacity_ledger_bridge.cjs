"use strict";
const assert=require("node:assert/strict"),readline=require("node:readline");
const C=require("../web/dist/bridge-client.js"),K=require("../web/dist/capacity-ledger-view.js");
const [mode,expectedText]=process.argv.slice(2),expected=JSON.parse(expectedText),waiting=new Map();
const input=readline.createInterface({input:process.stdin});
input.on("line",line=>{const value=JSON.parse(line),resolve=waiting.get(value.requestId);assert.ok(resolve);waiting.delete(value.requestId);resolve(value);});
const transport=request=>new Promise(resolve=>{waiting.set(request.requestId,resolve);process.stdout.write(JSON.stringify(request)+"\n");});
(async()=>{
 const client=C.createDesktopClient({transport,timeoutMs:30000});
 try{
  const who=await client.overview();assert.equal(who.databaseSchema,6);assert.equal(who.role,"administrator");
  for(const name of ["authorizeFixtureCapacityLedgerRead","receiveCapacityFile","cancelCapacityAllocation","settleRecycleOperation"])assert.equal(client[name],undefined);
  if(mode==="denied"){
   await assert.rejects(client.capacityLedgerContext(),e=>e.code==="denied");assert.equal(client.closed,false);
  }else{
   assert.equal(mode,"approved");const model=await C.createCapacityLedgerModel(client);assert.equal(model.snapshot().list,null);
   const view=await model.refresh(),value=view.list;assert.equal(value.evidence,"ledgerOnly");assert.equal(value.scopeID,expected.scopeID);
   assert.deepEqual(value.totals,expected.totals);assert.deepEqual(value.items.map(v=>[v.allocationID,v.state,v.declaredBytes]),expected.items);
   const summary=K.summarize(value,{scopeID:value.scopeID,sourceID:value.sourceID,ownerUserID:who.userID});
   assert.equal(summary.filesystemVerified,false);assert.equal(summary.executionAuthorized,false);assert.equal(Object.hasOwn(summary,"freeBytes"),false);
   await model.refresh();model.dispose();assert.equal(client.closed,false);assert.equal(model.snapshot().list,null);
  }
  process.stderr.write("capacity-ledger-pipe: PASS "+mode+"\n");
 }finally{client.close();input.close();process.stdin.pause();}
})().catch(error=>{process.stderr.write(String(error.stack||error)+"\n");input.close();process.exitCode=1;process.stdin.pause();});
