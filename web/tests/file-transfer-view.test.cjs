"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const M=require("../dist/model.js"),V=require("../dist/file-transfer-view.js"),I=require("../dist/i18n.js");
const code=value=>error=>error instanceof M.ServiceError&&error.code===value;
// A DOM-shape double, never a browser, layout engine, file picker or download-permission test.
class Node {
 constructor(tag){this.tagName=tag;this.children=[];this.dataset={};this.attributes={};this.listeners={};this.hidden=false;this.disabled=false;this.textContent="";}
 append(...nodes){for(const node of nodes){node.parent=this;this.children.push(node);}}
 setAttribute(key,value){this.attributes[key]=String(value);}
 removeAttribute(key){delete this.attributes[key];delete this[key];}
 addEventListener(key,handler){this.listeners[key]=handler;}
 remove(){if(this.parent)this.parent.children=this.parent.children.filter(x=>x!==this);}
 click(){this.listeners.click?.();}
 all(){return[this,...this.children.flatMap(x=>x.all())];}
}
function panel(){let locale="zh-CN",created=[],revoked=[],calls=[];const value=V.createPanel({document:{createElement:tag=>new Node(tag)},urls:{createObjectURL:blob=>{created.push(blob);return"blob:fixture-"+created.length;},revokeObjectURL:url=>revoked.push(url)},translate:(k,v)=>I.t(locale,k,v),...Object.fromEntries(["Upload","Download","Cancel","Check","Confirm"].map(name=>["on"+name,()=>calls.push(name)]))});
 const find=key=>value.element.all().find(n=>Object.hasOwn(n.dataset,key));return{value,created,revoked,calls,find,setLocale:value=>locale=value};}
const view=patch=>({phase:"idle",preview:null,result:null,totalBytes:0,transferredBytes:0,error:null,...patch});
test("blob sink copies delivered bytes, stays bounded and offers no Blob before successful finish",async()=>{
 const sink=V.createBlobSink(),bytes=Uint8Array.of(1,2,3);await sink.write(bytes);bytes[0]=9;assert.equal(sink.blob,null);await sink.finish();assert.deepEqual(new Uint8Array(await sink.blob.arrayBuffer()),Uint8Array.of(1,2,3));
 await assert.rejects(sink.write(Uint8Array.of(4)),code("invalidInput"));await sink.abort();assert.equal(sink.blob,null);assert.equal(sink.bytes,0);
 const bounded=V.createBlobSink(),chunk=new Uint8Array(32768);for(let n=0;n<512;n++)await bounded.write(chunk);await assert.rejects(bounded.write(Uint8Array.of(1)),code("budgetExceeded"));await bounded.abort();
});
test("DOM-shaped panel exposes real disabled controls and labelled progress with literal path text",async()=>{
 const p=panel();p.value.render(view(),{actionable:true,canUpload:false,canDownload:true});assert.equal(p.find("fileUpload").disabled,true);assert.equal(p.find("fileDownload").disabled,false);p.find("fileUpload").click();p.find("fileDownload").click();await Promise.resolve();assert.deepEqual(p.calls,["Download"]);
 p.value.render(view({phase:"uploading",totalBytes:70001,transferredBytes:32768,preview:{intent:{libraryID:"shared",parentPath:"",name:"<script>.bin"}}}),{actionable:true,canUpload:true,canDownload:true});
 const all=p.value.element.all(),progress=all.find(n=>n.tagName==="progress");assert.equal(progress.max,70001);assert.equal(progress.value,32768);assert.match(progress.attributes["aria-valuetext"],/32768/);assert.ok(all.some(n=>n.textContent==="<script>.bin"));assert.equal(p.find("fileUpload").disabled,true);assert.equal(p.find("transferCancel").hidden,false);
 p.value.render(view({phase:"completed"}));assert.equal(progress.value,1);assert.equal(progress.max,1);assert.match(progress.attributes["aria-valuetext"],/0 \/ 0/);
});
test("ready confirmation and uncertain observation have separate controls and never invoke a write automatically",async()=>{
 const p=panel();p.value.render(view({phase:"ready"}));assert.equal(p.find("transferConfirm").hidden,false);p.find("transferConfirm").click();await Promise.resolve();assert.deepEqual(p.calls,["Confirm"]);
 p.value.render(view({phase:"uncertain",error:"unavailable"}),{actionable:true,canUpload:true,canDownload:true});assert.equal(p.find("transferConfirm").hidden,true);assert.equal(p.find("transferCheck").hidden,false);assert.equal(p.find("fileUpload").disabled,true);assert.equal(p.find("fileDownload").disabled,true);assert.ok(p.value.element.all().some(n=>n.textContent.includes("不要重复上传")));assert.equal(p.created.length,0);
});
test("download links require an explicit verified Blob and revoke replaced or disposed object URLs exactly once",()=>{
 const p=panel();assert.equal(p.find("transferSave").hidden,true);p.value.setDownload(new Blob(["data"]),"中日.bin");assert.equal(p.created.length,1);assert.equal(p.find("transferSave").download,"中日.bin");assert.equal(p.find("transferSave").hidden,false);assert.deepEqual(p.calls,[]);
 p.value.setDownload(new Blob([]),"empty");assert.deepEqual(p.revoked,["blob:fixture-1"]);p.value.dispose();p.value.dispose();assert.deepEqual(p.revoked,["blob:fixture-1","blob:fixture-2"]);assert.equal(p.find("transferSave").href,undefined);assert.equal(p.find("transferSave").hidden,true);
});
test("locale changes re-render all transfer labels and cancelled or failed paths offer no new save link",()=>{
 const p=panel();for(const phase of["previewing","ready","conflict","uploading","verifying","startingDownload","downloading","cancelling","completed","cancelled","failed","uncertain"]){p.setLocale("ja-JP");p.value.render(view({phase,error:phase==="failed"?"integrity":null}),{actionable:true,canUpload:true});assert.equal(p.find("fileUpload").textContent,"ファイルをアップロード");assert.equal(p.find("transferSave").hidden,true);}
 assert.equal(p.value.element.attributes["aria-label"],"ファイル転送");assert.equal(p.created.length,0);
});
