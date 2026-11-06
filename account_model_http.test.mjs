import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {once} from 'node:events';
import {createAccountApi} from './account_api.mjs';

test('only verified account identity reaches model; exhausted quota is distinguished from network failure',async t=>{
  const owner='00000000-0000-0000-0000-000000000068',calls=[];
  const server=http.createServer(createAccountApi({authUrl:'http://localhost/',store:{},
    fetchImpl:async()=>Response.json({id:owner,role:'authenticated',email:'fixture@example.invalid',email_confirmed_at:'2026-10-27'}),
    model:async(user,input)=>{calls.push([user,input]);throw new Error('quota_unavailable');}}));
  server.listen(0,'127.0.0.1');await once(server,'listening');
  t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
  const url=`http://127.0.0.1:${server.address().port}/v1/ai/complete`;
  assert.equal((await fetch(url,{method:'POST'})).status,401);
  assert.equal((await fetch(url,{method:'POST',body:'x'.repeat(99000)})).status,413);
  const response=await fetch(url,{method:'POST',headers:{Authorization:'Bearer synthetic-account-token-68','Content-Type':'application/json'},body:'{}'});
  assert.equal(response.status,402);assert.deepEqual(await response.json(),{detail:'feature_quota_exhausted'});
  assert.equal(calls.length,1);assert.equal(calls[0][0],owner);
});
