import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {once} from 'node:events';
import {createAccountApi} from './account_api.mjs';

const alice='00000000-0000-0000-0000-000000000064';
const authorization='Bearer synthetic-account-token-64';
const user={id:alice,email:'synthetic@example.invalid',role:'authenticated',email_confirmed_at:'2026-10-27T00:00:00Z'};

async function start(t,{authUser=user,upstreamStatus=200,upstreamFailure=false,storeFailure=false}={}) {
  const calls=[];
  const store={
    products:async()=>[{id:'monthly_5',price_cents:500}],
    saveProfile:async(id,name)=>calls.push(['save',id,name]),
    accountDocument:async(id)=>{
      calls.push(['document',id]);
      if(storeFailure)throw new Error('postgres://DO-NOT-LEAK@example.invalid/private');
      return {displayName:'',orders:[],quota:[]};
    }
  };
  const server=http.createServer(createAccountApi({authUrl:'http://auth:9999/',store,
    fetchImpl:async(url,options)=>{
      calls.push(['auth',url]);
      assert.equal(options.redirect,'error');
      assert.equal(options.headers.Authorization,authorization);
      if(upstreamFailure)throw new Error('private-upstream-error');
      return new Response(JSON.stringify(authUser),{status:upstreamStatus});
    }}));
  server.listen(0,'127.0.0.1');await once(server,'listening');
  t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
  return {calls,url:`http://127.0.0.1:${server.address().port}`};
}

test('health/products expose no private account and keep checkout disabled',async t=>{
  const {url,calls}=await start(t);
  const data=await (await fetch(url+'/v1/products')).json();
  assert.equal(data.checkoutEnabled,false);assert.equal(data.products[0].price_cents,500);
  assert.deepEqual(calls,[]);
});
test('private account requires a valid session before querying the database',async t=>{
  const {url,calls}=await start(t);
  assert.equal((await fetch(url+'/v1/me')).status,401);assert.deepEqual(calls,[]);
});
test('account identity comes only from GoTrue, not a supplied user ID',async t=>{
  const {url,calls}=await start(t);
  const response=await fetch(url+'/v1/me?userId=someone-else',{headers:{authorization}});
  assert.equal(response.headers.get('cache-control'),'no-store');
  assert.equal((await response.json()).account.id,alice);
  assert.deepEqual(calls.filter(x=>x[0]==='document'),[['document',alice]]);
});
test('profile accepts only explicitly submitted display name, never roles/keys/text capture',async t=>{
  const {url,calls}=await start(t);
  for(const body of [{displayName:'Alice',role:'admin'}, {apiKey:'secret'}, {text:'local notes'}, {displayName:'a\nb'}]) {
    const response=await fetch(url+'/v1/me/profile',{method:'PATCH',headers:{authorization,'Content-Type':'application/json'},body:JSON.stringify(body)});
    assert.equal(response.status,400);
  }
  assert.equal(calls.some(x=>x[0]==='save'),false);
  const response=await fetch(url+'/v1/me/profile',{method:'PATCH',headers:{authorization,'Content-Type':'application/json'},body:JSON.stringify({displayName:'小窗'})});
  assert.equal(response.status,200);
  assert.deepEqual(calls.filter(x=>x[0]==='save'),[['save',alice,'小窗']]);
});
test('unverified and elevated service-role tokens are not ordinary account sessions',async t=>{
  for(const authUser of [{...user,role:'service_role'},{...user,email_confirmed_at:null}]) {
    const {url,calls}=await start(t,{authUser});
    assert.equal((await fetch(url+'/v1/me',{headers:{authorization}})).status,401);
    assert.equal(calls.some(x=>x[0]==='document'),false);
  }
});

test('oversized chunked profile receives a clear rejection without saving any input',async t=>{
  const {url,calls}=await start(t);
  const response=await new Promise((resolve,reject)=>{
    const request=http.request(url+'/v1/me/profile',{method:'PATCH',
      headers:{authorization,'Content-Type':'application/json','Transfer-Encoding':'chunked'}},response=>{
        let body='';response.setEncoding('utf8');
        response.on('data',chunk=>{body+=chunk;});
        response.on('end',()=>resolve({status:response.statusCode,body}));
      });
    request.on('error',reject);
    request.write('{"displayName":"'+ 'x'.repeat(5000));
    setTimeout(()=>request.end('"}'),30);
  });
  assert.equal(response.status,400);
  assert.equal(JSON.parse(response.body).error,'invalid_profile');
  assert.equal(calls.some(x=>x[0]==='save'),false);
});
test('expired session differs from upstream/network outage and raw errors stay private',async t=>{
  for(const scenario of [{upstreamStatus:401,expected:401},{upstreamStatus:503,expected:503},
      {upstreamFailure:true,expected:503},{storeFailure:true,expected:503}]) {
    const {url}=await start(t,scenario);
    const response=await fetch(url+'/v1/me',{headers:{authorization}});
    assert.equal(response.status,scenario.expected);
    assert.doesNotMatch(await response.text(),/DO-NOT-LEAK|postgres:|private-upstream/);
  }
});
test('payments cannot create an order or grant rights before merchant configuration',async t=>{
  const {url,calls}=await start(t);
  const response=await fetch(url+'/v1/orders',{method:'POST',headers:{authorization,'Content-Type':'application/json'},body:'{"productId":"monthly_5"}'});
  assert.equal(response.status,503);
  assert.equal((await response.json()).error,'payments_not_configured');
  assert.equal((await fetch(url+'/v1/payments/zpay/notify?trade_status=TRADE_SUCCESS')).status,503);
  assert.equal(calls.some(x=>x[0]==='save'||x[0]==='document'),false);
});
test('auth endpoint rejects public HTTP or embedded credentials',()=>{
  for(const authUrl of ['http://public.example.com','https://user:secret@example.com'])
    assert.throws(()=>createAccountApi({authUrl,store:{}}));
});
