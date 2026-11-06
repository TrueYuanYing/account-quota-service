// Server-only protocol boundary; no endpoint or membership grant is enabled here.
import { createHash, timingSafeEqual } from 'node:crypto';

function parameters(input) {
  if (!(input instanceof URLSearchParams) || input.toString().length > 16384) {
    throw new Error('invalid_payment_parameters');
  }
  const values = new Map();
  for (const [key, value] of input) {
    if (!/^[a-z][a-z0-9_]{0,63}$/.test(key) || value.length > 4096 || values.has(key)) {
      throw new Error('invalid_payment_parameters');
    }
    values.set(key, value);
  }
  return values;
}

export function signZpay(input, secret) {
  if (typeof secret !== 'string' || secret.length < 16 || secret.length > 512 || /\s/.test(secret)) {
    throw new Error('invalid_payment_secret');
  }
  const values = parameters(input);
  const canonical = [...values.keys()].sort()
    .filter(key => key !== 'sign' && key !== 'sign_type' && values.get(key) !== '')
    .map(key => `${key}=${values.get(key)}`).join('&');
  // Required by this provider's protocol; it is not a password/JWT hashing scheme.
  return createHash('md5').update(canonical + secret, 'utf8').digest('hex');
}

function cents(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,8})(\.[0-9]{1,2})?$/.test(value)) {
    throw new Error('invalid_payment_amount');
  }
  const [whole, fraction = ''] = value.split('.');
  const result = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  if (result <= 0) throw new Error('invalid_payment_amount');
  return result;
}

function validOrder(order) {
  if (!order || typeof order.merchantId !== 'string' ||
      !/^[A-Za-z0-9]{1,64}$/.test(order.merchantId) ||
      typeof order.orderId !== 'string' || !/^[0-9]{1,32}$/.test(order.orderId) ||
      !Number.isSafeInteger(order.amountCents) || order.amountCents <= 0) {
    throw new Error('invalid_server_order');
  }
}

/** expected must come from the server's existing order, never from the callback/client. */
export function verifyZpayNotification(input, expected, secret) {
  validOrder(expected);
  const values = parameters(input), signature = values.get('sign') ?? '';
  if (values.get('sign_type') !== 'MD5' || !/^[a-fA-F0-9]{32}$/.test(signature) ||
      !timingSafeEqual(Buffer.from(signature, 'hex'), Buffer.from(signZpay(input, secret), 'hex'))) {
    throw new Error('invalid_payment_signature');
  }
  const tradeNo = values.get('trade_no') ?? '';
  if (values.get('pid') !== expected.merchantId || values.get('out_trade_no') !== expected.orderId ||
      values.get('type') !== 'alipay' || values.get('trade_status') !== 'TRADE_SUCCESS' ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(tradeNo) || cents(values.get('money')) !== expected.amountCents) {
    throw new Error('payment_order_mismatch');
  }
  return Object.freeze({ orderId: expected.orderId, tradeNo,
    amountCents: expected.amountCents, paymentType: 'alipay' });
}

/** query must be fetched server-to-server, not supplied by a browser or mobile client. */
export function verifyZpayOrderQuery(query, claim, expected) {
  validOrder(expected);
  const merchantId = typeof query?.pid === 'number' && Number.isSafeInteger(query.pid)
    ? String(query.pid) : query?.pid;
  if (!claim || claim.orderId !== expected.orderId || claim.amountCents !== expected.amountCents ||
      claim.paymentType !== 'alipay' || typeof claim.tradeNo !== 'string' ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(claim.tradeNo) ||
      ![1, '1'].includes(query?.code) || ![1, '1'].includes(query?.status) ||
      merchantId !== expected.merchantId || query.out_trade_no !== expected.orderId ||
      query.trade_no !== claim.tradeNo || query.type !== 'alipay' ||
      cents(query.money) !== expected.amountCents) {
    throw new Error('payment_query_mismatch');
  }
  return Object.freeze({ orderId: expected.orderId, tradeNo: claim.tradeNo,
    amountCents: expected.amountCents, paymentType: 'alipay' });
}
