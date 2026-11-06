import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readdir,rm,readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {modelJournal} from './model_journal.mjs';
import {accountModel} from './account_model.mjs';
const user='00000000-0000-0000-0000-000000000068',request='00000000-0000-0000-0000-000000000069';
const input={feature:'answer',requestId:request,messages:[{role:'user',content:'do not persist this text'}]};

test('transient settlement error retries without duplicate upstream call',async()=>{
  let attempts=0,calls=0;
  const app=accountModel({proxyKey:'a'.repeat(64),store:{claimModel:async()=> 'claimed',settleModel:async()=>{if(attempts++===0)throw Error('transient database');}},
    fetchImpl:async()=>{calls++;return Response.json({text:'valid result'});}});
  assert.deepEqual(await app(user,input),{status:200,text:'valid result'});
  assert.equal(attempts,2);assert.equal(calls,1);
});
test('known success/failure survives failed settlement and replays once at restart, without transcript storage',async t=>{
  const dir=await mkdtemp(join(tmpdir(),'model68-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));
  for(const success of [true,false]) {
    const journal=modelJournal(dir);
    const app=accountModel({proxyKey:'a'.repeat(64),journal,store:{claimModel:async()=> 'claimed',settleModel:async()=>{throw Error('database offline');}},
      fetchImpl:async()=>Response.json({text:success?'valid result':''})});
    await assert.rejects(()=>app(user,input),/database offline/);
    const names=await readdir(dir);assert.equal(names.length,1);
    const value=JSON.parse(await readFile(dir+'/'+names[0],'utf8'));
    assert.deepEqual(value,{user,request,outcome:success?'succeeded':'charged_failed'});
    const recovered=[];await journal.recover(async(...args)=>recovered.push(args));
    assert.deepEqual(recovered,[[user,request,true]]);assert.deepEqual(await readdir(dir),[]);
  }
});
test('terminated executor without durable result can be released; duplicate live request cannot claim same journal',async t=>{
  const dir=await mkdtemp(join(tmpdir(),'model68-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));const journal=modelJournal(dir);
  assert.equal(await journal.start(user,request),true);assert.equal(await journal.start(user,request),false);
  const settled=[];await journal.recover(async(...args)=>settled.push(args));
  assert.deepEqual(settled,[[user,request,false]]);
});
test('uppercase UUID requests share one claim and recover after restart',async t=>{
  const dir=await mkdtemp(join(tmpdir(),'model68-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));const journal=modelJournal(dir);
  const upperUser='ABCDEF68-0000-0000-0000-000000000068',upperRequest='ABCDEF69-0000-0000-0000-000000000069';
  assert.equal(await journal.start(upperUser,upperRequest),true);
  assert.equal(await journal.start(upperUser.toLowerCase(),upperRequest.toLowerCase()),false);
  await journal.terminal(upperUser,upperRequest,true);
  const restored=[];await journal.recover(async(...args)=>restored.push(args));
  assert.deepEqual(restored,[[upperUser,upperRequest,true]]);assert.deepEqual(await readdir(dir),[]);
});


test('charged failed outcome restores the charge and false delivery result independently',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'model73-'));
 t.after(()=>rm(dir,{recursive:true,force:true}));const journal=modelJournal(dir);
 await journal.start(user,request);await journal.terminal(user,request,false,{charge:true});
 const charged=[],results=[];
 await journal.recover(async(...args)=>charged.push(args),async(...args)=>results.push(args));
 assert.deepEqual(charged,[[user,request,true]]);assert.deepEqual(results,[[user,request,false]]);
 assert.deepEqual(await readdir(dir),[]);
});


test('accepted dispatch interrupted by process death is charged once with unknown delivery',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'model73-'));
 t.after(()=>rm(dir,{recursive:true,force:true}));const journal=modelJournal(dir);
 await journal.start(user,request);await journal.attempted(user,request);
 const charged=[],results=[];
 await journal.recover(async(...args)=>charged.push(args),async(...args)=>results.push(args));
 assert.deepEqual(charged,[[user,request,true]]);assert.deepEqual(results,[]);
 assert.deepEqual(await readdir(dir),[]);
});


test('real executor killed after dispatch recovers one charged call without guessing success',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'model73-'));
 t.after(()=>rm(dir,{recursive:true,force:true}));
 const script=`import {accountModel} from ${JSON.stringify(new URL('./account_model.mjs',import.meta.url).href)};
import {modelJournal} from ${JSON.stringify(new URL('./model_journal.mjs',import.meta.url).href)};
const app=accountModel({proxyKey:'a'.repeat(64),journal:modelJournal(${JSON.stringify(dir)}),store:{claimModel:async()=> 'claimed',settleModel:async()=>{}},fetchImpl:async()=>{process.send('dispatched');return new Promise(()=>{});}});
app(${JSON.stringify(user)},${JSON.stringify(input)}).catch(()=>process.exit(2));`;
 const child=spawn(process.execPath,['--input-type=module','-e',script],{stdio:['ignore','ignore','ignore','ipc']});
 t.after(()=>{if(child.exitCode===null)child.kill('SIGKILL');});
 const notified=once(child,'message');await notified;
 const stopped=once(child,'exit');child.kill('SIGKILL');await stopped;
 const charges=[],results=[];
 await modelJournal(dir).recover(async(...args)=>charges.push(args),async(...args)=>results.push(args));
 assert.deepEqual(charges,[[user,request,true]]);assert.deepEqual(results,[]);
 assert.deepEqual(await readdir(dir),[]);
});
