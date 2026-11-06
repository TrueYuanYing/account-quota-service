import {test} from 'node:test';import assert from 'node:assert/strict';import {accountStore} from './account_store.mjs';
test('本人资料只增加密码是否已设置，不返回认证密文或密码',async()=>{
 let sql,params;const store=accountStore({query:async(statement,values)=>{sql=statement;params=values;return {rows:[{displayName:'同学',passwordSet:false,avatarBase64:null,unread:0}]};}});
 const result=await store.identity('owner');assert.equal(result.passwordSet,false);assert.deepEqual(params,['owner']);
 assert.match(sql,/u\.password_set AS "passwordSet"/);assert.doesNotMatch(sql,/encrypted_password|password_hash/);
 assert.equal(result.password,undefined);assert.equal(result.encrypted_password,undefined);
});
