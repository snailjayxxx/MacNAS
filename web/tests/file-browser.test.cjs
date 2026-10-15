"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const M = require("../dist/model.js"), D = require("../dist/directory-view.js"), B = require("../dist/file-browser.js");
const code = value => error => error instanceof M.ServiceError && error.code === value;
const token = n => "30000000-0000-0000-0000-" + n.toString(16).padStart(12, "0");
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return { promise, resolve, reject }; };
const info = {apiVersion:1,source:"fixture-host",userID:"fixture-owner",role:"administrator",mode:"synthetic_development",databaseSchema:3,physicalPool:"unbound",languages:["zh-CN","ja-JP"],active:0,completed:0,logicalReferenceBytes:0,taskTimestampsAvailable:false,libraries:[]};
const item = (name,parent="",kind="file",bytes=1) => ({name,relativePath:(parent?parent+"/":"")+name,kind,modifiedAt:"2026-10-15T00:00:00Z",...(kind==="file"?{bytes}:{})});
const page = (p,items=[item("a.txt",p.relativePath)],nextCursor=null) => ({pageVersion:1,order:"name-utf8",consistency:"directory-stamped-live-metadata",libraryID:p.libraryID,relativePath:p.relativePath,pageSize:p.pageSize,items,nextCursor});
async function fixture(scenario="owner",options={}) {
  const api=M.createFixtureAdapter(),session=await api.beginFixtureSession(scenario),source=await D.createFixtureDirectorySource(api,session);
  return {api,session,source,browser:B.createFileBrowser({source,...options})};
}
async function setup(overrides={},options={}) {
  const client={source:"fixture-host-client",closed:false,calls:[],discarded:[],overview:async()=>info,listLibraries:async()=>[],
    async listFilesPage(p){this.calls.push(p);return page(p);},async previewFile(p){return{libraryID:p.libraryID,relativePath:p.relativePath,text:"x",utf8Bytes:1};},
    discardFilePage(value){this.discarded.push(value);return true;},...overrides};
  const source=await D.createClientDirectorySource(client);return{client,source,browser:B.createFileBrowser({source,...options})};
}
test("default browsing loads the entire small fixture folder without three-item paging or fake metadata",async()=>{
  const {browser}=await fixture(),view=await browser.open({libraryID:"shared"});
  assert.equal(view.items.length,8);assert.equal(view.hasNext,false);assert.equal(view.pageNumber,1);
  assert.equal(view.visibleItems[0].kind,"directory");assert.equal(view.visibleItems[0].bytes,null);assert.equal(view.visibleItems[0].modifiedAt,null);
  assert.equal(view.total,undefined);assert.equal(view.nextCursor,undefined);assert.ok(Object.isFrozen(view.visibleItems));
});
test("back forward parent reload and branch history commit only successful navigation",async()=>{
  const {browser}=await fixture();await browser.open({libraryID:"shared"});await browser.open({libraryID:"shared",relativePath:"Notes"});
  await browser.open({libraryID:"personal",relativePath:"Travel"});assert.equal((await browser.back()).relativePath,"Notes");
  assert.equal((await browser.back()).libraryID,"shared");assert.equal((await browser.forward()).relativePath,"Notes");
  assert.equal((await browser.up()).relativePath,"");assert.equal(browser.snapshot().canGoForward,false);
  await browser.reload();assert.equal((await browser.back()).relativePath,"Notes");
  await assert.rejects(browser.open({libraryID:"shared",relativePath:"missing"}),code("denied"));
  assert.equal(browser.snapshot().relativePath,"Notes");assert.equal(browser.snapshot().requiresReload,true);
  assert.throws(()=>browser.select("Notes/Readme.txt"),code("denied"));
  assert.equal((await browser.reload()).relativePath,"Notes");assert.equal((await browser.back()).relativePath,"");
});
test("history is bounded and a reload does not create an extra entry",async()=>{
  const {browser}=await setup({}, {maximumHistory:2});
  for(const libraryID of ["a","b","c"])await browser.open({libraryID});
  await browser.reload();assert.equal((await browser.back()).libraryID,"b");assert.equal(browser.snapshot().canGoBack,false);
  assert.throws(()=>browser.back(),code("denied"));assert.equal((await browser.forward()).libraryID,"c");
});
test("paging accumulates loaded files and previews from earlier pages remain valid",async()=>{
  const {browser,client}=await setup({listFilesPage:async p=>p.cursor?page(p,[item("c.txt")]):page(p,[item("a.txt"),item("b.txt")],token(1))},{pageSize:2});
  await browser.open({libraryID:"literal"});browser.select("a.txt");const view=await browser.next();
  assert.deepEqual(view.items.map(x=>x.name),["a.txt","b.txt","c.txt"]);assert.deepEqual(view.selectedPaths,["a.txt"]);
  assert.equal((await browser.preview("a.txt")).text,"x");assert.equal(client.closed,false);
  await assert.rejects(browser.preview("off-page.txt"),code("denied"));await assert.rejects(browser.next(),code("denied"));
});
test("large directories stop at the loaded budget without evicting files or making another call",async()=>{
  let calls=0;const {browser}=await setup({listFilesPage:async p=>{calls++;const start=p.cursor?2:0;return page(p,[item(String(start)+".txt"),item(String(start+1)+".txt")],token(calls));}},{pageSize:2,maximumLoaded:4});
  await browser.open({libraryID:"literal"});await browser.next();assert.equal(browser.snapshot().limitReached,true);
  await assert.rejects(browser.next(),code("budgetExceeded"));assert.equal(calls,2);assert.equal(browser.snapshot().items.length,4);
  browser.dispose();
});
test("selection supports toggle range select-all and filtering without selecting hidden names",async()=>{
  const {browser}=await fixture();let view=await browser.open({libraryID:"shared"});const names=view.visibleItems.map(x=>x.relativePath);
  browser.select(names[2]);browser.select(names[4],{range:true});assert.deepEqual(browser.snapshot().selectedPaths,names.slice(2,5));
  browser.select(names[3],{toggle:true});assert.deepEqual(browser.snapshot().selectedPaths,[names[2],names[4]]);
  browser.clearSelection();browser.select(names[4],{range:true});assert.deepEqual(browser.snapshot().selectedPaths,[names[4]]);
  browser.selectAll();assert.equal(browser.snapshot().selectedPaths.length,8);
  view=browser.configure({filter:"directory"});assert.equal(view.selectedItems.length,2);assert.equal(view.visibleItems.length,2);
  view=browser.configure({search:"not present"});assert.deepEqual(view.selectedPaths,[]);assert.deepEqual(browser.selectAll().selectedPaths,[]);
  assert.throws(()=>browser.select(names[0]),code("denied"));
});
test("sorting is natural folders-first in either direction and unknown values remain last",()=>{
  const rows=[item("file10.txt","","file",10),item("file2.txt","","file",2),{...item("z","","directory"),bytes:null,modifiedAt:null}, {...item("a","","directory"),bytes:null,modifiedAt:null}];
  assert.deepEqual(B.projectFiles(rows).map(x=>x.name),["a","z","file2.txt","file10.txt"]);
  assert.deepEqual(B.projectFiles(rows,{sort:"size",direction:"descending",locale:"ja-JP"}).map(x=>x.name),["z","a","file10.txt","file2.txt"]);
  const dated=[{...item("missing.txt"),modifiedAt:null},item("known.txt")];
  for(const direction of ["ascending","descending"])assert.equal(B.projectFiles(dated,{sort:"modified",direction})[0].name,"known.txt");
  assert.deepEqual(rows.map(x=>x.name),["file10.txt","file2.txt","z","a"]);
});
test("loaded search and type sorting preserve literal multilingual names and do not request unseen files",async()=>{
  const {browser,client}=await setup({listFilesPage:async p=>{client.calls.push(p);return page(p,[item("2.md"),item("jobHash.txt"),item("日本語.txt")],token(8));}},{pageSize:3});
  await browser.open({libraryID:"literal"});let view=browser.configure({search:"JOBhash",sort:"type"});
  assert.deepEqual(view.visibleItems.map(x=>x.name),["jobHash.txt"]);assert.equal(client.calls.length,1);assert.equal(view.hasNext,true);
  view=browser.configure({search:"日本語",locale:"ja-JP"});assert.equal(view.visibleItems[0].name,"日本語.txt");assert.equal(client.calls.length,1);
});
test("unsupported files are selectable for details without a preview request",async()=>{
  let previews=0;const {browser}=await setup({listFilesPage:async p=>page(p,[item("image.png")]),previewFile:async()=>{previews++;throw Error("must not run");}});
  await browser.open({libraryID:"literal"});assert.equal(browser.select("image.png").selectedItems[0].name,"image.png");
  await assert.rejects(browser.preview("image.png"),code("denied"));assert.equal(previews,0);
});
test("navigation resets selection and filters while preserving the chosen sort",async()=>{
  const {browser}=await fixture();await browser.open({libraryID:"shared"});browser.selectAll();browser.configure({filter:"file",search:"Guide",sort:"type",direction:"descending"});
  const view=await browser.open({libraryID:"shared",relativePath:"Notes"});assert.deepEqual(view.selectedPaths,[]);
  assert.deepEqual(view.settings,{filter:"all",search:"",sort:"type",direction:"descending",locale:"zh-CN"});
});
test("an expired continuation preserves labelled loaded rows and requires an explicit reload",async()=>{
  const {browser}=await setup({listFilesPage:async p=>{if(p.cursor)throw new M.ServiceError("expired");return page(p,[item("a.txt")],token(1));}},{pageSize:1});
  await browser.open({libraryID:"literal"});await assert.rejects(browser.next(),code("expired"));const failed=browser.snapshot();
  assert.equal(failed.libraryID,"literal");assert.equal(failed.items[0].name,"a.txt");assert.equal(failed.requiresReload,true);
  await assert.rejects(browser.preview("a.txt"),code("denied"));assert.equal((await browser.reload()).phase,"ready");
});
test("superseded navigation drops the late page and discards its cursor",async()=>{
  const late=deferred();const {browser,client}=await setup({listFilesPage:p=>p.libraryID==="old"?late.promise:Promise.resolve(page(p))});
  const pending=browser.open({libraryID:"old"});assert.equal(browser.snapshot().libraryID,null);
  await browser.open({libraryID:"new"});late.resolve(page({libraryID:"old",relativePath:"",pageSize:50},Array.from({length:50},(_,i)=>item(String(i).padStart(2,"0")+".txt")),token(5)));
  await pending;assert.equal(browser.snapshot().libraryID,"new");assert.ok(client.discarded.includes(token(5)));
});
test("selection filtering navigation and disposal suppress late previews without closing borrowed clients",async()=>{
  for(const action of [b=>b.select("b.txt"),b=>b.configure({filter:"directory"}),b=>b.open({libraryID:"other"}),b=>b.dispose()]){
    const late=deferred();const {browser,client}=await setup({listFilesPage:async p=>page(p,[item("a.txt"),item("b.txt")]),previewFile:()=>late.promise});
    await browser.open({libraryID:"literal"});const pending=browser.preview("a.txt");await action(browser);
    late.resolve({libraryID:"literal",relativePath:"a.txt",text:"late",utf8Bytes:4});assert.equal(await pending,null);assert.equal(client.closed,false);
  }
});
test("unchanged settings do not cancel an in-flight preview",async()=>{
  const late=deferred();const {browser}=await setup({previewFile:()=>late.promise});await browser.open({libraryID:"literal"});
  const pending=browser.preview("a.txt");browser.configure({locale:"zh-CN"});late.resolve({libraryID:"literal",relativePath:"a.txt",text:"x",utf8Bytes:1});
  assert.equal((await pending).text,"x");assert.equal(browser.snapshot().previewPhase,"ready");
});
test("preview failures retain stale rows and require rereading instead of displaying raw errors",async()=>{
  const {browser}=await setup({previewFile:async()=>{throw Error("private diagnostic");}});await browser.open({libraryID:"literal"});
  await assert.rejects(browser.preview("a.txt"),code("unavailable"));const view=browser.snapshot();
  assert.equal(view.error,"unavailable");assert.equal(view.items.length,1);assert.equal(view.requiresReload,true);assert.doesNotMatch(JSON.stringify(view),/private diagnostic/);
});
test("reader and recovery browsing respect provider authorization and never obtain write capabilities",async()=>{
  const reader=await fixture("reader");await reader.browser.open({libraryID:"shared"});
  await assert.rejects(reader.browser.open({libraryID:"personal"}),code("denied"));assert.equal(reader.browser.snapshot().libraryID,"shared");
  const recovery=await fixture("recovery");await recovery.browser.open({libraryID:"personal"});assert.equal((await recovery.browser.preview("Private.txt")).relativePath,"Private.txt");
  assert.equal(recovery.source.context.mode,"read_only_recovery");assert.equal(recovery.browser.remove,undefined);
});
test("disposal clears all location and selection state and leaves the session usable",async()=>{
  const {browser,api,session,source}=await fixture();await browser.open({libraryID:"shared"});browser.selectAll();browser.dispose();browser.dispose();
  const view=browser.snapshot();assert.deepEqual(view.items,[]);assert.deepEqual(view.selectedPaths,[]);assert.equal(view.libraryID,null);assert.equal(view.canGoBack,false);
  await assert.rejects(browser.open({libraryID:"shared"}),code("unavailable"));assert.equal(source.closed,false);assert.equal((await api.overview(session)).userID,"fixture-owner");
});
test("configuration and requests reject invalid bounds and accessors without evaluating them",async()=>{
  const {source,browser}=await fixture();let touched=0;const accessor={source};Object.defineProperty(accessor,"pageSize",{get(){touched++;return 50;},enumerable:true});
  assert.throws(()=>B.createFileBrowser(accessor),code("invalidInput"));assert.equal(touched,0);
  for(const options of [{pageSize:null},{pageSize:101},{maximumLoaded:1001},{maximumLoaded:null},{maximumHistory:1},{maximumHistory:null},{unknown:true}])
    assert.throws(()=>B.createFileBrowser({source,...options}),code("invalidInput"));
  for(const target of [{libraryID:"shared",relativePath:"../a"},{libraryID:"shared",relativePath:"a\\b"},{libraryID:"shared",relativePath:"\ud800"},{libraryID:"shared",extra:true}])
    await assert.rejects(browser.open(target),code("invalidInput"));
  for(const settings of [{search:"x".repeat(1025)},{sort:"global"},{locale:"en-US"},{direction:"down"},{filter:"photo"}])assert.throws(()=>browser.configure(settings),code("invalidInput"));
  await browser.open({libraryID:"shared"});assert.throws(()=>browser.select("jobHash.txt",{range:"yes"}),code("invalidInput"));
});
