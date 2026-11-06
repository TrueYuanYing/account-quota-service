import {randomUUID,timingSafeEqual} from 'node:crypto';
import {PROVIDERS} from './provider_registry.mjs';
import {validateModelInput} from './account_model.mjs';
const LIMITS={answer:1400,correct:500,translate:500,summary:700};
const json=(value,status=200)=>Response.json(value,{status});
async function content(response){const reader=response.body?.getReader();let size=0;const chunks=[];
 if(!reader)throw new Error('upstream_unavailable');
 try{while(true){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>250000)throw new Error('upstream_unavailable');chunks.push(part.value);}}
 finally{await reader.cancel().catch(()=>{});}return JSON.parse(Buffer.concat(chunks).toString('utf8'));}

export function providerGateway({registry,proxyKey,fetchImpl=fetch}){
 if(!/^[a-f0-9]{64}$/.test(proxyKey??''))throw new Error('provider_service_credential_required');
 let pending=0;
 async function complete(input,outerSignal){
  try{validateModelInput({...input,requestId:randomUUID()});}catch{return json({detail:'invalid_request'},422);}
  if(pending>=8)return json({detail:'ai_service_busy'},503);
  pending++;
  try{
   // Copy selection once. A configuration update cannot change an in-flight request.
   let selected;
   try{selected=await registry.selected();}catch{return json({detail:'upstream_not_configured'},503);}
   const signal=outerSignal?AbortSignal.any([outerSignal,AbortSignal.timeout(35000)]):AbortSignal.timeout(35000);
   if(!selected)return await fetchImpl(process.env.MODEL_RELAY_URL || 'https://example.invalid/v1/internal/complete',{
    method:'POST',redirect:'error',signal,headers:{'Content-Type':'application/json',Authorization:'Bearer '+proxyKey},body:JSON.stringify(input)});
   const definition=PROVIDERS.find(p=>p.id===selected.kind);
   if(!definition)return json({detail:'upstream_not_configured'},503);
   const payload={model:selected.model,messages:input.messages,max_tokens:LIMITS[input.feature],temperature:0.2,stream:false};
   if(selected.kind==='qwen')payload.enable_thinking=false;
   if(['deepseek','volcengine','zhipu'].includes(selected.kind))payload.thinking={type:'disabled'};
   const response=await fetchImpl(definition.endpoint,{method:'POST',redirect:'error',signal,
    headers:{'Content-Type':'application/json',Authorization:'Bearer '+selected.apiKey},body:JSON.stringify(payload)});
   if(!response.ok){await response.body?.cancel();return json({detail:'upstream_unavailable'},502);}
   const data=await content(response),choice=data.choices?.[0],text=choice?.message?.content;
   if(typeof text!=='string'||!text.trim()||['length','content_filter'].includes(choice.finish_reason))return json({detail:'upstream_unavailable'},502);
   return json({text:text.trim()});
  }catch{return json({detail:'upstream_unavailable'},502);}finally{pending--;}
 }
 return {complete,
  relayFetch:(_url,options)=>complete(JSON.parse(options.body),options.signal),
  async internal(request,response){
   const presented=request.headers.authorization??'',expected='Bearer '+proxyKey;
   if(typeof presented!=='string'||Buffer.byteLength(presented)!==Buffer.byteLength(expected)
    ||!timingSafeEqual(Buffer.from(presented),Buffer.from(expected))){response.writeHead(401,{'Content-Type':'application/json'});response.end('{"detail":"service_required"}');return;}
   let size=0;const chunks=[];
   for await(const chunk of request){size+=chunk.length;if(size>96000){response.writeHead(413);response.end();return;}chunks.push(chunk);}
   let input;try{input=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{response.writeHead(422);response.end();return;}
   const result=await complete(input);response.writeHead(result.status,{'Content-Type':'application/json','Cache-Control':'no-store'});response.end(await result.text());
  },
 };
}
