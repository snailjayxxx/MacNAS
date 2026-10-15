"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const M = require("../dist/model.js");
const code = expected => error => error instanceof M.ServiceError && error.code === expected;
const success = data => M.createBridgeAdapter(async r => ({apiVersion:1,requestId:r.requestId,data}));

test("request numbers, undefined values, cycles and accessor objects cannot be silently normalized", async () => {
  let calls=0; const api=M.createBridgeAdapter(async () => {calls++;});
  const cycle={};cycle.self=cycle;
  let getterCalled=false;const getter={get value(){getterCalled=true;return "secret";}};
  for(const value of [NaN,Infinity,9007199254740992,1n,undefined,()=>{},cycle,getter,new Date()]) {
    await assert.rejects(api.request("overview",{value}),code("invalidInput"));
  }
  assert.equal(getterCalled,false);assert.equal(calls,0);
});
test("request depth, bytes and Unicode are checked before transport", async () => {
  const api=success(true);let nested={};for(let i=0;i<18;i++)nested={nested};
  await assert.rejects(api.request("overview",nested),code("budgetExceeded"));
  await assert.rejects(api.request("overview",{text:"x".repeat(65536)}),code("budgetExceeded"));
  await assert.rejects(api.request("overview",{text:"\uD800"}),code("invalidInput"));
  assert.equal(await api.request("overview",{text:"日本語 🐚"}),true);
});
test("response envelopes require exactly one result and no hidden fields", async () => {
  for(const transform of [
    r=>({apiVersion:1,requestId:r.requestId,data:{},error:{code:"denied"}}),
    r=>({apiVersion:1,requestId:r.requestId,data:{},role:"administrator"}),
    r=>({apiVersion:1,requestId:r.requestId}),
    r=>({apiVersion:1,requestId:r.requestId,error:{code:"denied",message:"private/path"}}),
    r=>({apiVersion:1,requestId:r.requestId,error:{code:"unknown-private-error"}})
  ])await assert.rejects(M.createBridgeAdapter(transform).request("overview"),code("invalidResponse"));
});
test("transport errors are fixed codes without private exception details or fixture fallback", async () => {
  const api=M.createBridgeAdapter(async()=>{throw Error("/private/credentials: SQL failure");});
  await assert.rejects(api.request("listJobs"),error=>code("unavailable")(error)&&error.message==="unavailable");
  await assert.rejects(M.createBridgeAdapter().request("overview"),code("unavailable"));
});
test("response budgets, invalid numbers and accessor data are rejected", async () => {
  for(const value of [NaN,undefined,9007199254740992,{text:"x".repeat(1048577)}]) {
    await assert.rejects(success(value).request("overview"),code("invalidResponse"));
  }
  let called=false;
  await assert.rejects(success({get value(){called=true;return 1;}}).request("overview"),code("invalidResponse"));
  assert.equal(called,false);
});
test("correlation remains independent when concurrent requests resolve in reverse order", async () => {
  const waiting=[];const api=M.createBridgeAdapter(r=>new Promise(resolve=>waiting.push({r,resolve})));
  const first=api.request("overview"),second=api.request("listJobs");
  waiting[1].resolve({apiVersion:1,requestId:waiting[1].r.requestId,data:["second"]});
  waiting[0].resolve({apiVersion:1,requestId:waiting[0].r.requestId,data:{first:true}});
  assert.deepEqual(await first,{first:true});assert.deepEqual(await second,["second"]);
});
test("library discovery is whitelisted and response values are independent copies",async()=>{
  const original={libraries:[{libraryID:"fixture",state:"missing"}]},api=success(original);
  const data=await api.request("listLibraries");data.libraries[0].state="readyReadWrite";
  assert.equal(original.libraries[0].state,"missing");
  await assert.rejects(api.request("authorizeFixtureLibraryContent",{root:"/"}),code("invalidInput"));
});
