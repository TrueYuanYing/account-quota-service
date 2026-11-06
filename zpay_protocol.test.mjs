import test from 'node:test';
import assert from 'node:assert/strict';
import { signZpay, verifyZpayNotification, verifyZpayOrderQuery } from './zpay_protocol.mjs';

const secret = 'fixture-key-only';
const order = Object.freeze({ merchantId: 'fixturemerchant', orderId: '20261026000001', amountCents: 500 });
function notification(overrides = {}) {
  const result = new URLSearchParams({ pid: order.merchantId, out_trade_no: order.orderId,
    trade_no: 'provider_order_001', type: 'alipay', money: '5.00',
    trade_status: 'TRADE_SUCCESS', sign_type: 'MD5', ...overrides });
  result.set('sign', signZpay(result, secret));
  return result;
}

test('ZPAY签名遵循未URL编码的UTF-8参数规则', () => {
  // Independent hashlib vector for the literal canonical string in the spec.
  assert.equal(signZpay(new URLSearchParams({
    type: 'alipay', pid: 'fixturemerchant', out_trade_no: '20261026000001',
    name: 'IKO 月度会员', money: '5.00', empty: '', sign: 'ignored', sign_type: 'MD5',
  }), 'fixture-key-only'), '4189c047ac870c9e42b3079f08fdd5b1');
});

test('有效的支付宝已付通知仅生成核对凭据，不从param决定权益用户', () => {
  assert.deepEqual(verifyZpayNotification(notification({ param: 'untrusted-other-user' }), order, secret), {
    orderId: order.orderId, tradeNo: 'provider_order_001', amountCents: 500, paymentType: 'alipay',
  });
});

test('服务端二次查单的商户、订单、交易号和金额必须与已验签通知一致', () => {
  const claim = verifyZpayNotification(notification(), order, secret);
  assert.deepEqual(verifyZpayOrderQuery({ code: 1, status: 1, pid: order.merchantId,
    out_trade_no: order.orderId, trade_no: 'provider_order_001', type: 'alipay', money: '5.00',
  }, claim, order), claim);
});

for (const [name, changes] of [
  ['金额不足', { money: '0.01' }], ['金额超出', { money: '9.99' }],
  ['其他商户', { pid: 'othermerchant' }], ['其他订单', { out_trade_no: '20261026999999' }],
  ['未支付', { trade_status: 'WAIT_BUYER_PAY' }], ['错误渠道', { type: 'wxpay' }],
  ['错误签名类型', { sign_type: 'RSA' }], ['空交易号', { trade_no: '' }],
]) {
  test(`拒绝虽有合法签名但不属于本订单的通知：${name}`, () => {
    assert.throws(() => verifyZpayNotification(notification(changes), order, secret));
  });
}

for (const money of ['NaN', 'Infinity', '5e0', '+5.00', '-5.00', '0', '01.00', '5.001', '5,00', ' 5.00', '5.00 ']) {
  test(`金额必须按十进制分精确匹配，拒绝 ${JSON.stringify(money)}`, () => {
    assert.throws(() => verifyZpayNotification(notification({ money }), order, secret));
  });
}

test('通知的金额被改后即使仍是合法金额也无法通过原签名', () => {
  const changed = notification(); changed.set('money', '9.99');
  assert.throws(() => verifyZpayNotification(changed, order, secret), /invalid_payment_signature/);
});

test('拒绝重复参数，避免代理与服务器对同一付款金额理解不同', () => {
  const duplicate = notification(); duplicate.append('money', '0.01');
  assert.throws(() => verifyZpayNotification(duplicate, order, secret), /invalid_payment_parameters/);
});

test('拒绝缺失、过长、非十六进制或空签名', () => {
  for (const signature of ['', 'a', 'g'.repeat(32), 'a'.repeat(64)]) {
    const input = notification(); input.set('sign', signature);
    assert.throws(() => verifyZpayNotification(input, order, secret), /invalid_payment_signature/);
  }
});

test('拒绝不合法参数体与空商户密钥', () => {
  assert.throws(() => signZpay({ pid: 'fixturemerchant' }, secret), /invalid_payment_parameters/);
  assert.throws(() => signZpay(notification(), ''), /invalid_payment_secret/);
  const large = notification(); large.set('param', 'x'.repeat(5000));
  assert.throws(() => verifyZpayNotification(large, order, secret), /invalid_payment_parameters/);
});

test('服务端配置或价格丢失时不能把订单当作免费已付订单', () => {
  for (const amountCents of [0, -1, 5.5, NaN, Infinity]) {
    assert.throws(() => verifyZpayNotification(notification(), { ...order, amountCents }, secret), /invalid_server_order/);
  }
});

const query = Object.freeze({ code: 1, status: 1, pid: order.merchantId,
  out_trade_no: order.orderId, trade_no: 'provider_order_001', type: 'alipay', money: '5.00' });
for (const [name, changes] of [
  ['查询失败', { code: 0 }], ['查询未支付', { status: 0 }], ['查询其他商户', { pid: 'othermerchant' }],
  ['查询其他订单', { out_trade_no: '20261026999999' }], ['查询交易号不同', { trade_no: 'other_provider_trade' }],
  ['查询金额不同', { money: '0.01' }], ['查询渠道不同', { type: 'wxpay' }],
]) {
  test(`通知与二次查单不一致必须拒绝：${name}`, () => {
    const claim = verifyZpayNotification(notification(), order, secret);
    assert.throws(() => verifyZpayOrderQuery({ ...query, ...changes }, claim, order));
  });
}

test('验证结果是不可变的，且不会回传回调里声明的用户或管理员身份', () => {
  const claim = verifyZpayNotification(notification({ param: '{"role":"admin","userId":"other-user"}' }), order, secret);
  assert.equal(Object.isFrozen(claim), true);
  assert.deepEqual(Object.keys(claim).sort(), ['amountCents', 'orderId', 'paymentType', 'tradeNo']);
});
