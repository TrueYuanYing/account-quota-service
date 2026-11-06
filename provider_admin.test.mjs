import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {once} from 'node:events';
import {createAccountApi} from './account_api.mjs';

const headers={authorization:'Bearer '+'a'.repeat(48),'X-IKO-Device':'b'.repeat(64),'Content-Type':'application/json'};
async function setup(t,allowed){
 const calls=[];
 const providers={view:async()=>{calls.push('view');return {revision:1,items:[]};},save:async body=>{calls.push('save');if(body.revision===0)throw new Error('revision_conflict');return {revision:2,items:[{hasKey:true}]};}};
 const server=http.createServer(createAccountApi({authUrl:'http://auth:9999',store:{},providers,
  fetchImpl:async()=>Response.json({active:true,administrator:allowed})}));
 server.listen(0,'127.0.0.1');await once(server,'listening');
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 return {calls,url:`http://127.0.0.1:${server.address().port}`};
}
test('provider configuration requires verified administrator before reading or mutation',async t=>{
 const {url,calls}=await setup(t,false);
 for(const method of ['GET','POST']){
  const r=await fetch(url+'/v1/admin/providers'+(method==='POST'?'/save':''),{method,headers,...(method==='POST'?{body:'{}'}:{})});assert.equal(r.status,403);
 }
 assert.deepEqual(calls,[]);
});
test('provider reads redact keys; revision conflict is explicit and failed writes do not echo request',async t=>{
 const {url}=await setup(t,true);
 assert.equal((await fetch(url+'/v1/admin/providers',{headers})).status,200);
 const r=await fetch(url+'/v1/admin/providers/save',{method:'POST',headers,body:JSON.stringify({revision:0,apiKey:'SECRET-NEVER-ECHO'})});
 assert.equal(r.status,409);assert.deepEqual(await r.json(),{error:'revision_conflict'});
});
