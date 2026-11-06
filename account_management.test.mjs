import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {once} from 'node:events';
import {createAccountApi} from './account_api.mjs';

const alice='00000000-0000-0000-0000-000000000166';
const ticket='00000000-0000-0000-0000-000000000168';
const order='00000000-0000-0000-0000-000000000169';
const requestId='00000000-0000-0000-0000-000000000170';
const authorization='Bearer '+ 'a'.repeat(48), device='b'.repeat(64);
async function setup(t,{administrator=true,adminFailure=false}={}) {
  const calls=[];
  const store={
    products:async()=>[],accountDocument:async()=>({quota:[]}),
    submitFeedback:async(...args)=>{calls.push(['submit',...args]);return ticket;},
    feedback:async user=>{calls.push(['feedback',user]);return [{id:ticket,state:'open'}];},
    adminQuery:async(...args)=>{calls.push(['query',...args]);return {rows:[]};},
    adminAction:async(...args)=>{calls.push(['action',...args]);return {changed:true,moneyRefunded:false};},
  };
  const server=http.createServer(createAccountApi({authUrl:'http://auth:9999/',store,
    fetchImpl:async(url,options)=>{
      calls.push(['verify',url]);assert.equal(options.redirect,'error');
      if(url.includes('license/status')) {
        assert.equal(options.headers['X-IKO-Device'],device);
        if(adminFailure)throw new Error('private-credential-DO-NOT-LEAK');
        return Response.json({active:true,administrator});
      }
      return Response.json({id:alice,role:'authenticated',email:'synthetic@example.invalid',email_confirmed_at:'2026-10-27'});
    }}));
  server.listen(0,'127.0.0.1');await once(server,'listening');
  t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
  return {calls,url:`http://127.0.0.1:${server.address().port}`};
}
test('explicit product/order feedback uses authenticated account and idempotency ID',async t=>{
  const {url,calls}=await setup(t);
  const response=await fetch(url+'/v1/feedback',{method:'POST',headers:{authorization,'Content-Type':'application/json'},
    body:JSON.stringify({requestId,category:'order',orderId:order,message:'Synthetic order issue'})});
  assert.equal(response.status,201);assert.equal((await response.json()).id,ticket);
  assert.deepEqual(calls.find(x=>x[0]==='submit'),['submit',alice,{requestId,category:'order',orderId:order,message:'Synthetic order issue'}]);
  assert.equal((await fetch(url+'/v1/feedback',{headers:{authorization}})).status,200);
  assert.deepEqual(calls.find(x=>x[0]==='feedback'),['feedback',alice]);
});
test('feedback rejects extra data, foreign identities and unbounded text without storing it',async t=>{
  const {url,calls}=await setup(t);
  for(const body of [{requestId,category:'product',message:'a'.repeat(4001)},
    {requestId,category:'product',message:'valid body',userId:alice},
    {requestId,category:'order',message:'missing order'},
    {requestId,category:'product',message:'valid body',apiKey:'DO-NOT-SAVE'}]) {
    const response=await fetch(url+'/v1/feedback',{method:'POST',headers:{authorization,'Content-Type':'application/json'},body:JSON.stringify(body)});
    assert.equal(response.status,400);
  }
  assert.equal(calls.some(x=>x[0]==='submit'),false);
});
test('administrator is verified online, never by package name or user-supplied role',async t=>{
  const {url,calls}=await setup(t,{administrator:false});
  const response=await fetch(url+'/v1/admin/accounts',{headers:{authorization,'X-IKO-Device':device,'X-IKO-Role':'admin'}});
  assert.equal(response.status,403);assert.equal(calls.some(x=>x[0]==='query'),false);
});
test('admin revocation stores a reason and irreversible token digest, never the token',async t=>{
  const {url,calls}=await setup(t);
  const response=await fetch(url+'/v1/admin/revoke',{method:'POST',headers:{authorization,'X-IKO-Device':device,'Content-Type':'application/json'},
    body:JSON.stringify({requestId,orderId:order,reason:'Synthetic manual review'})});
  assert.equal(response.status,200);assert.equal((await response.json()).moneyRefunded,false);
  const args=calls.find(x=>x[0]==='action');
  assert.match(args[1],/^[a-f0-9]{64}$/);assert.notEqual(args[1],'a'.repeat(48));
  assert.equal(args[2],'revoke');assert.equal(JSON.stringify(args).includes(authorization),false);
});
test('admin pagination is bounded and service failures never expose credentials',async t=>{
  const {url,calls}=await setup(t);
  assert.equal((await fetch(url+'/v1/admin/accounts?page=0',{headers:{authorization,'X-IKO-Device':device}})).status,400);
  assert.equal(calls.some(x=>x[0]==='query'),false);
  const good=await fetch(url+'/v1/admin/accounts?page=2',{headers:{authorization,'X-IKO-Device':device}});
  assert.equal(good.status,200);assert.deepEqual(calls.find(x=>x[0]==='query'),['query','accounts',{page:2,search:''}]);
  const outage=await setup(t,{adminFailure:true});
  const failure=await fetch(outage.url+'/v1/admin/accounts',{headers:{authorization,'X-IKO-Device':device}});
  assert.equal(failure.status,503);assert.doesNotMatch(await failure.text(),/DO-NOT-LEAK|private-credential/);
});
test('read-only admin navigation reuses a short verification; sensitive actions verify again',async t=>{
  const {url,calls}=await setup(t);
  for(const path of ['accounts','orders','feedback']){
    assert.equal((await fetch(url+'/v1/admin/'+path,{headers:{authorization,'X-IKO-Device':device}})).status,200);
  }
  assert.equal(calls.filter(x=>x[0]==='verify').length,1);
  assert.equal((await fetch(url+'/v1/admin/revoke',{method:'POST',headers:{authorization,'X-IKO-Device':device,'Content-Type':'application/json'},
    body:JSON.stringify({requestId,orderId:order,reason:'Synthetic explicit action'})})).status,200);
  assert.equal(calls.filter(x=>x[0]==='verify').length,2);
});
