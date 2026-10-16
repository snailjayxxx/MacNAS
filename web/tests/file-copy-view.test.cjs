"use strict";
const test=require("node:test"),assert=require("node:assert/strict"),V=require("../dist/file-copy-view.js"),M=require("../dist/model.js"),I=require("../dist/i18n.js");
// Shape-only DOM substitute. No browser, layout, focus or keyboard evidence.
class Node{
  constructor(tag){this.tagName=tag;this.children=[];this.attributes={};this.dataset={};this.listeners={};this.hidden=false;this.disabled=false;this.textContent="";}
  append(...nodes){for(const node of nodes){node.parent=this;this.children.push(node);}}
  replaceChildren(...nodes){this.children=[];this.append(...nodes);}
  setAttribute(k,v){this.attributes[k]=String(v);}
  addEventListener(k,fn){this.listeners[k]=fn;}
  click(){this.listeners.click?.();}
  remove(){if(this.parent)this.parent.children=this.parent.children.filter(n=>n!==this);}
  all(){return[this,...this.children.flatMap(n=>n.all())];}
}
const document={createElement:tag=>new Node(tag)},translate=(k,v)=>I.t("zh-CN",k,v),tick=()=>new Promise(resolve=>setImmediate(resolve));
const view=patch=>({phase:"idle",busy:false,intent:null,totalBytes:0,copiedBytes:0,error:null,...patch});
test("copy panel gates writes, offers explicit confirmation and preserves literal paths",async()=>{
  const calls=[],p=V.createPanel({document,translate,onPrepare:()=>calls.push("prepare"),onConfirm:()=>calls.push("confirm"),onCancel:()=>calls.push("cancel"),onCheck:()=>calls.push("check")}),find=k=>p.element.all().find(n=>Object.hasOwn(n.dataset,k));
  p.render(view(),{canCopy:false,selected:true,actionable:true});find("fileCopy").click();await tick();assert.deepEqual(calls,[]);
  p.render(view(),{canCopy:true,selected:true,actionable:true});find("fileCopy").click();await tick();assert.deepEqual(calls,["prepare"]);
  p.render(view({phase:"ready"}));assert.equal(find("copyConfirm").hidden,false);find("copyConfirm").click();await tick();assert.deepEqual(calls,["prepare","confirm"]);
  p.render(view({phase:"copying",busy:true,totalBytes:70001,copiedBytes:32768,intent:{sourceLibraryID:"shared",sourcePath:"<script>.bin",targetLibraryID:"personal",parentPath:"中日",name:"x.bin"}}));
  const progress=p.element.all().find(n=>n.tagName==="progress");assert.equal(progress.value,32768);assert.equal(progress.max,70001);assert.match(progress.attributes["aria-valuetext"],/32768/);assert.ok(p.element.all().some(n=>n.textContent.includes("<script>.bin → personal/中日/x.bin")));
  assert.equal(find("fileCopy").disabled,true);assert.equal(find("copyCancel").disabled,false);
  p.render(view({phase:"uncertain",error:"unavailable"}),{canCopy:true,selected:true,actionable:true});assert.equal(find("fileCopy").disabled,true);assert.equal(find("copyConfirm").hidden,true);assert.equal(find("copyCheck").hidden,false);
  assert.ok(p.element.all().some(n=>n.textContent.includes("不要重复发起复制")));find("copyConfirm").click();find("copyCheck").click();await tick();assert.deepEqual(calls,["prepare","confirm","check"]);
  p.dispose();find("copyCheck").click();await tick();assert.equal(calls.length,3);
});
test("empty completion and checking have distinct progress and action states in both languages",()=>{
  for(const locale of["zh-CN","ja-JP"]){
    const p=V.createPanel({document,translate:(k,v)=>I.t(locale,k,v),onPrepare(){},onConfirm(){},onCancel(){},onCheck(){}});
    p.render(view({phase:"completed"}));const progress=p.element.all().find(n=>n.tagName==="progress");assert.equal(progress.max,1);assert.equal(progress.value,1);
    p.render(view({phase:"checking",busy:true}));assert.equal(p.element.all().find(n=>Object.hasOwn(n.dataset,"copyCancel")).disabled,true);
    for(const phase of["previewing","ready","conflict","unchanged","copying","cancelling","failed","uncertain","cancelled","closed"])p.render(view({phase}));
  }
});
test("destination picker uses bounded source pages and commits only successful directory navigation",async()=>{
  let request=[],discarded=[];const source={async page(p){request.push(p);return{libraryID:p.libraryID,relativePath:p.relativePath,items:p.relativePath?[]:[{name:"<dir>",kind:"directory",relativePath:"<dir>"},{name:"file.txt",kind:"file",relativePath:"file.txt"}],nextCursor:p.relativePath?null:"cursor-a"};},discardCursor:id=>discarded.push(id)};
  const p=V.createDestinationPicker({document,translate,source,libraries:[{libraryID:"shared"},{libraryID:"personal"}],initial:{libraryID:"shared",relativePath:""}});
  assert.throws(()=>p.selection(),e=>e instanceof M.ServiceError&&e.code==="staleState");await p.load();assert.deepEqual(p.selection(),{libraryID:"shared",relativePath:""});assert.equal(request[0].pageSize,50);
  assert.equal(p.element.all().filter(n=>n.tagName==="button"&&n.textContent==="file.txt").length,0);
  p.element.all().find(n=>n.tagName==="button"&&n.textContent==="<dir>").click();assert.throws(()=>p.selection());await tick();assert.deepEqual(p.selection(),{libraryID:"shared",relativePath:"<dir>"});assert.deepEqual(discarded,["cursor-a"]);
  p.dispose();assert.throws(()=>p.selection());
});
test("destination picker closing a pending page releases its late continuation without repopulating",async()=>{
  let deliver,discarded=[];const source={page:()=>new Promise(resolve=>deliver=resolve),discardCursor:id=>discarded.push(id)};
  const p=V.createDestinationPicker({document,translate,source,libraries:[{libraryID:"shared"}],initial:{libraryID:"shared",relativePath:""}}),pending=p.load();p.dispose();
  deliver({libraryID:"shared",relativePath:"",items:[{name:"late",kind:"directory",relativePath:"late"}],nextCursor:"late-cursor"});await pending;
  assert.deepEqual(discarded,["late-cursor"]);assert.equal(p.element.all().some(n=>n.textContent==="late"),false);assert.throws(()=>p.selection());
});
test("failed target reads disable selection and require an explicit reload",async()=>{
  let fail=true;const source={async page(p){if(fail)throw new M.ServiceError("denied");return{libraryID:p.libraryID,relativePath:p.relativePath,items:[],nextCursor:null};},discardCursor(){}};
  const p=V.createDestinationPicker({document,translate,source,libraries:[{libraryID:"shared"}],initial:{libraryID:"shared",relativePath:""}});await assert.rejects(p.load());assert.throws(()=>p.selection());fail=false;
  p.element.all().find(n=>n.textContent===translate("reloadFiles")).click();await tick();assert.deepEqual(p.selection(),{libraryID:"shared",relativePath:""});p.dispose();
});
