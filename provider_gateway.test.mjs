import {test} from 'node:test';
import assert from 'node:assert/strict';
import {providerGateway} from './provider_gateway.mjs';
const body={feature:'answer',messages:[{role:'user',content:'公开测试问题'}]};
test('internal gateway refuses missing or malformed service credential before construction',()=>{
 for(const proxyKey of [undefined,'','undefined','a'.repeat(63)])assert.throws(()=>providerGateway({registry:{selected:()=>null},proxyKey}),/provider_service_credential_required/);
});
test('empty registry preserves trusted relay, configured supplier dispatches once with vendor controls',async()=>{
 let chosen=null;const calls=[];
 const gateway=providerGateway({registry:{selected:()=>chosen},proxyKey:'a'.repeat(64),fetchImpl:async(url,options)=>{
  calls.push([url,options]);return Response.json(new URL(url).host==='example.invalid'?{text:'旧连接有效'}:{choices:[{message:{content:'新连接有效'},finish_reason:'stop'}]});}});
 assert.equal((await (await gateway.complete(body)).json()).text,'旧连接有效');
 chosen={kind:'qwen',model:'qwen-flash',apiKey:'synthetic-secret'};
 assert.equal((await (await gateway.complete(body)).json()).text,'新连接有效');
 assert.equal(calls.length,2);assert.equal(JSON.parse(calls[1][1].body).enable_thinking,false);
 assert.equal(calls[1][1].redirect,'error');
});
test('upstream failure never retries another paid provider and never leaks private data',async()=>{
 let count=0;const gateway=providerGateway({registry:{selected:()=>({kind:'deepseek',model:'deepseek-flash',apiKey:'private-secret'})},proxyKey:'a'.repeat(64),
  fetchImpl:async()=>{count++;return new Response('private-secret',{status:401});}});
 const response=await gateway.complete(body);assert.equal(response.status,502);assert.equal(count,1);assert.equal((await response.text()).includes('private-secret'),false);
});
test('invalid and excessive inputs cannot dispatch provider',async()=>{
 let count=0;const gateway=providerGateway({registry:{selected:()=>null},proxyKey:'a'.repeat(64),fetchImpl:async()=>{count++;throw new Error();}});
 for(const input of [{...body,feature:'bad'},{...body,messages:[{role:'user',content:'x'.repeat(16001)}]}])assert.equal((await gateway.complete(input)).status,422);
 assert.equal(count,0);
});
