(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"));
  else root.MacNASFileCopyView=Object.freeze(factory(root.MacNASModel));
})(globalThis,function(M){
  "use strict";
  const busyPhases=Object.freeze(["previewing","copying","cancelling","checking"]);
  const check=(value,code="invalidInput")=>{if(!value)throw new M.ServiceError(code);};
  function createPanel({document,translate,onPrepare,onConfirm,onCancel,onCheck}){
    check(document&&[translate,onPrepare,onConfirm,onCancel,onCheck].every(f=>typeof f==="function"));
    let disposed=false;
    const make=(tag,cls="")=>{const n=document.createElement(tag);n.className=cls;return n;};
    const element=make("section","file-copy-panel"),tools=make("div","file-transfer-tools"),prepare=make("button","secondary-button"),hint=make("p","file-transfer-hint"),status=make("div","file-transfer-status"),message=make("p"),path=make("p","file-transfer-path"),progress=make("progress"),count=make("p","file-transfer-count"),error=make("p","file-transfer-error"),actions=make("div","file-transfer-actions"),confirm=make("button","text-button"),cancel=make("button","text-button"),observe=make("button","text-button");
    for(const [node,key,handler]of[[prepare,"fileCopy",onPrepare],[confirm,"copyConfirm",onConfirm],[cancel,"copyCancel",onCancel],[observe,"copyCheck",onCheck]]){
      node.type="button";node.dataset[key]="";node.addEventListener("click",()=>{if(!disposed&&!node.disabled&&!node.hidden)void Promise.resolve().then(handler).catch(()=>{});});
    }
    message.setAttribute("role","status");message.setAttribute("aria-live","polite");error.setAttribute("role","alert");
    tools.append(prepare);actions.append(confirm,cancel,observe);status.append(message,path,progress,count,error,actions);element.append(tools,hint,status);
    return Object.freeze({element,render(view,{canCopy=false,selected=false,actionable=false,otherBusy=false}={}){
      if(disposed)return;const busy=busyPhases.includes(view.phase)||view.busy,uncertain=view.phase==="uncertain";
      element.setAttribute("aria-label",translate("fileCopy"));prepare.textContent=translate("fileCopy");hint.textContent=translate("fileCopyLimit");
      prepare.disabled=!canCopy||!selected||!actionable||busy||uncertain||view.phase==="ready"||otherBusy;
      confirm.textContent=translate("fileCopyReview");confirm.hidden=view.phase!=="ready";confirm.disabled=busy||otherBusy;
      cancel.textContent=translate("fileTransferCancel");cancel.hidden=!(busy||view.phase==="ready"||uncertain);cancel.disabled=view.phase==="cancelling"||view.phase==="checking";
      observe.textContent=translate("fileOperationCheck");observe.hidden=!uncertain;observe.disabled=busy;
      status.hidden=["idle","closed"].includes(view.phase);
      const keys={previewing:"fileTransferPreviewing",ready:"fileTransferReady",conflict:"fileOperationConflict",unchanged:"fileOperationUnchanged",copying:"fileCopyRunning",cancelling:"fileTransferCancelling",checking:"fileOperationChecking",completed:"fileCopyCompleted",cancelled:"fileTransferCancelled",failed:"fileCopyFailed",uncertain:"fileCopyUncertain"};
      message.textContent=status.hidden?"":translate(keys[view.phase]||"fileCopyFailed");
      const p=view.intent;path.textContent=p?p.sourceLibraryID+"/"+p.sourcePath+" → "+p.targetLibraryID+"/"+(p.parentPath?p.parentPath+"/":"")+p.name:"";
      progress.hidden=!["copying","cancelling","completed"].includes(view.phase);progress.max=Math.max(1,view.totalBytes);progress.value=view.totalBytes===0&&view.phase==="completed"?1:view.copiedBytes;
      progress.setAttribute("aria-label",translate("fileCopyProgress"));progress.setAttribute("aria-valuetext",translate("fileTransferBytes",{done:view.copiedBytes,total:view.totalBytes}));count.textContent=progress.hidden?"":translate("fileTransferBytes",{done:view.copiedBytes,total:view.totalBytes});
      error.hidden=!uncertain&&!view.error;error.textContent=uncertain?translate("fileCopyNoRepeat"):view.error?translate(view.error==="expired"?"fileTransferExpired":view.error==="integrity"?"fileTransferIntegrity":"fileCopyFailed"):"";
    },dispose(){if(disposed)return;disposed=true;element.remove();}});
  }
  function createDestinationPicker({document,translate,source,libraries,initial,libraryName=id=>id}){
    check(document&&source&&typeof source.page==="function"&&Array.isArray(libraries)&&libraries.length>0);
    let closed=false,busy=false,location=null,cursor=null,phase="idle",serial=0;
    const make=(tag,text)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;return n;};
    const element=make("section"),label=make("label",translate("fileCopyTargetLibrary")),select=make("select"),path=make("p"),up=make("button",translate("fileUp")),reload=make("button",translate("reloadFiles")),next=make("button",translate("nextFilePage")),folders=make("div"),status=make("p");
    element.className="file-copy-destination";folders.className="file-copy-folders";select.id="copy-target-library";label.htmlFor=select.id;status.setAttribute("role","status");status.setAttribute("aria-live","polite");
    for(const library of libraries){const option=make("option",libraryName(library.libraryID));option.value=library.libraryID;select.append(option);}
    select.value=initial.libraryID;for(const node of[up,reload,next])node.type="button";
    element.append(label,select,make("p",translate("fileCopyTargetHint")),path,up,reload,folders,next,status);
    function discard(value){if(value)try{source.discardCursor(value);}catch{}}
    function controls(){select.disabled=busy;up.disabled=busy||!location?.relativePath;reload.disabled=busy;next.disabled=busy||phase!=="ready"||!cursor;next.hidden=!cursor;}
    async function read(target,continued=false){
      check(!closed,"unavailable");check(!busy,"busy");busy=true;phase="loading";const request=++serial,previous=cursor;cursor=null;if(!continued)discard(previous);controls();status.textContent=translate("fileCopyTargetLoading");folders.replaceChildren();
      try{
        const page=await source.page({...target,pageSize:50,...(continued?{cursor:previous}:{})});
        if(closed||request!==serial){discard(page.nextCursor);return;}
        location=Object.freeze({libraryID:page.libraryID,relativePath:page.relativePath});cursor=page.nextCursor;phase="ready";select.value=location.libraryID;path.textContent=libraryName(location.libraryID)+"/"+location.relativePath;
        const directories=page.items.filter(item=>item.kind==="directory");
        for(const item of directories){const open=make("button",item.name);open.type="button";open.className="text-button";open.addEventListener("click",()=>{if(!busy&&!closed)void read({libraryID:location.libraryID,relativePath:item.relativePath}).catch(()=>{});});folders.append(open);}
        status.textContent=translate(directories.length?"fileCopyChooseFolder":"fileCopyNoFolders");
      }catch(error){if(!closed&&request===serial){phase="failed";select.value=location?.libraryID||initial.libraryID;status.textContent=translate("fileCopyTargetFailed");}throw error;}
      finally{busy=false;if(!closed)controls();}
    }
    select.addEventListener("change",()=>{if(!busy&&!closed)void read({libraryID:select.value,relativePath:""}).catch(()=>{});});
    up.addEventListener("click",()=>{if(!busy&&location?.relativePath)void read({libraryID:location.libraryID,relativePath:location.relativePath.split("/").slice(0,-1).join("/")}).catch(()=>{});});
    reload.addEventListener("click",()=>{if(!busy&&!closed)void read(location||initial).catch(()=>{});});
    next.addEventListener("click",()=>{if(!busy&&cursor)void read(location,true).catch(()=>{});});
    controls();
    return Object.freeze({element,load:()=>read(initial),selection(){check(!closed&&phase==="ready"&&!busy&&location,"staleState");return location;},dispose(){if(closed)return;closed=true;serial++;discard(cursor);cursor=null;folders.replaceChildren();}});
  }
  return {busyPhases,createPanel,createDestinationPicker};
});
