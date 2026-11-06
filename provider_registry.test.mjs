import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {providerRegistry} from './provider_registry.mjs';

const key='a'.repeat(64),secret='synthetic-provider-secret-only';
async function setup(t,fetchImpl=async()=>Response.json({is_available:true,balance_infos:[{currency:'CNY',total_balance:'12.34'}]})){
 const dir=await mkdtemp(path.join(os.tmpdir(),'iko-provider94-'));
 t.after(()=>rm(dir,{recursive:true,force:true}));
 return {dir,registry:await providerRegistry({directory:dir,encryptionKey:key,fetchImpl})};
}
function connection(revision=0){return {revision,id:randomUUID(),kind:'deepseek',label:'课堂连接',model:'deepseek-flash',priority:1,enabled:false,apiKey:secret,reason:'管理员登记连接'};}
test('encrypted persistence, redacted reads, omitted Key keeps value and stale revision rejects',async t=>{
 const {registry,dir}=await setup(t); const input=connection();
 const view=await registry.save(input,'actor');assert.equal(view.items[0].hasKey,true);
 assert.equal(JSON.stringify(view).includes(secret),false);assert.equal((await readFile(path.join(dir,'registry.enc'),'utf8')).includes(secret),false);
 const restored=await providerRegistry({directory:dir,encryptionKey:key});assert.equal((await restored.view()).items.length,1);
 const {apiKey,...edit}=input;await restored.save({...edit,revision:1,label:'改名'},'actor');
 assert.equal((await restored.view()).items[0].hasKey,true);
 await assert.rejects(restored.save(input,'actor'),/revision_conflict/);
});
test('disabled new connection never overrides existing relay; explicit priority chooses one snapshot',async t=>{
 const {registry}=await setup(t);const first=connection();await registry.save(first,'actor');
 assert.equal(await registry.selected(),null);
 await registry.priority({revision:1,id:first.id,reason:'选择内置优先连接'},'actor');
 const second=connection(2);await registry.save({...second,enabled:true,priority:2},'actor');
 assert.equal((await registry.selected()).id,first.id);
 await registry.priority({revision:3,id:second.id,reason:'调整课堂优先连接'},'actor');
 assert.equal((await registry.selected()).id,second.id);
});
test('official balance uses fixed endpoint, records sample, and failures never turn old balance to zero',async t=>{
 let fail=false;const calls=[];
 const {registry}=await setup(t,async(url,options)=>{calls.push([url,options]);return fail?new Response('',{status:401}):Response.json({is_available:true,balance_infos:[{currency:'CNY',total_balance:'12.34'}]});});
 const input=connection();await registry.save(input,'actor');
 let view=await registry.refresh({id:input.id});assert.equal(view.items[0].balance.amount,12.34);
 assert.equal(calls[0][0],'https://api.deepseek.com/user/balance');assert.equal(calls[0][1].redirect,'error');
 fail=true;view=await registry.refresh({id:input.id});assert.equal(view.items[0].balance.state,'error');assert.equal(view.items[0].balance.amount,12.34);
 assert.equal(view.items[0].history.length,1);
});
test('unsupported balance is unknown, manual sample is labelled, invalid models/extra fields refused',async t=>{
 const {registry}=await setup(t);const input={...connection(),kind:'qwen',model:'qwen-flash'};await registry.save(input,'actor');
 let view=await registry.refresh({id:input.id});assert.equal(view.items[0].balance.amount,null);assert.equal(view.items[0].balance.state,'unsupported');
 view=await registry.balance({id:input.id,amount:5,currency:'CNY',reason:'控制台手工登记'},'actor');assert.equal(view.items[0].balance.source,'manual');
 assert.throws(()=>registry.save({...connection(view.revision),endpoint:'http://127.0.0.1'},'actor'),/invalid_provider/);
});
test('blank balance is an error and cannot overwrite a real amount as zero, including legacy path',async t=>{
 let current='8.00';const {registry,dir}=await setup(t,async()=>Response.json({balance_infos:[{currency:'CNY',total_balance:current}]}));
 const input=connection();await registry.save(input,'actor');await registry.refresh({id:input.id});
 current=' ';let view=await registry.refresh({id:input.id});assert.equal(view.items[0].balance.amount,8);assert.equal(view.items[0].balance.state,'error');
 const legacy=await providerRegistry({directory:dir,encryptionKey:key,legacyBalanceFetcher:async()=>Response.json({balance_infos:[{currency:'CNY',total_balance:current}]})});
 view=await legacy.refresh({id:'legacy'});assert.equal(view.legacyBalance.amount,null);assert.equal(view.legacyBalance.state,'error');
});
