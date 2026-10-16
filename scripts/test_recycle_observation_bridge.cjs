"use strict";
const assert=require("node:assert/strict"),readline=require("node:readline");
const C=require("../web/dist/bridge-client.js"),R=require("../web/dist/recycle-observation.js");
const [mode,operationID,entryID,totalText,schemaText="4"]=process.argv.slice(2),totalBytes=Number(totalText),waiting=new Map();
const input=readline.createInterface({input:process.stdin});
input.on("line",line=>{const value=JSON.parse(line),resolve=waiting.get(value.requestId);assert.ok(resolve);waiting.delete(value.requestId);resolve(value);});
const transport=request=>new Promise(resolve=>{waiting.set(request.requestId,resolve);process.stdout.write(JSON.stringify(request)+"\n");});
(async()=>{
  assert.ok(Number.isSafeInteger(totalBytes)&&totalBytes>=0&&totalBytes<=16*1024*1024);
  const client=C.createDesktopClient({transport,timeoutMs:30000});
  try{
    const who=await client.overview();assert.equal(who.databaseSchema,Number(schemaText));assert.equal(who.userID,"fixture-owner");
    assert.equal(client.authorizeFixtureRecycleObservation,undefined);assert.equal(client.settleRecycleOperation,undefined);
    if(mode==="denied"){
      await assert.rejects(client.observeRecycleOperation(operationID),error=>error.code==="denied");assert.equal(client.closed,false);
    }else{
      assert.equal(mode,"approved");const value=await client.observeRecycleOperation(operationID);
      assert.equal(value.visibility,"visible");assert.equal(value.record.entryID,entryID);assert.equal(value.record.phase,"completed");
      assert.equal(value.classification,"matchedPost");assert.equal(value.record.chargeState,"retained");assert.equal(value.record.chargedBytes,totalBytes);
      const absent=await client.observeRecycleOperation("00000000-0000-4000-8000-000000000000");
      assert.equal(absent.visibility,"notVisible");assert.equal(absent.record,null);assert.equal(R.summary(absent,{operationID:absent.operationID,ownerUserID:who.userID}).requiresReview,true);
      const model=await C.createRecycleObservationModel(client,{operationID,entryID});
      const view=await model.refresh();assert.equal(view.busy,false);assert.equal(view.observation.record.operationID,operationID);model.dispose();assert.equal(client.closed,false);
    }
    process.stderr.write("recycle-observation-pipe: PASS "+mode+"\n");
  }finally{client.close();input.close();process.stdin.pause();}
})().catch(error=>{process.stderr.write(String(error.stack||error)+"\n");input.close();process.exitCode=1;process.stdin.pause();});
