(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory(require("./model.js"),require("./notification-view.js"));
  else root.MacNASNotificationReconciliation=Object.freeze(factory(root.MacNASModel,root.MacNASNotifications));
})(globalThis,function(M,N){
  "use strict";
  const check=(value,code="invalidInput")=>{if(!value)throw new M.ServiceError(code);};
  const freeze=value=>{if(value&&typeof value==="object"){for(const item of Object.values(value))freeze(item);Object.freeze(value);}return value;};
  const known=new Set(["denied","readOnly","invalidInput","invalidResponse","unavailable","busy","budgetExceeded","timedOut","cancelled","database","expired","staleState","replay"]);
  const errorCode=error=>error instanceof M.ServiceError&&known.has(error.code)?error.code:"unavailable";
  function clientReady(client){
    check(client?.source==="fixture-host-client"&&!client.closed&&["overview","pollEvents","acknowledgeEvents","eventConsumerObservation"].every(key=>typeof client[key]==="function"),"unavailable");
  }
  function captureOptions(options){
    check(options&&Object.getPrototypeOf(options)===Object.prototype);
    const descriptors=Object.getOwnPropertyDescriptors(options),copy={};
    check(Object.hasOwn(descriptors,"consumerID"));
    for(const key of Reflect.ownKeys(descriptors)){
      const item=descriptors[key];check(["consumerID","capacity"].includes(key)&&item.enumerable&&Object.hasOwn(item,"value"));
      Object.defineProperty(copy,key,{value:item.value,enumerable:true});
    }
    return Object.freeze(copy);
  }
  async function createClientReconciliationView(client,options={}){
    clientReady(client);const capturedOptions=captureOptions(options),consumerID=capturedOptions.consumerID;
    // The existing view owns validation, bounded events, ACK retry targets and shared-provider serialization.
    const view=await N.createClientNotificationView(client,capturedOptions);
    let original;
    try{
      original=(await client.eventConsumerObservation(consumerID)).context;
      check(!client.closed,"unavailable");
      check(["userID","role","mode"].every(key=>original[key]===view.context[key]),"denied");
    }
    catch(error){view.dispose();throw error;}
    let generation=0,busy=false,target=null;
    let reconciliation=freeze({phase:"idle",outcome:"unresolved",target:null,acknowledgedThrough:null,error:null});
    const state=()=>freeze({...view.snapshot(),reconciliation});
    function ready(){check(view.snapshot().phase!=="closed","unavailable");check(!busy,"busy");}
    function reset(){reconciliation=freeze({phase:"idle",outcome:"unresolved",target:null,acknowledgedThrough:null,error:null});}
    return Object.freeze({
      context:original,snapshot:state,
      dispose(){generation++;view.dispose();target=null;reconciliation=freeze({phase:"closed",outcome:"unresolved",target:null,acknowledgedThrough:null,error:null});},
      async poll(){ready();busy=true;reset();try{await view.poll();return state();}finally{busy=false;}},
      async acknowledge(){
        ready();const batch=view.snapshot();check(batch.items.length>0,"denied");
        if(target===null)target=batch.items[0].sequence;
        busy=true;reset();
        try{await view.acknowledge();target=null;return state();}finally{busy=false;}
      },
      async reconcile(candidate){
        ready();const batch=view.snapshot();
        check(target!==null&&batch.ackRetryRequired,"staleState");
        clientReady(candidate);check(candidate!==client,"invalidInput");
        const epoch=generation,captured=target;busy=true;
        reconciliation=freeze({phase:"checking",outcome:"unresolved",target:captured,acknowledgedThrough:null,error:null});
        try{
          const observation=await candidate.eventConsumerObservation(consumerID);
          if(epoch!==generation)return state();
          check(!candidate.closed,"unavailable");
          check(["contextVersion","source","scopeID","userID","role","mode"].every(key=>observation.context[key]===original[key]),"denied");
          check(original.mode==="synthetic_development","readOnly");
          const status=observation.status;
          const acknowledged=status.visibility==="visible"&&status.acknowledgedThrough>=captured;
          reconciliation=freeze({phase:"checked",outcome:acknowledged?"acknowledged":"unresolved",target:captured,
            acknowledgedThrough:status.visibility==="visible"?status.acknowledgedThrough:null,error:null});
          // This result never clears the old batch, advances confirmedThrough, sends ACK, or adopts a connection.
          return state();
        }catch(error){
          if(epoch!==generation)return state();
          const code=errorCode(error);
          reconciliation=freeze({phase:"error",outcome:"unresolved",target:captured,acknowledgedThrough:null,error:code});
          throw new M.ServiceError(code);
        }finally{busy=false;}
      }
    });
  }
  return {createClientReconciliationView};
});
