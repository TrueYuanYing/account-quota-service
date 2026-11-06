import {test} from 'node:test';
import assert from 'node:assert/strict';
import {accountModel,validateModelInput} from './account_model.mjs';
const input={feature:'answer',requestId:'00000000-0000-0000-0000-000000000068',messages:[{role:'user',content:'公开问题'}]};

test('no model secret means disabled; quota claim precedes upstream and success settles once',async()=>{
  assert.equal(accountModel({store:{}}),null);
  const calls=[];
  const service=accountModel({proxyKey:'f'.repeat(64),store:{claimModel:async(...args)=>{calls.push(['claim',...args]);return 'claimed';},
    settleModel:async(...args)=>calls.push(['settle',...args])},fetchImpl:async(url,options)=>{
      assert.equal(calls[0][0],'claim');assert.equal(url,'https://example.invalid/v1/internal/complete');
      assert.equal(JSON.parse(options.body).requestId,undefined);return Response.json({text:' 有效回答 '});}});
  assert.deepEqual(await service('user68',input),{status:200,text:'有效回答'});
  assert.deepEqual(calls.at(-1),['settle','user68',input.requestId,true]);
});

test('duplicate completed or pending requests never invoke upstream',async()=>{
  for(const state of ['completed','reserved','released']) {
    const service=accountModel({proxyKey:'f'.repeat(64),store:{claimModel:async()=>state},
      fetchImpl:async()=>{throw new Error('upstream_must_not_run');}});
    assert.equal((await service('user68',input)).status,409);
  }
});

test('upstream failures charge this attempted request and cannot leak provider or relay secret',async()=>{
  const settled=[];
  for(const response of [Response.json({secret:'private'}, {status:502}),Response.json({text:''})]) {
    const service=accountModel({proxyKey:'f'.repeat(64),store:{claimModel:async()=> 'claimed',settleModel:async(...args)=>settled.push(args)},fetchImpl:async()=>response});
    assert.deepEqual(await service('user68',input),{status:502,error:'upstream_unavailable_charged'});
  }
  assert.deepEqual(settled,[['user68',input.requestId,true],['user68',input.requestId,true]]);
});

test('malformed input or missing quota never invokes provider',async()=>{
  assert.throws(()=>validateModelInput({...input,endpoint:'https://untrusted.invalid'}));
  assert.throws(()=>validateModelInput({...input,messages:[{role:'user',content:'x'.repeat(16001)}]}));
  const service=accountModel({proxyKey:'f'.repeat(64),store:{claimModel:async()=>{throw Object.assign(new Error('quota_unavailable'),{code:'P0001'});}},
    fetchImpl:async()=>{assert.fail('must not call upstream');}});
  await assert.rejects(()=>service('user68',input),/quota_unavailable/);
});
test('one account cannot occupy all model slots; rejected excess never reserves a quota',async()=>{
 let finish;const blocked=new Promise(r=>finish=r);let claims=0;
 const service=accountModel({proxyKey:'f'.repeat(64),store:{claimModel:async()=>{claims++;return 'claimed';},settleModel:async()=>{}},fetchImpl:async()=>{await blocked;return Response.json({text:'valid'});}});
 const first=service('same-user',input),second=service('same-user',{...input,requestId:'00000000-0000-0000-0000-000000000070'});
 await new Promise(r=>setTimeout(r,0));
 const third=await service('same-user',{...input,requestId:'00000000-0000-0000-0000-000000000071'});
 assert.equal(third.status,503);assert.equal(claims,2);
 finish();await Promise.all([first,second]);
 assert.equal((await service('same-user',input)).status,200);
});


test('accepted upstream timeout is charged once, while failure result remains distinct',async()=>{
 const charged=[],results=[];
 const service=accountModel({proxyKey:'f'.repeat(64),store:{claimModel:async()=> 'claimed',settleModel:async(...args)=>charged.push(args),recordModelResult:async(...args)=>results.push(args)},
  fetchImpl:async()=>{throw new DOMException('timeout','TimeoutError');}});
 assert.deepEqual(await service('user73',input),{status:502,error:'upstream_unavailable_charged'});
 assert.deepEqual(charged,[['user73',input.requestId,true]]);
 assert.deepEqual(results,[['user73',input.requestId,false]]);
});


test('trusted relay preflight refusal does not charge an unstarted model request',async()=>{
 for(const [status,detail] of [[401,'service_required'],[503,'upstream_not_configured'],[422,'invalid_request']]) {
  const settled=[],results=[];
  const service=accountModel({proxyKey:'f'.repeat(64),store:{claimModel:async()=> 'claimed',settleModel:async(...args)=>settled.push(args),recordModelResult:async(...args)=>results.push(args)},
   fetchImpl:async()=>Response.json({detail},{status})});
  assert.deepEqual(await service('user73',input),{status:503,error:'model_not_configured'});
  assert.deepEqual(settled,[['user73',input.requestId,false]]);assert.deepEqual(results,[]);
 }
});
