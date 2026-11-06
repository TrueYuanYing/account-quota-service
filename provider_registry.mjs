import {createCipheriv,createDecipheriv,randomBytes} from 'node:crypto';
import {mkdir,readFile,open,rename,chmod,stat,unlink} from 'node:fs/promises';
import path from 'node:path';

export const PROVIDERS=Object.freeze([
 {id:'deepseek',label:'DeepSeek',consoleUrl:'https://platform.deepseek.com/',balanceMode:'official',endpoint:'https://api.deepseek.com/chat/completions'},
 {id:'qwen',label:'阿里云百炼',consoleUrl:'https://bailian.console.aliyun.com/',balanceMode:'manual',endpoint:'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions'},
 {id:'volcengine',label:'火山方舟',consoleUrl:'https://console.volcengine.com/ark',balanceMode:'manual',endpoint:'https://ark.cn-beijing.volces.com/api/v3/chat/completions'},
 {id:'zhipu',label:'智谱',consoleUrl:'https://bigmodel.cn/',balanceMode:'manual',endpoint:'https://open.bigmodel.cn/api/paas/v4/chat/completions'},
 {id:'siliconflow',label:'硅基流动',consoleUrl:'https://cloud.siliconflow.cn/',balanceMode:'official',endpoint:'https://api.siliconflow.cn/v1/chat/completions'},
]);
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const clean=(s,max)=>typeof s==='string'&&s.trim().length>0&&s.trim().length<=max&&!/[\u0000-\u001f\u007f]/.test(s);
function fields(input,allowed){if(!input||Array.isArray(input)||Object.keys(input).some(k=>!allowed.includes(k)))throw new Error('invalid_provider');}
const unknown=()=>({state:'never',amount:null,currency:'CNY',source:null,at:null});
function amount(value){
 if(typeof value!=='number' && !(typeof value==='string'&&/^-?\d+(?:\.\d+)?$/.test(value.trim())))throw new Error('balance_unavailable');
 const number=Number(value);if(!Number.isFinite(number)||Math.abs(number)>1e10)throw new Error('balance_unavailable');return number;
}

