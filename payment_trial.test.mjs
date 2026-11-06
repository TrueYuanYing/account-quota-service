import {test} from 'node:test';
import assert from 'node:assert/strict';
import {zpayCheckout} from './zpay_checkout.mjs';
const owner='00000000-0000-0000-0000-000000000070';
const id='10000000-0000-0000-0000-000000000070';
test('one-cent trial permits only the server-approved owner and trial product',async()=>{
  let calls=0;
  const app=zpayCheckout({enabled:false,trialUser:owner,pid:'test70',cid:'123',key:'synthetic-payment-key',linkKey:'a'.repeat(64),
    store:{open:async()=>{calls++;return {id};}}});
  assert.ok(app);
  await assert.rejects(()=>app.create('someone-else',{requestId:id,productId:'trial_001'}));
  await assert.rejects(()=>app.create(owner,{requestId:id,productId:'topup_599'}));
  const result=await app.create(owner,{requestId:id,productId:'trial_001'});
  assert.match(result.checkoutUrl,/\/v1\/payments\/checkout/);
  assert.equal(calls,1);
  assert.equal(app.canPurchase('someone-else','trial_001'),false);
  assert.equal(app.canPurchase(owner,'trial_001'),true);
  assert.equal(app.canPurchase(owner,'topup_599'),false);
});
