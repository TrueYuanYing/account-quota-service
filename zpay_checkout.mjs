import {createHmac,timingSafeEqual} from 'node:crypto';
import {signZpay,verifyZpayNotification,verifyZpayOrderQuery} from './zpay_protocol.mjs';
const BASE=process.env.PUBLIC_ACCOUNT_URL || 'https://example.invalid';
if(new URL(BASE).protocol!=='https:')throw new Error('https_checkout_base_required');
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const html=value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

export function zpayCheckout({enabled=false,trialUser=null,pid,cid,key,linkKey,store,fetchImpl=fetch,now=()=>Date.now()}) {
  if(trialUser && !UUID.test(trialUser))throw new Error('invalid_trial_user');
  if(!enabled && !trialUser && ![pid,cid,key,linkKey].some(Boolean))return null;
  if(!/^[A-Za-z0-9]{1,64}$/.test(pid??'') || !/^[0-9]{1,20}$/.test(cid??'')
    || !/^[A-Za-z0-9_-]{16,512}$/.test(key??'') || !/^[a-f0-9]{64}$/.test(linkKey??''))throw new Error('invalid_payment_configuration');
  const signature=(id,expires)=>createHmac('sha256',linkKey).update(`iko-checkout-v1\n${id}\n${expires}`).digest('hex');
  const expected=order=>({merchantId:pid,orderId:order.out_trade_no,amountCents:order.price_cents});
  const canPurchase=(user,product)=>product==='trial_001'
    ? trialUser!==null && user===trialUser : enabled && ['topup_599','topup_999','topup_2999'].includes(product);
  const permitted=order=>canPurchase(order.user_id,order.product_id);
  // The purchase switch stops new payments, not settlement of existing orders.
  const knownOrder=order=>order && ['topup_599','topup_999','topup_2999','trial_001'].includes(order.product_id);
  let balanceSnapshot=null;
  const mode=enabled?'open':trialUser?'owner_trial':'closed';
  async function query(order) {
    const url=new URL('https://zpayz.cn/api.php');
    url.search=new URLSearchParams({act:order?'order':'balance',pid,key,...(order?{out_trade_no:order.out_trade_no}:{})}).toString();
    const response=await fetchImpl(url,{redirect:'error',signal:AbortSignal.timeout(10000)});
    if(!response.ok){await response.body?.cancel();throw new Error('payment_verification_unavailable');}
    const text=await response.text();
    if(text.length>16384)throw new Error('invalid_payment_query');
    return JSON.parse(text);
  }
  return {
    canPurchase,
    enabled,
    trialEnabled:!enabled && trialUser!==null,
    async overview() {
      if(balanceSnapshot && now()>=balanceSnapshot.checkedAt && now()-balanceSnapshot.checkedAt<60000)return balanceSnapshot;
      try {
        const result=await query(null);
        if(![1,'1'].includes(result.code) || !/^-?\d{1,9}(\.\d{1,2})?$/.test(String(result.balance)))throw new Error('invalid_balance');
        balanceSnapshot={available:true,mode,balanceYuan:Number(result.balance),checkedAt:now(),rechargeUrl:'https://member.z-pay.cn/member/'};
        return balanceSnapshot;
      } catch {
        return {available:false,mode,...(balanceSnapshot?{balanceYuan:balanceSnapshot.balanceYuan,checkedAt:balanceSnapshot.checkedAt}:{})};
      }
    },
    async create(user,input) {
      if(!input || Array.isArray(input) || Object.keys(input).some(k=>!['requestId','productId'].includes(k))
        || !UUID.test(input.requestId??'') || !canPurchase(user,input.productId))throw new Error('invalid_order');
      const order=await store.open(user,input.requestId,input.productId);
      if(order.state==='expired')return {id:order.id,state:'expired'};
      const expires=String(Math.floor(now()/1000)+900);
      return {id:order.id,checkoutUrl:`${BASE}/v1/payments/checkout?order=${order.id}&expires=${expires}&token=${signature(order.id,expires)}`};
    },
    async form(parameters) {
      if([...parameters.keys()].sort().join(',')!=='expires,order,token')throw new Error('invalid_checkout_link');
      const id=parameters.get('order'),expires=parameters.get('expires'),token=parameters.get('token');
      if(!UUID.test(id??'') || !/^[0-9]{1,12}$/.test(expires??'') || !/^[a-f0-9]{64}$/.test(token??'')
        || Number(expires)<Math.floor(now()/1000) || Number(expires)>Math.floor(now()/1000)+900
        || !timingSafeEqual(Buffer.from(token),Buffer.from(signature(id,expires))))throw new Error('invalid_checkout_link');
      const order=await store.find(id);
      if(knownOrder(order)&&order.state==='expired')return '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IKO · 订单已关闭</title><body><main><h1>订单已关闭</h1><p>此订单超过15分钟未付款，请返回 IKO 重新购买。如已经付款，可返回账户核对到账或提交订单反馈，原记录仍保留。</p></main></body></html>';
      if(knownOrder(order) && order.state==='paid')return `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IKO · 订单已支付</title><body style="margin:0;background:#f3f2ee;color:#20211f;font:16px/1.8 system-ui;padding:28px"><main style="max-width:520px;margin:8vh auto"><img src="https://example.invalid/_mail/iko-light.png" alt="IKO" width="72" height="72"><h1>此订单已完成付款</h1><p>请返回 IKO 查看账户额度及订单状态，无需重复支付。</p><p style="overflow-wrap:anywhere">订单号 ${html(order.out_trade_no)}</p></main></body></html>`;
      if(!order || order.state!=='pending' || !permitted(order))throw new Error('order_not_pending');
      const params=new URLSearchParams({pid,cid,type:'alipay',out_trade_no:order.out_trade_no,
        name:order.name,money:(order.price_cents/100).toFixed(2),notify_url:BASE+'/v1/payments/notify',return_url:BASE+'/v1/payments/return'});
      params.set('sign',signZpay(params,key));params.set('sign_type','MD5');
      const labels={answer:'答题',correct:'云端纠错',translate:'翻译',summary:'课堂摘要'};
      return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IKO · 确认充值</title><style>
*{box-sizing:border-box}body{margin:0;background:#f3f2ee;color:#20211f;font:16px/1.7 system-ui,sans-serif}main{max-width:580px;margin:28px auto;padding:24px}header{display:flex;align-items:center;gap:14px;margin-bottom:32px}header img{width:64px;height:64px;border-radius:16px;background:#fff}header strong{font-size:25px;letter-spacing:2px}header span{display:block;color:#666d68;font-size:14px}h1{font-size:25px;line-height:1.3;margin:0 0 8px}.price{font-size:46px;font-weight:650;letter-spacing:-1px;margin:0 0 20px;font-variant-numeric:tabular-nums}.panel{background:#fff;border:1px solid #e4e3dd;border-radius:20px;padding:24px}.quotas{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin:0 0 24px}.quotas dt{color:#636961;font-size:14px}.quotas dd{margin:2px 0 0;font-size:25px;font-weight:600}p{margin:10px 0}.note{color:#60655f;font-size:14px}.order{overflow-wrap:anywhere;font-size:13px;color:#71766f;border-top:1px solid #e8e7e1;padding-top:16px;margin-top:20px}.review{display:flex;gap:10px;align-items:flex-start;margin:22px 0 16px;font-size:14px}.review input{margin:4px 0 0;width:20px;height:20px;flex-shrink:0;accent-color:#232621}button{width:100%;padding:15px 12px;border:0;border-radius:14px;background:#242721;color:#fff;font:600 17px/1.5 system-ui;cursor:pointer}button:focus-visible,input:focus-visible{outline:3px solid #487bff;outline-offset:3px}.channel{color:#1677ff;font-size:14px;margin-top:14px;text-align:center}footer{padding:18px 4px;font-size:13px;color:#6b7068}@media(max-width:380px){main{padding:16px;margin:12px auto}.panel{padding:20px}.price{font-size:40px}}
</style></head><body><main><header><img src="https://example.invalid/_mail/iko-light.png" alt="IKO"><div><strong>IKO</strong><span>确认你的云端额度</span></div></header><section class="panel"><h1>${html(order.name)}</h1><p class="price">¥${(order.price_cents/100).toFixed(2)}</p><dl class="quotas">${Object.entries(labels).map(([kind,label])=>`<div><dt>${label}</dt><dd>${html(order.quotas?.[kind]??0)}<small> 次</small></dd></div>`).join('')}</dl>
<p>充值账号：${html(order.account_label??'账号尾号 '+String(order.user_id).slice(-8))}</p><p class="note">额度归入创建此订单时登录的 IKO 账号。无日历到期；同档、跨档可重复购买，额度累加。每次请求发送云端模型处理后计1次，超时、中断或未得到有效回答也计次；未通过登录、额度或繁忙校验的请求不扣。手动重新生成属于一次新请求。长课堂摘要包含分段与合并请求，各自计次。</p>
<form method="post" action="https://zpayz.cn/submit.php">${[...params].map(([k,v])=>`<input type="hidden" name="${html(k)}" value="${html(v)}">`).join('')}<label class="review"><input type="checkbox" required><span>我已核对金额、额度与计量说明。</span></label><button>¥${(order.price_cents/100).toFixed(2)} · 前往支付宝付款</button><p class="channel">支付宝 H5 · 确认后跳转支付收银台</p></form><p class="order">订单号 ${html(order.out_trade_no)}</p></section><footer>付款后返回 IKO 刷新账户额度；如未到账，可在最近订单中核对，或提交“订单反馈”由管理员处理。此页面本身不代表付款成功。</footer></main></body></html>`;
    },
    async notify(parameters) {
      const no=parameters.get('out_trade_no');
      if(!/^[0-9]{1,32}$/.test(no??''))throw new Error('invalid_payment_parameters');
      const order=await store.findByNumber(no);
      if(!knownOrder(order))throw new Error('unknown_order');
      const claim=verifyZpayNotification(parameters,expected(order),key);
      verifyZpayOrderQuery(await query(order),claim,expected(order));
      await store.grant(order.id,claim.tradeNo,claim.amountCents);
    },
    async reconcile(user,id) {
      if(!UUID.test(id??''))throw new Error('invalid_order');
      const order=await store.find(id);
      if(!knownOrder(order) || order.user_id!==user)throw new Error('unknown_order');
      if(!['pending','expired'].includes(order.state))return {id,state:order.state};
      const answer=await query(order);
      if([1,'1'].includes(answer.code) && [0,'0'].includes(answer.status))return {id,state:order.state};
      const claim={orderId:order.out_trade_no,amountCents:order.price_cents,paymentType:'alipay',tradeNo:answer.trade_no};
      verifyZpayOrderQuery(answer,claim,expected(order));
      await store.grant(id,claim.tradeNo,claim.amountCents);
      return {id,state:'paid'};
    },
  };
}
