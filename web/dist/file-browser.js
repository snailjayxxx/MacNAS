(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"),require("./directory-view.js"));
  else root.MacNASFileBrowser=Object.freeze(factory(root.MacNASModel,root.MacNASDirectoryView));
})(globalThis,function(M,D){
  "use strict";
  const encoder=new TextEncoder(),check=(value,code="invalidInput")=>{if(!value)throw new M.ServiceError(code);};
  const freeze=value=>{if(value&&typeof value==="object"){for(const item of Object.values(value))freeze(item);Object.freeze(value);}return value;};
  const same=(a,b)=>a?.libraryID===b?.libraryID&&a?.relativePath===b?.relativePath;
  function fields(value,allowed,required=[]){
    check(value&&Object.getPrototypeOf(value)===Object.prototype);
    const descriptors=Object.getOwnPropertyDescriptors(value),copy={};
    check(required.every(key=>Object.hasOwn(descriptors,key)));
    for(const key of Reflect.ownKeys(descriptors)){
      const item=descriptors[key];check(typeof key==="string"&&allowed.includes(key)&&item.enumerable&&Object.hasOwn(item,"value"));
      Object.defineProperty(copy,key,{value:item.value,enumerable:true});
    }
    return copy;
  }
  function text(value,maximum,empty=false){
    check(typeof value==="string"&&(empty||value.length>0)&&value.isWellFormed()&&!value.includes("\0")&&encoder.encode(value).length<=maximum);return value;
  }
  function location(value){
    const p=fields(value,["libraryID","relativePath"],["libraryID"]),relativePath=Object.hasOwn(p,"relativePath")?text(p.relativePath,4096,true):"";
    check(!relativePath||relativePath.split("/").length<=128&&!relativePath.includes("\\")&&relativePath.split("/").every(x=>x&&x!=="."&&x!==".."&&!x.includes(":")));
    return freeze({libraryID:text(p.libraryID,128),relativePath});
  }
  function options(value){
    const p=fields(value,["search","filter","sort","direction","locale"]);
    if(Object.hasOwn(p,"search"))text(p.search,1024,true);
    if(Object.hasOwn(p,"filter"))check(["all","file","directory"].includes(p.filter));
    if(Object.hasOwn(p,"sort"))check(["name","size","type","modified"].includes(p.sort));
    if(Object.hasOwn(p,"direction"))check(["ascending","descending"].includes(p.direction));
    if(Object.hasOwn(p,"locale"))check(["zh-CN","ja-JP"].includes(p.locale));
    return p;
  }
  const extension=item=>item.kind==="directory"?"":item.name.includes(".")?item.name.split(".").at(-1).toLocaleLowerCase():"";
  function projectFiles(items,settings={}){
    check(Array.isArray(items)&&items.length<=1000);
    const config={search:"",filter:"all",sort:"name",direction:"ascending",locale:"zh-CN",...options(settings)},query=config.search.trim().toLocaleLowerCase();
    const compare=new Intl.Collator(config.locale,{numeric:true,sensitivity:"base"}).compare,sign=config.direction==="ascending"?1:-1;
    return freeze(items.filter(x=>(config.filter==="all"||x.kind===config.filter)&&x.name.toLocaleLowerCase().includes(query)).sort((a,b)=>{
      if(a.kind!==b.kind)return a.kind==="directory"?-1:1;
      const x=config.sort==="size"?a.bytes:config.sort==="modified"?a.modifiedAt:config.sort==="type"?extension(a):a.name;
      const y=config.sort==="size"?b.bytes:config.sort==="modified"?b.modifiedAt:config.sort==="type"?extension(b):b.name;
      if(x===null&&y!==null)return 1;if(y===null&&x!==null)return -1;
      const result=x===y?0:typeof x==="number"&&typeof y==="number"?x-y:x===null||y===null?0:compare(String(x),String(y));
      return sign*(result||compare(a.name,b.name)||(a.name<b.name?-1:a.name>b.name?1:0));
    }));
  }
  function createFileBrowser(configuration){
    const config=fields(configuration,["source","pageSize","maximumLoaded","maximumHistory"],["source"]);
    const {source}=config,pageSize=Object.hasOwn(config,"pageSize")?config.pageSize:50,maximumLoaded=Object.hasOwn(config,"maximumLoaded")?config.maximumLoaded:1000,maximumHistory=Object.hasOwn(config,"maximumHistory")?config.maximumHistory:64;
    check(Number.isSafeInteger(pageSize)&&pageSize>=1&&pageSize<=100);
    check(Number.isSafeInteger(maximumLoaded)&&maximumLoaded>=pageSize&&maximumLoaded<=1000);
    check(Number.isSafeInteger(maximumHistory)&&maximumHistory>=2&&maximumHistory<=128);
    let pager=D.createDirectoryPager({source,pageSize}),generation=0,previewGeneration=0,history=[],historyIndex=-1,anchor=null;
    let view=freeze({phase:"idle",libraryID:null,relativePath:"",items:[],pageNumber:0,hasNext:false,requiresReload:false,error:null,selectedPaths:[],activePath:null,
      previewPhase:"idle",previewError:null,settings:{search:"",filter:"all",sort:"name",direction:"ascending",locale:"zh-CN"}});
    const update=patch=>{view=freeze({...view,...patch});return snapshot();};
    function snapshot(){
      const visible=projectFiles(view.items,view.settings),selected=view.items.filter(x=>view.selectedPaths.includes(x.relativePath));
      return freeze({...view,visibleItems:visible,selectedItems:selected,canGoBack:historyIndex>0,canGoForward:historyIndex>=0&&historyIndex<history.length-1,
        canGoUp:!!view.libraryID&&view.relativePath!=="",limitReached:view.hasNext&&view.items.length+pageSize>maximumLoaded,maximumLoaded});
    }
    function alive(){check(view.phase!=="closed"&&!source.closed,"unavailable");}
    function ready(){alive();check(view.phase!=="loading","busy");}
    function clearPreview(){previewGeneration++;}
    function remember(target,index){
      if(index!==undefined){historyIndex=index;return;}
      if(same(history[historyIndex],target))return;
      history=history.slice(0,historyIndex+1);history.push(target);
      if(history.length>maximumHistory)history.shift();historyIndex=history.length-1;
    }
    async function navigate(target,index){
      alive();const requested=location(target),epoch=++generation;clearPreview();
      update({phase:"loading",error:null,previewPhase:"idle",previewError:null,selectedPaths:[],activePath:null});anchor=null;
      try{
        const result=await pager.open(requested);if(epoch!==generation)return snapshot();
        remember(requested,index);
        return update({...requested,phase:"ready",items:result.items,pageNumber:1,hasNext:result.hasNext,requiresReload:false,
          settings:{...view.settings,search:"",filter:"all"}});
      }catch(error){
        if(epoch!==generation)return snapshot();
        update({phase:"error",hasNext:false,requiresReload:true,error:error.code||"unavailable"});throw new M.ServiceError(view.error);
      }
    }
    return Object.freeze({
      snapshot,
      open:target=>navigate(target),
      back(){ready();check(historyIndex>0,"denied");return navigate(history[historyIndex-1],historyIndex-1);},
      forward(){ready();check(historyIndex>=0&&historyIndex<history.length-1,"denied");return navigate(history[historyIndex+1],historyIndex+1);},
      up(){ready();check(view.libraryID&&view.relativePath,"denied");return navigate({libraryID:view.libraryID,relativePath:view.relativePath.split("/").slice(0,-1).join("/")});},
      reload(){ready();check(view.libraryID,"denied");return navigate({libraryID:view.libraryID,relativePath:view.relativePath},historyIndex);},
      async next(){
        ready();check(view.phase==="ready"&&!view.requiresReload&&view.hasNext,"denied");check(view.items.length+pageSize<=maximumLoaded,"budgetExceeded");
        const epoch=++generation;clearPreview();update({phase:"loading",error:null,previewPhase:"idle",previewError:null});
        try{
          const result=await pager.next();if(epoch!==generation)return snapshot();
          const items=[...view.items,...result.items];check(items.length<=maximumLoaded&&new Set(items.map(x=>x.relativePath)).size===items.length,"invalidResponse");
          return update({phase:"ready",items,pageNumber:result.pageNumber,hasNext:result.hasNext,requiresReload:false});
        }catch(error){if(epoch!==generation)return snapshot();update({phase:"error",hasNext:false,requiresReload:true,error:error.code||"unavailable"});throw new M.ServiceError(view.error);}
      },
      configure(settings){
        alive();const next={...view.settings,...options(settings)};
        if(Object.keys(next).every(key=>next[key]===view.settings[key]))return snapshot();
        const visible=projectFiles(view.items,next),allowed=new Set(visible.map(x=>x.relativePath));clearPreview();
        return update({settings:next,selectedPaths:view.selectedPaths.filter(x=>allowed.has(x)),activePath:allowed.has(view.activePath)?view.activePath:null,previewPhase:"idle",previewError:null});
      },
      select(relativePath,selection={}){
        ready();check(view.phase==="ready"&&!view.requiresReload,"denied");
        text(relativePath,4096);
        const opts=fields(selection,["toggle","range"]);for(const value of Object.values(opts))check(typeof value==="boolean");
        const visible=projectFiles(view.items,view.settings),index=visible.findIndex(x=>x.relativePath===relativePath);check(index>=0,"denied");
        let paths;
        if(opts.range){const prior=visible.findIndex(x=>x.relativePath===anchor),start=prior<0?index:prior;paths=visible.slice(Math.min(start,index),Math.max(start,index)+1).map(x=>x.relativePath);if(prior<0)anchor=relativePath;}
        else if(opts.toggle){const selected=new Set(view.selectedPaths);if(selected.has(relativePath))selected.delete(relativePath);else selected.add(relativePath);paths=visible.filter(x=>selected.has(x.relativePath)).map(x=>x.relativePath);anchor=relativePath;}
        else{paths=[relativePath];anchor=relativePath;}
        clearPreview();return update({selectedPaths:paths,activePath:relativePath,previewPhase:"idle",previewError:null});
      },
      selectAll(){ready();check(view.phase==="ready"&&!view.requiresReload,"denied");const paths=projectFiles(view.items,view.settings).map(x=>x.relativePath);clearPreview();anchor=paths[0]??null;return update({selectedPaths:paths,activePath:paths[0]??null,previewPhase:"idle",previewError:null});},
      clearSelection(){alive();clearPreview();anchor=null;return update({selectedPaths:[],activePath:null,previewPhase:"idle",previewError:null});},
      async preview(relativePath){
        text(relativePath,4096);
        ready();check(view.phase==="ready"&&!view.requiresReload&&view.items.some(x=>x.relativePath===relativePath&&x.canPreview),"denied");
        const epoch=generation,serial=++previewGeneration,libraryID=view.libraryID;anchor=relativePath;update({selectedPaths:[relativePath],activePath:relativePath,previewPhase:"loading",previewError:null});
        try{
          const result=await source.preview({libraryID,relativePath});if(epoch!==generation||serial!==previewGeneration)return null;
          update({previewPhase:"ready"});return result;
        }catch(error){if(epoch!==generation||serial!==previewGeneration)return null;update({phase:"error",hasNext:false,requiresReload:true,error:error.code||"unavailable",previewPhase:"error",previewError:error.code||"unavailable"});throw new M.ServiceError(view.error);}
      },
      dispose(){if(view.phase==="closed")return;generation++;clearPreview();pager.dispose();history=[];historyIndex=-1;anchor=null;update({phase:"closed",libraryID:null,relativePath:"",pageNumber:0,items:[],selectedPaths:[],activePath:null,hasNext:false,requiresReload:false,error:null,previewPhase:"idle",previewError:null});}
    });
  }
  return {createFileBrowser,projectFiles};
});
