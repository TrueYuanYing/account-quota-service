import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {once} from 'node:events';
import {createAccountApi} from './account_api.mjs';
const user='00000000-0000-0000-0000-000000000187',id='00000000-0000-0000-0000-000000000188';
const authorization='Bearer '+'a'.repeat(48),device='b'.repeat(64);
async function setup(t,{admin=true,writable=true}={}) {
 const calls=[];const store={identity:async u=>{calls.push(['identity',u]);return {displayName:'同学',avatarBase64:null,unread:1};},
  notifications:async u=>{calls.push(['notifications',u]);return [{id,title:'额度已到账'}];},
  readNotifications:async(...args)=>calls.push(['read',...args]),saveAvatar:async(...args)=>calls.push(['avatar',...args]),
  adminAction:async(...args)=>{calls.push(['grant',...args]);return {changed:true};}};
 const server=http.createServer(createAccountApi({authUrl:'http://auth:9999/',store,
  capacity:{refresh:async()=>({writesAllowed:writable})},fetchImpl:async url=>Response.json(url.includes('license/status')?{active:true,administrator:admin}:
   {id:user,role:'authenticated',email:'sample@example.invalid',email_confirmed_at:'2026-10-30',user_metadata:{iko_password_set:true}})}));
 server.listen(0,'127.0.0.1');await once(server,'listening');t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 const call=(path,method='GET',data,adminHeaders=false)=>fetch(`http://127.0.0.1:${server.address().port}/v1/`+path,
  {method,headers:{authorization,'content-type':'application/json',...(adminHeaders?{'x-iko-device':device}:{})},...(data?{body:JSON.stringify(data)}:{})});
 return {call,calls};
}
test('资料和通知只从已验证账号读取，GET不自动已读',async t=>{
 const {call,calls}=await setup(t);const profile=await call('me/profile');assert.equal(profile.status,200);assert.equal((await profile.json()).passwordSet,true);
 assert.equal((await call('notifications')).status,200);assert.deepEqual(calls,[['identity',user],['notifications',user]]);
 assert.equal((await call('notifications/read','POST',{ids:[id]})).status,200);assert.deepEqual(calls.at(-1),['read',user,[id]]);
 assert.equal((await call('notifications/read','POST',{ids:[id],userId:'other'})).status,400);
 assert.equal((await call('notifications/read','POST',{all:true})).status,200);assert.deepEqual(calls.at(-1),['read',user,null]);
});
test('头像只接受显式小JPEG，拒绝SVG/超大数据/额外账号参数',async t=>{
 const {call,calls}=await setup(t);
 for(const payload of [{jpegBase64:'<svg/>'},{jpegBase64:'a'.repeat(45000)},{jpegBase64:null,userId:user}])
  assert.equal((await call('me/avatar','PUT',payload)).status,400);
 assert.equal((await call('me/avatar','PUT',{jpegBase64:null})).status,200);
 assert.deepEqual(calls.find(x=>x[0]==='avatar'),['avatar',user,null]);
});
test('空间保护拒绝新头像写入，已有资料仍可读',async t=>{
 const {call,calls}=await setup(t,{writable:false});assert.equal((await call('me/avatar','PUT',{jpegBase64:null})).status,503);
 const profile=await call('me/profile');assert.equal(profile.status,200);assert.equal((await profile.json()).passwordSet,true);assert.equal(calls.some(x=>x[0]==='avatar'),false);
});
test('管理员加量需服务端角色、范围校验及requestId，不允许指定来源订单',async t=>{
 const {call,calls}=await setup(t);const payload={requestId:id,userId:user,quotas:{answer:20,correct:0,translate:0,summary:0},reason:'测试赠送'};
 assert.equal((await call('admin/grant','POST',payload,true)).status,200);
 const action=calls.find(x=>x[0]==='grant');assert.equal(action[2],'grant');assert.equal(action[3].userId,user);assert.match(action[1],/^[a-f0-9]{64}$/);
 for(const changed of [{quotas:{answer:-1}},{quotas:{answer:1.5}},{quotas:{answer:100001}},{quotas:{other:1}},{sourceOrderId:id}])
  assert.equal((await call('admin/grant','POST',{...payload,...changed},true)).status,400);
 assert.equal((await call('admin/grant','POST',payload)).status,401);
 const denied=await setup(t,{admin:false});assert.equal((await denied.call('admin/grant','POST',payload,true)).status,403);
 assert.equal(denied.calls.length,0);
});
