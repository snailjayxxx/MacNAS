(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"),require("./file-transfers.js"));
  else root.MacNASFileTransferView=Object.freeze(factory(root.MacNASModel,root.MacNASFileTransfers));
})(globalThis,function(M,T){
  "use strict";
  const check=(ok,code="invalidInput")=>{if(!ok)throw new M.ServiceError(code);};
  const busyPhases=["previewing","uploading","verifying","startingDownload","downloading","cancelling"];
  function createBlobSink(){
    let blocks=[],bytes=0,blob=null,settled=false;
    return Object.freeze({get blob(){return blob;},get bytes(){return bytes;},
      async write(value){check(!settled&&value instanceof Uint8Array&&value.length<=T.chunkBytes);check(bytes+value.length<=T.fileBytes&&blocks.length<513,"budgetExceeded");blocks.push(value.slice());bytes+=value.length;},
      async finish(){check(!settled);blob=new Blob(blocks,{type:"application/octet-stream"});blocks=[];settled=true;},
      async abort(){blocks=[];blob=null;bytes=0;settled=true;}
    });
  }
  function createPanel({document,urls,translate,onUpload,onDownload,onCancel,onCheck,onConfirm}){
    check(document&&urls&&typeof urls.createObjectURL==="function"&&typeof urls.revokeObjectURL==="function");
    check([translate,onUpload,onDownload,onCancel,onCheck,onConfirm].every(f=>typeof f==="function"));let url=null,disposed=false;
    const make=(tag,classes="")=>{const node=document.createElement(tag);node.className=classes;return node;};
    const element=make("section","file-transfer-panel"),tools=make("div","file-transfer-tools"),upload=make("button","secondary-button"),download=make("button","secondary-button"),hint=make("p","file-transfer-hint");
    const status=make("div","file-transfer-status"),message=make("p"),progress=make("progress"),count=make("p","file-transfer-count"),path=make("p","file-transfer-path"),actions=make("div","file-transfer-actions"),cancel=make("button","text-button"),checkResult=make("button","text-button"),confirm=make("button","text-button"),save=make("a","secondary-button"),error=make("p","file-transfer-error");
    for(const control of[upload,download,cancel,checkResult,confirm])control.type="button";
    for(const [control,handler]of[[upload,onUpload],[download,onDownload],[cancel,onCancel],[checkResult,onCheck],[confirm,onConfirm]])control.addEventListener("click",()=>{if(!disposed&&!control.disabled)void Promise.resolve().then(handler).catch(()=>{});});
    upload.dataset.fileUpload="";download.dataset.fileDownload="";cancel.dataset.transferCancel="";checkResult.dataset.transferCheck="";save.dataset.transferSave="";
    element.setAttribute("aria-label",translate("fileTransfers"));message.setAttribute("role","status");message.setAttribute("aria-live","polite");error.setAttribute("role","alert");
    confirm.dataset.transferConfirm="";tools.append(upload,download);actions.append(confirm,cancel,checkResult,save);status.append(message,path,progress,count,error,actions);element.append(tools,hint,status);
    function clearDownload(){if(url!==null){urls.revokeObjectURL(url);url=null;}save.removeAttribute("href");save.removeAttribute("download");save.hidden=true;}
    function render(view,{canUpload=false,canDownload=false,actionable=false,otherBusy=false}={}){
      if(disposed)return;const busy=busyPhases.includes(view.phase),uncertain=view.phase==="uncertain";
      element.setAttribute("aria-label",translate("fileTransfers"));upload.textContent=translate("fileUpload");download.textContent=translate("fileDownload");cancel.textContent=translate("fileTransferCancel");checkResult.textContent=translate("fileOperationCheck");save.textContent=translate("fileSaveLocal");
      upload.disabled=!actionable||!canUpload||busy||uncertain||otherBusy;download.disabled=!actionable||!canDownload||busy||uncertain||otherBusy;
      confirm.textContent=translate("fileUploadReview");confirm.hidden=view.phase!=="ready";confirm.disabled=otherBusy;
      hint.textContent=translate(canUpload?"fileTransferLimitHint":"fileTransferReadHint");status.hidden=view.phase==="idle"||view.phase==="closed";
      const keys={previewing:"fileTransferPreviewing",ready:"fileTransferReady",conflict:"fileOperationConflict",uploading:"fileTransferUploading",verifying:"fileTransferVerifying",startingDownload:"fileTransferStarting",downloading:"fileTransferDownloading",cancelling:"fileTransferCancelling",completed:"fileTransferCompleted",cancelled:"fileTransferCancelled",failed:"fileTransferFailed",uncertain:"fileTransferUncertain"};
      message.textContent=status.hidden?"":translate(view.phase==="completed"?(view.direction==="upload"?"fileUploadCompleted":"fileDownloadCompleted"):keys[view.phase]||"fileTransferFailed");
      const captured=view.preview?.intent,pathValue=view.result?.relativePath||view.location?.relativePath||(captured?T.target(captured):"");path.textContent=(view.location?.libraryID?view.location.libraryID+"/":"")+pathValue;
      progress.hidden=!["uploading","verifying","downloading","cancelling","completed"].includes(view.phase);progress.max=Math.max(1,view.totalBytes);progress.value=view.totalBytes===0&&view.phase==="completed"?1:view.transferredBytes;
      progress.setAttribute("aria-label",translate("fileTransferProgress"));progress.setAttribute("aria-valuetext",translate("fileTransferBytes",{done:view.transferredBytes,total:view.totalBytes}));count.textContent=progress.hidden?"":translate("fileTransferBytes",{done:view.transferredBytes,total:view.totalBytes});
      error.hidden=!view.error&&!uncertain;error.textContent=uncertain?translate("fileTransferNoRepeat"):view.error?translate(view.error==="integrity"?"fileTransferIntegrity":view.error==="expired"?"fileTransferExpired":"fileTransferFailed"):"";
      cancel.hidden=!(busy||view.phase==="ready"||uncertain);cancel.disabled=view.phase==="cancelling"||view.phase==="verifying";checkResult.hidden=!uncertain;checkResult.disabled=busy;
    }
    clearDownload();
    return Object.freeze({element,render,clearDownload,
      setDownload(blob,name){check(!disposed&&blob instanceof Blob&&blob.size<=T.fileBytes&&typeof name==="string"&&!/[\\/\0]/.test(name));clearDownload();url=urls.createObjectURL(blob);save.href=url;save.download=name;save.hidden=false;},
      dispose(){if(disposed)return;clearDownload();disposed=true;element.remove();}
    });
  }
  return {busyPhases,createBlobSink,createPanel};
});
