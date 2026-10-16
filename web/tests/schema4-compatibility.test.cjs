"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),C=require("../dist/bridge-client.js");
const P=require("../dist/task-pages.js"),N=require("../dist/notification-view.js"),F=require("../dist/directory-view.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const info=(schema=4)=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN"],databaseSchema:schema,active:0,completed:0,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[]});
const response=(request,data)=>({apiVersion:1,requestId:request.requestId,data});

test("Schema4 host keeps existing typed task, notification and directory readers without recycle mutation capabilities",async()=>{
  const methods=[];
  const client=C.createDesktopClient({transport:async request=>{
    methods.push(request.method);
    const data=request.method==="overview"?info():request.method==="listJobsPage"?{pageVersion:1,order:"id-utf8",consistency:"live",pageSize:50,items:[],nextCursor:null}:[];
    return response(request,data);
  }});
  assert.equal((await client.overview()).databaseSchema,4);
  const tasks=await P.createClientTaskSource(client),directory=await F.createClientDirectorySource(client);
  const notifications=await N.createClientNotificationView(client,{consumerID:"schema4"});
  assert.deepEqual((await tasks.page()).tasks,[]);
  assert.deepEqual(await directory.libraries(),[]);
  await notifications.poll();assert.deepEqual(notifications.snapshot().items,[]);
  assert.equal(client.previewRecycleFile,undefined);assert.equal(client.confirmRestoreFile,undefined);
  notifications.dispose();directory.dispose();assert.equal(client.closed,false);
  await tasks.close();assert.equal(client.closed,true);
  assert.ok(methods.includes("listJobsPage")&&methods.includes("pollEvents")&&methods.includes("listLibraries"));
});

test("host schema whitelist rejects unknown versions and does not adopt a schema change on an open connection",async()=>{
  for(const schema of [0,1,2,5,"4",true]){
    const client=C.createDesktopClient({transport:async request=>response(request,info(schema))});
    await assert.rejects(client.overview(),code("invalidResponse"));assert.equal(client.closed,true);
  }
  for(const [first,second] of [[3,4],[4,3]]){
    let schema=first;
    const client=C.createDesktopClient({transport:async request=>response(request,info(schema))});
    await client.overview();schema=second;
    await assert.rejects(client.overview(),code("denied"));assert.equal(client.closed,true);
  }
});

test("static fixture remains Schema3 and cannot masquerade as a durable Schema4 host",async()=>{
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession("owner");
  assert.equal((await api.overview(session)).databaseSchema,3);
  const disguised={...api,overview:async s=>({...await api.overview(s),databaseSchema:4})};
  await assert.rejects(P.createFixtureTaskSource(disguised,session),code("invalidResponse"));
  // A rejected task source ends its own borrowed fixture session, so use fresh sessions for the other views.
  const second=await api.beginFixtureSession("owner"),third=await api.beginFixtureSession("owner");
  await assert.rejects(F.createFixtureDirectorySource(disguised,second),code("invalidResponse"));
  await assert.rejects(N.createFixtureNotificationView(disguised,third,{consumerID:"schema4"}),code("invalidResponse"));
  await api.endSession(second);await api.endSession(third);
});
