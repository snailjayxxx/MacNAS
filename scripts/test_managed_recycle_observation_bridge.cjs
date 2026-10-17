"use strict";
const assert=require("node:assert/strict"),readline=require("node:readline");
const C=require("../web/dist/bridge-client.js"),V=require("../web/dist/managed-recycle-observation.js");
const [mode,text]=process.argv.slice(2),expected=JSON.parse(text),waiting=new Map();
const input=readline.createInterface({input:process.stdin});
input.on("line",line=>{const value=JSON.parse(line),resolve=waiting.get(value.requestId);assert.ok(resolve);waiting.delete(value.requestId);resolve(value);});
const transport=request=>new Promise(resolve=>{waiting.set(request.requestId,resolve);process.stdout.write(JSON.stringify(request)+"\n");});
(async()=>{
  const client=C.createDesktopClient({transport,timeoutMs:30000});
  try{
    const who=await client.overview();assert.equal(who.databaseSchema,6);assert.equal(who.role,"administrator");
    for(const key of ["authorizeFixtureManagedRecycleObservation","settleManagedRecycleOperation","releaseCapacity","recycleManagedFile","restoreManagedFile"])assert.equal(client[key],undefined);
    if(mode==="denied"){
      await assert.rejects(client.managedRecycleObservationContext(),e=>e.code==="denied");assert.equal(client.closed,false);
    }else{
      assert.equal(mode,"approved");const model=await C.createManagedRecycleObservationModel(client,{operationID:expected.operationID,...(expected.entryID?{entryID:expected.entryID}:{}),...(expected.allocationID?{allocationID:expected.allocationID}:{})});
      assert.equal(model.snapshot().envelope,null);await model.refresh();const value=model.snapshot().envelope;
      assert.equal(value.context.scopeID,expected.scopeID);assert.equal(value.context.sourceID,expected.sourceID);assert.equal(value.context.mode,expected.mode);
      assert.equal(value.observation.visibility,expected.visibility);assert.equal(value.observation.classification,expected.classification);
      if(expected.visibility==="notVisible"){assert.equal(value.allocation,null);assert.equal(value.observation.record,null);}
      else{assert.equal(value.allocation.allocationID,expected.allocationID);assert.equal(value.allocation.declaredBytes,expected.ownedBytes);assert.equal(value.allocation.origin,expected.origin);assert.equal(value.observation.record.chargeState,expected.entryChargeState);assert.equal(value.observation.record.chargedBytes,expected.entryChargedBytes);}
      const summary=V.summarize(value,{scopeID:expected.scopeID,sourceID:expected.sourceID,ownerUserID:who.userID,mode:who.mode,operationID:expected.operationID});
      assert.equal(summary.filesystemVerified,false);assert.equal(summary.executionAuthorized,false);assert.equal(summary.capacityReleaseAuthorized,false);assert.equal(Object.hasOwn(summary,"freeBytes"),false);
      await model.refresh();model.dispose();assert.equal(client.closed,false);assert.equal(model.snapshot().envelope,null);
    }
    process.stderr.write("managed-observation-pipe: PASS "+mode+"\n");
  }finally{client.close();input.close();process.stdin.pause();}
})().catch(error=>{process.stderr.write(String(error.stack||error)+"\n");input.close();process.exitCode=1;process.stdin.pause();});