/** Bounded encrypted server-only state. Each successful mutation is one atomic rename. */
export async function providerRegistry({directory,encryptionKey,fetchImpl=fetch,legacyBalanceFetcher=null,now=()=>new Date()}){
 if(!/^[a-f0-9]{64}$/.test(encryptionKey??''))throw new Error('provider_encryption_key_required');
 const key=Buffer.from(encryptionKey,'hex'),file=path.join(directory,'registry.enc');
 await mkdir(directory,{recursive:true,mode:0o700});await chmod(directory,0o700);
 let data={revision:0,items:[],audit:[]},queue=Promise.resolve();
 try {
  if((await stat(file)).size>2000000)throw new Error('provider_store_too_large');
  const packed=JSON.parse(await readFile(file,'utf8'));
  const decipher=createDecipheriv('aes-256-gcm',key,Buffer.from(packed.iv,'base64'));
  decipher.setAuthTag(Buffer.from(packed.tag,'base64'));
  data=JSON.parse(Buffer.concat([decipher.update(Buffer.from(packed.body,'base64')),decipher.final()]).toString('utf8'));
  if(!Number.isSafeInteger(data.revision)||!Array.isArray(data.items)||data.items.length>12||!Array.isArray(data.audit))throw new Error('provider_store_invalid');
 }catch(error){if(error.code!=='ENOENT')throw new Error('provider_store_unavailable');}
 function view(){return {revision:data.revision,activeId:selected()?.id??null,legacy:!selected(),legacyBalance:structuredClone(data.legacy?.balance??unknown()),legacyHistory:structuredClone(data.legacy?.history??[]),catalog:PROVIDERS.map(({endpoint,...p})=>p),
  items:data.items.map(({apiKey,...p})=>({...structuredClone(p),hasKey:!!apiKey}))};}
 function selected(){const item=data.items.filter(x=>x.enabled&&x.apiKey).sort((a,b)=>a.priority-b.priority||a.id.localeCompare(b.id))[0];return item?structuredClone(item):null;}
 function mutate(action){const result=queue.then(async()=>{
  const next=structuredClone(data);await action(next);next.revision++;
  const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv);
  const body=Buffer.concat([cipher.update(JSON.stringify(next),'utf8'),cipher.final()]);
  const packed=JSON.stringify({iv:iv.toString('base64'),tag:cipher.getAuthTag().toString('base64'),body:body.toString('base64')});
  if(Buffer.byteLength(packed)>2000000)throw new Error('provider_store_too_large');
  const temp=file+'.'+randomBytes(8).toString('hex');
  try {
   const handle=await open(temp,'wx',0o600);
   try{await handle.writeFile(packed);await handle.sync();}finally{await handle.close();}
   await rename(temp,file);
   // Linux deployment also flushes the rename; Windows does not expose directory fsync.
   if(process.platform!=='win32'){const directoryHandle=await open(directory,'r');try{await directoryHandle.sync();}finally{await directoryHandle.close();}}
  }catch(error){await unlink(temp).catch(()=>{});throw error;}
  data=next;return view();
 });queue=result.catch(()=>{});return result;}
 function entry(next,id){const item=next.items.find(x=>x.id===id);if(!item)throw new Error('provider_not_found');return item;}
 function revision(next,value){if(!Number.isSafeInteger(value)||value!==next.revision)throw new Error('revision_conflict');}
 function audit(next,actor,action,id,reason){if(!clean(reason,500)||reason.trim().length<3)throw new Error('invalid_provider');next.audit.push({at:now().toISOString(),actor,action,id,reason:reason.trim()});next.audit=next.audit.slice(-500);}
 function snapshot(item,amount,currency,source){if(!Number.isFinite(amount)||Math.abs(amount)>1e10||!['CNY','USD'].includes(currency))throw new Error('invalid_provider');
  const at=now().toISOString();item.balance={state:'ok',amount,currency,source,at};
  item.history=(item.history??[]).filter(x=>!(x.currency===currency&&x.at.slice(0,10)===at.slice(0,10))).concat([{amount,currency,source,at}]).slice(-366);}
 async function boundedJson(response){if(!response.ok){await response.body?.cancel();throw new Error('balance_unavailable');}
  const reader=response.body?.getReader();let size=0;const chunks=[];if(!reader)throw new Error('balance_unavailable');
  try{while(true){const r=await reader.read();if(r.done)break;size+=r.value.length;if(size>32768)throw new Error('balance_unavailable');chunks.push(r.value);}}
  finally{await reader.cancel().catch(()=>{});}return JSON.parse(Buffer.concat(chunks).toString('utf8'));}
 const refreshing=new Map();
 return {view,selected,
  save(input,actor){fields(input,['revision','id','kind','label','model','priority','enabled','apiKey','reason']);return mutate(next=>{
   revision(next,input.revision);
   if(!UUID.test(input.id??'')||!PROVIDERS.some(p=>p.id===input.kind)||!clean(input.label,60)||!clean(input.model,128)
    ||!/^[-a-zA-Z0-9_./:]+$/.test(input.model)||!Number.isInteger(input.priority)||input.priority<1||input.priority>99||typeof input.enabled!=='boolean'
    ||(input.apiKey!==undefined&&(!clean(input.apiKey,512)||input.apiKey.trim().length<8)))throw new Error('invalid_provider');
   let item=next.items.find(x=>x.id===input.id);
   if(!item){if(next.items.length>=12||!input.apiKey)throw new Error('invalid_provider');item={id:input.id,balance:unknown(),history:[]};next.items.push(item);}
   if(item.kind&&item.kind!==input.kind&&!input.apiKey)throw new Error('invalid_provider');
   if(item.kind&&item.kind!==input.kind || input.apiKey&&input.apiKey!==item.apiKey){item.balance=unknown();item.history=[];}
   Object.assign(item,{kind:input.kind,label:input.label.trim(),model:input.model.trim(),priority:input.priority,enabled:input.enabled});
   if(input.apiKey)item.apiKey=input.apiKey.trim();
   audit(next,actor,'save',item.id,input.reason);
  });},
  priority(input,actor){fields(input,['revision','id','reason']);return mutate(next=>{revision(next,input.revision);const item=entry(next,input.id);
   for(const other of next.items)other.priority=other.id===item.id?1:Math.min(99,other.priority+1);
   item.enabled=true;audit(next,actor,'priority',item.id,input.reason);});},
  balance(input,actor){fields(input,['id','amount','currency','reason']);return mutate(next=>{const item=entry(next,input.id);snapshot(item,input.amount,input.currency,'manual');audit(next,actor,'balance',item.id,input.reason);});},
  refresh(input){fields(input,['id']);if(refreshing.has(input.id))return refreshing.get(input.id);
   if(input.id==='legacy'){
    const result=(async()=>{let value=null;
     if(legacyBalanceFetcher)try{
      const body=await boundedJson(await legacyBalanceFetcher());
      const row=body.balance_infos?.find(x=>x.currency==='CNY')??body.balance_infos?.find(x=>x.currency==='USD');
      if(row)value={amount:amount(row.total_balance),currency:row.currency};
      if(!value||!Number.isFinite(value.amount))throw new Error('balance_unavailable');
     }catch{value={error:true};}
     return mutate(next=>{const item=next.legacy??={balance:unknown(),history:[]};
      if(value&&!value.error)snapshot(item,value.amount,value.currency,'official');
      else item.balance={...item.balance,state:value?'error':'unsupported'};
     });})();refreshing.set(input.id,result);result.finally(()=>refreshing.delete(input.id)).catch(()=>{});return result;
   }
   const result=(async()=>{const original=data.items.find(x=>x.id===input.id);if(!original)throw new Error('provider_not_found');
    const snapshotKey=original.apiKey,kind=original.kind;let value=null;
    if(['deepseek','siliconflow'].includes(kind))try{
     const response=await fetchImpl(kind==='deepseek'?'https://api.deepseek.com/user/balance':'https://api.siliconflow.cn/v1/user/info',{
      headers:{Authorization:'Bearer '+snapshotKey},redirect:'error',signal:AbortSignal.timeout(8000)});
     const body=await boundedJson(response);
     if(kind==='deepseek'){const row=body.balance_infos?.find(x=>x.currency==='CNY')??body.balance_infos?.find(x=>x.currency==='USD');
      if(row)value={amount:amount(row.total_balance),currency:row.currency};}
     else if(body.status===true&&body.data?.totalBalance!=null)value={amount:amount(body.data.totalBalance),currency:'CNY'};
     if(!value||!Number.isFinite(value.amount))throw new Error('balance_unavailable');
    }catch{value={error:true};}
    return mutate(next=>{const item=entry(next,input.id);if(item.apiKey!==snapshotKey||item.kind!==kind)throw new Error('revision_conflict');
     if(value&&!value.error)snapshot(item,value.amount,value.currency,'official');
     else item.balance={...(item.balance??unknown()),state:value?'error':'unsupported'};
    });})();refreshing.set(input.id,result);result.finally(()=>refreshing.delete(input.id)).catch(()=>{});return result;
  },
 };
}
