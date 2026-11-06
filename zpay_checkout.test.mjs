import {test} from 'node:test';
import assert from 'node:assert/strict';
import {zpayCheckout} from './zpay_checkout.mjs';
import {signZpay} from './zpay_protocol.mjs';
const id='00000000-0000-0000-0000-000000000068',user='account68',key='synthetic-not-a-merchant-key';
const order={id,user_id:user,account_label:'te***71@example.invalid',product_id:'topup_599',out_trade_no:'20261027000000068',price_cents:599,state:'pending',name:'5.99元额度包',quotas:{answer:150,correct:400,translate:150,summary:25}};
function setup({query={},state='pending'}={}){
  const granted=[],row={...order,state};let opened;
  const app=zpayCheckout({enabled:true,pid:'merchant68',cid:'123',key,linkKey:'a'.repeat(64),now:()=>1793100000000,
    store:{open:async(...args)=>{opened=args;return row;},find:async()=>row,findByNumber:async()=>row,grant:async(...args)=>granted.push(args)},
    fetchImpl:async url=>{assert.equal(url.hostname,'zpayz.cn');return Response.json({code:1,status:1,pid:'merchant68',
      out_trade_no:row.out_trade_no,trade_no:'trade68',money:'5.99',type:'alipay',...query});}});
  const notification=()=>{
    const params=new URLSearchParams({pid:'merchant68',out_trade_no:row.out_trade_no,trade_no:'trade68',money:'5.99',type:'alipay',trade_status:'TRADE_SUCCESS'});
    params.set('sign',signZpay(params,key));params.set('sign_type','MD5');return params;
  };
  return {app,granted,notification,get opened(){return opened;}};
}
test('expired checkout has no pay form, retains history and reconciles a verified late payment',async()=>{
 const {app,granted,notification}=setup({state:'expired'});
 const created=await app.create(user,{requestId:id,productId:'topup_599'});
 assert.deepEqual(created,{id,state:'expired'});
 const normal=await setup().app.create(user,{requestId:id,productId:'topup_599'});
 const closed=await app.form(new URL(normal.checkoutUrl).searchParams);
 assert.match(closed,/订单已关闭/);assert.ok(!closed.includes('<form'));
 await app.notify(notification());assert.deepEqual(granted,[[id,'trade68',599]]);
 assert.deepEqual(await app.reconcile(user,id),{id,state:'paid'});
});
test('unpaid expired order stays closed and grants no quota',async()=>{
 const {app,granted}=setup({state:'expired',query:{status:0}});
 assert.deepEqual(await app.reconcile(user,id),{id,state:'expired'});assert.deepEqual(granted,[]);
});
test('signed notification must pass independent server query before any grant',async()=>{
  const {app,granted,notification}=setup();await app.notify(notification());
  assert.deepEqual(granted,[[id,'trade68',599]]);
});
test('wrong signature, query amount or status never grants',async()=>{
  for(const query of [{money:'9.99'},{status:0},{pid:'other'}]){
    const {app,granted,notification}=setup({query});await assert.rejects(()=>app.notify(notification()));assert.deepEqual(granted,[]);
  }
  const {app,granted,notification}=setup();const forged=notification();forged.set('sign','0'.repeat(32));
  await assert.rejects(()=>app.notify(forged));assert.deepEqual(granted,[]);
});
test('checkout links are short-lived, fixed-amount and contain no merchant secret',async()=>{
  const {app}=setup();const result=await app.create(user,{requestId:id,productId:'topup_599'});
  assert.ok(!result.checkoutUrl.includes(key));const parameters=new URL(result.checkoutUrl).searchParams;
  const form=await app.form(parameters);assert.match(form,/https:\/\/zpayz.cn\/submit.php/);
  assert.ok(!form.includes(key));assert.match(form,/value="5\.99"/);
  parameters.set('expires','1');await assert.rejects(()=>app.form(parameters));
  await assert.rejects(()=>app.create(user,{requestId:id,productId:'topup_599',money:1}));
});
test('client reconcile checks order owner and independent query; disabled config cannot create checkout',async()=>{
  assert.equal(zpayCheckout({enabled:false}),null);const {app,granted}=setup();
  await assert.rejects(()=>app.reconcile('other-account',id));assert.deepEqual(granted,[]);
  assert.deepEqual(await app.reconcile(user,id),{id,state:'paid'});
  assert.deepEqual(granted,[[id,'trade68',599]]);
});

test('closing new purchases does not strand an already paid order notification or its owner reconciliation',async()=>{
  const granted=[];
  const app=zpayCheckout({enabled:false,pid:'merchant68',cid:'123',key,linkKey:'a'.repeat(64),
    store:{find:async()=>order,findByNumber:async()=>order,grant:async(...args)=>granted.push(args)},
    fetchImpl:async()=>Response.json({code:1,status:1,pid:'merchant68',out_trade_no:order.out_trade_no,
      trade_no:'trade68',money:'5.99',type:'alipay'})});
  assert.ok(app,'configured settlement service must survive a closed purchase switch');
  assert.equal(app.canPurchase(user,'topup_599'),false);
  await assert.rejects(()=>app.create(user,{requestId:id,productId:'topup_599'}));
  const params=new URLSearchParams({pid:'merchant68',out_trade_no:order.out_trade_no,trade_no:'trade68',
    money:'5.99',type:'alipay',trade_status:'TRADE_SUCCESS'});
  params.set('sign',signZpay(params,key));params.set('sign_type','MD5');
  await app.notify(params);
  assert.deepEqual(await app.reconcile(user,id),{id,state:'paid'});
  assert.equal(granted.length,2,'store grant is idempotent for the same order and payment identity');
  await assert.rejects(()=>app.reconcile('other-account',id));
});

test('checkout states all four purchased quantities and requires an explicit review before the provider form submits',async()=>{
  const {app}=setup();const created=await app.create(user,{requestId:id,productId:'topup_599'});
  const form=await app.form(new URL(created.checkoutUrl).searchParams);
  for(const label of ['答题','云端纠错','翻译','课堂摘要','150','400','25','无日历到期','订单反馈'])assert.ok(form.includes(label),label);
  assert.match(form,/<input[^>]*type="checkbox"[^>]*required/);
  assert.match(form,/https:\/\/example\.invalid\/_mail\/iko-light\.png/);
  assert.ok(!form.includes(key));
});

test('reopening a paid checkout displays its payment status without a second payment form',async()=>{
  const {app}=setup({state:'paid'});
  const created=await app.create(user,{requestId:id,productId:'topup_599'});
  const page=await app.form(new URL(created.checkoutUrl).searchParams);
  assert.match(page,/此订单已完成付款/);
  assert.ok(!page.includes('<form'));
  assert.ok(page.includes(order.out_trade_no));
});

test('payer can identify the server-bound account before paying and cannot replace it in the order request',async()=>{
  const {app}=setup();const result=await app.create(user,{requestId:id,productId:'topup_599'});
  const form=await app.form(new URL(result.checkoutUrl).searchParams);
  assert.ok(form.includes(order.account_label));
  await assert.rejects(()=>app.create(user,{requestId:id,productId:'topup_599',account_label:'someone-else'}));
});
