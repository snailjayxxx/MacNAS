"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),C=require("../dist/bridge-client.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
const info=()=>({apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",languages:["zh-CN"],databaseSchema:3,active:0,completed:0,logicalReferenceBytes:0,physicalPool:"unbound",taskTimestampsAvailable:false,libraries:[]});
const token=n=>`00000000-0000-4000-8000-${String(n).padStart(12,"0")}`;
const file=(name="a",patch={})=>({name,relativePath:name,kind:"file",bytes:1,modifiedAt:"2026-10-15T00:00:00Z",...patch});
const page=(items=[],patch={})=>({pageVersion:1,order:"name-utf8",consistency:"directory-stamped-live-metadata",libraryID:"library",relativePath:"",pageSize:50,items,nextCursor:null,...patch});
async function opened(handler,context=info()) {
  const calls=[],client=C.createDesktopClient({transport:async request=>{calls.push(request);return {apiVersion:1,requestId:request.requestId,data:request.method==="overview"?context:await handler(request)};}});
  await client.overview();return {client,calls};
}
test("directory pages are explicit typed calls with frozen literal file metadata and terminal null",async()=>{
  const {client,calls}=await opened(()=>page([file("jobHash"),file("中.txt")]));
  const result=await client.listFilesPage({libraryID:"library"});assert.equal(result.items[0].name,"jobHash");assert.equal(result.nextCursor,null);assert.ok(Object.isFrozen(result.items[0]));
  assert.deepEqual(calls[1].params,{libraryID:"library",relativePath:"",pageSize:50});client.close();
});
test("wire page metadata is exact and cannot claim a snapshot or a different library/path",async()=>{
  for(const patch of [{pageVersion:2},{order:"locale"},{consistency:"snapshot"},{libraryID:"other"},{relativePath:"folder"},{pageSize:1},{total:1},{nextCursor:"sql"}]) {
    const {client}=await opened(()=>page([],{...patch}));await assert.rejects(client.listFilesPage({libraryID:"library"}),code("invalidResponse"));assert.equal(client.closed,true);
  }
  const absent=page();delete absent.nextCursor;const {client}=await opened(()=>absent);await assert.rejects(client.listFilesPage({libraryID:"library"}),code("invalidResponse"));
});
test("unsafe, duplicate or byte-regressing entries quarantine the connection",async()=>{
  for(const items of [[file("z"),file("a")],[file("A"),file("a")],[file("x",{relativePath:"../x"})],[file("x",{bytes:Number.MAX_SAFE_INTEGER+1})],[file("x",{kind:"symlink"})]]) {
    const {client}=await opened(()=>page(items));await assert.rejects(client.listFilesPage({libraryID:"library"}),code("invalidResponse"));assert.equal(client.closed,true);
  }
});
test("page size and full-page continuation boundaries are enforced",async()=>{
  for(const result of [page([file("a"),file("b")],{pageSize:1}),page([],{pageSize:1,nextCursor:token(1)})]) {
    const {client}=await opened(()=>result);await assert.rejects(client.listFilesPage({libraryID:"library",pageSize:1}),code("invalidResponse"));
  }
});
test("continuations bind library, relative path, page size and client with raw UTF8 ordering",async()=>{
  let next=false;const {client,calls}=await opened(()=>next?page([file("🐚")],{pageSize:1}):page([file("\uE000")],{pageSize:1,nextCursor:token(1)}));
  await client.listFilesPage({libraryID:"library",pageSize:1});
  for(const params of [{libraryID:"other",pageSize:1},{libraryID:"library",relativePath:"folder",pageSize:1},{libraryID:"library",pageSize:2}])await assert.rejects(client.listFilesPage({...params,cursor:token(1)}),code("denied"));
  const other=await opened(()=>page());await assert.rejects(other.client.listFilesPage({libraryID:"library",pageSize:1,cursor:token(1)}),code("denied"));other.client.close();
  next=true;assert.equal((await client.listFilesPage({libraryID:"library",pageSize:1,cursor:token(1)})).items[0].name,"🐚");assert.equal(calls.length,3);client.close();
});
test("cross-page regression is refused even when each individual page is ordered",async()=>{
  let first=true;const {client}=await opened(()=>{const result=first?page([file("z")],{pageSize:1,nextCursor:token(1)}):page([file("a")],{pageSize:1});first=false;return result;});
  await client.listFilesPage({libraryID:"library",pageSize:1});await assert.rejects(client.listFilesPage({libraryID:"library",pageSize:1,cursor:token(1)}),code("invalidResponse"));
});
test("same cursor requests and local discard serialize while response is pending",async()=>{
  let resolve;const wait=new Promise(r=>{resolve=r;});let first=true;
  const {client}=await opened(async()=>{if(first){first=false;return page([file("a")],{pageSize:1,nextCursor:token(1)});}return wait;});
  await client.listFilesPage({libraryID:"library",pageSize:1});const pending=client.listFilesPage({libraryID:"library",pageSize:1,cursor:token(1)});
  await assert.rejects(client.listFilesPage({libraryID:"library",pageSize:1,cursor:token(1)}),code("busy"));assert.throws(()=>client.discardFilePage(token(1)),code("busy"));
  resolve(page([file("b")],{pageSize:1}));await pending;assert.equal(client.discardFilePage(token(1)),false);client.close();
});
test("stale, expired and revoked capabilities are dropped locally without automatic retry",async()=>{
  for(const failure of ["staleState","expired","denied","replay","missingVolume"]) {
    let calls=0;const client=C.createDesktopClient({transport:async request=>{
      if(request.method==="overview")return {apiVersion:1,requestId:request.requestId,data:info()};
      if(++calls===1)return {apiVersion:1,requestId:request.requestId,data:page([file("a")],{pageSize:1,nextCursor:token(1)})};
      return {apiVersion:1,requestId:request.requestId,error:{code:failure}};
    }});await client.overview();await client.listFilesPage({libraryID:"library",pageSize:1});
    await assert.rejects(client.listFilesPage({libraryID:"library",pageSize:1,cursor:token(1)}),code(failure));
    await assert.rejects(client.listFilesPage({libraryID:"library",pageSize:1,cursor:token(1)}),code("denied"));assert.equal(calls,2);assert.equal(client.closed,false);client.close();
  }
});
test("directory chain storage caps at 64 independently from job cursors and discard sends no RPC",async()=>{
  let n=0;const {client,calls}=await opened(()=>page([file("a")],{pageSize:1,nextCursor:token(++n)}));
  const tokens=[];for(let i=0;i<64;i++)tokens.push((await client.listFilesPage({libraryID:"library",pageSize:1})).nextCursor);
  await assert.rejects(client.listFilesPage({libraryID:"library",pageSize:1}),code("budgetExceeded"));const before=calls.length;
  assert.equal(client.discardFilePage(tokens[0]),true);assert.equal(client.discardFilePage(tokens[0]),false);assert.equal(calls.length,before);
  await client.listFilesPage({libraryID:"library",pageSize:1});assert.equal(calls.length,before+1);client.close();
});
test("invalid options, getters and path escapes fail before transport",async()=>{
  const {client,calls}=await opened(()=>{throw Error("must not be called");});let accessed=false;
  for(const params of [null,{}, {libraryID:"library",pageSize:null},{libraryID:"library",pageSize:101},{libraryID:"library",relativePath:"../x"},{libraryID:"library",cursor:null},{libraryID:"library",root:"/"},{get libraryID(){accessed=true;return "library";}}])await assert.rejects(client.listFilesPage(params),code("invalidInput"));
  assert.equal(calls.length,1);assert.equal(accessed,false);client.close();
});
test("existing approval can be queried in read-only mode without client-side write escalation",async()=>{
  const {client}=await opened(()=>page(),{...info(),mode:"read_only_recovery"});assert.deepEqual((await client.listFilesPage({libraryID:"library"})).items,[]);client.close();
});
test("closing a pending directory page discards its late response",async()=>{
  let resolve;const wait=new Promise(r=>{resolve=r;});const {client}=await opened(()=>wait);
  const pending=client.listFilesPage({libraryID:"library"}),rejected=assert.rejects(pending,code("cancelled"));client.close();await rejected;
  resolve(page());await Promise.resolve();await assert.rejects(client.listFilesPage({libraryID:"library"}),code("unavailable"));
});
