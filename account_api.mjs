import {accountAdministration,accountFeedback} from './account_management.mjs';
import {accountIdentity} from './account_identity.mjs';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function reply(response, status, value) {
  response.writeHead(status, {'Content-Type':'application/json; charset=utf-8',
    'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff'});
  response.end(JSON.stringify(value));
}

function page(response,status,text,type='text/html; charset=utf-8') {
  response.writeHead(status,{'Content-Type':type,'Cache-Control':'no-store','Referrer-Policy':'no-referrer',
    'X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; img-src https://example.invalid; style-src 'unsafe-inline'; form-action https://zpayz.cn https://api.z-pay.cn; frame-ancestors 'none'; base-uri 'none'"});
  response.end(text);
}

async function readProfile(request) {
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] ?? '')) return null;
  const chunks=[]; let length=0;
  for await (const chunk of request) {
    length+=chunk.length;
    if(length>4096) return null;
    chunks.push(chunk);
  }
  try {
    const body=JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if(!body || Array.isArray(body) || Object.keys(body).length!==1
        || typeof body.displayName!=='string')return null;
    const name=body.displayName.trim();
    return name.length>0 && [...name].length<=40 && !/[\u0000-\u001f\u007f-\u009f]/.test(name) ? name : null;
  }catch{return null;}
}

/** Explicit authenticated account operations; never generic input collection. */
export function createAccountApi({authUrl, store, model=null, payment=null, capacity=null, providers=null, providerGateway=null, fetchImpl=fetch}) {
  const adminPermissions=new Map();
  const auth=new URL(authUrl);
  if(auth.username || auth.password || auth.search || auth.hash
      || !['https:','http:'].includes(auth.protocol))throw new Error('invalid_auth_endpoint');
  // HTTP is allowed only for the private Compose service or local verification.
  if(auth.protocol==='http:' && !['auth','127.0.0.1','localhost'].includes(auth.hostname))
    throw new Error('private_auth_endpoint_required');
  const userUrl=new URL('user',auth.href.replace(/\/?$/,'/')).href;
  return async (request,response)=>{
    try {
      const path=new URL(request.url,'http://iko.internal').pathname;
      const length=request.headers['content-length'];
      if(length!=null && (!/^\d+$/.test(length) || Number(length)>96000))return reply(response,413,{error:'body_too_large'});
      if(path==='/health' && request.method==='GET')
        return reply(response,200,{service:'iko-account-api',checkoutEnabled:payment?.enabled===true,trialEnabled:payment?.trialEnabled===true});
      if(path==='/v1/internal/provider-complete' && request.method==='POST' && providerGateway)
        return await providerGateway.internal(request,response);
      const catalog=path==='/v1/products' && request.method==='GET';
      if(catalog && !request.headers.authorization)
        return reply(response,200,{products:(await store.products()).filter(p=>p.id!=='trial_001'),checkoutEnabled:payment?.enabled===true});
      if(path.startsWith('/v1/admin/'))return await accountAdministration(request,response,{store,fetchImpl,permissions:adminPermissions,payment,capacity,providers});
      if(path.startsWith('/v1/payments/')) {
        if(!payment)return reply(response,503,{error:'payments_not_configured'});
        if(request.method!=='GET')return reply(response,405,{error:'method_not_allowed'});
        if(path==='/v1/payments/return')return page(response,200,'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IKO · 支付结果</title><body style="font-family:system-ui;padding:28px;line-height:1.8"><h1>请返回 IKO 查看额度</h1><p>系统会向支付平台确认到账。此页面不代表充值已经成功，请回到账号额度页刷新订单。</p></body></html>');
        try {
          const parameters=new URL(request.url,'http://iko.internal').searchParams;
          if(path==='/v1/payments/notify') {
            await payment.notify(parameters);
            return page(response,200,'success','text/plain; charset=utf-8');
          }
          if(path==='/v1/payments/checkout')return page(response,200,await payment.form(parameters));
          return reply(response,404,{error:'not_found'});
        }catch{return reply(response,400,{error:'payment_not_confirmed'});}
      }
      const valid=catalog || (path==='/v1/me' && request.method==='GET')
          || (path==='/v1/ai/complete' && request.method==='POST')
          || (/^\/v1\/orders\/[a-f0-9-]{36}$/.test(path) && request.method==='GET')
          || (path==='/v1/me/profile' && ['GET','PATCH'].includes(request.method))
          || (path==='/v1/me/avatar' && request.method==='PUT')
          || (path==='/v1/notifications' && request.method==='GET')
          || (path==='/v1/notifications/read' && request.method==='POST')
          || (path==='/v1/feedback' && ['GET','POST'].includes(request.method))
          || (path==='/v1/orders' && request.method==='POST');
      if(!valid)return reply(response,404,{error:'not_found'});
      const authorization=request.headers.authorization;
      if(typeof authorization!=='string' || !/^Bearer [A-Za-z0-9._~-]{20,8192}$/.test(authorization))
        return reply(response,401,{error:'sign_in_required'});
      const verified=await fetchImpl(userUrl,{headers:{Authorization:authorization},
        signal:AbortSignal.timeout(5000),redirect:'error'});
      if(verified.status===401 || verified.status===403)return reply(response,401,{error:'session_expired'});
      if(!verified.ok)return reply(response,503,{error:'authentication_unavailable'});
      const user=await verified.json();
      if(!UUID.test(user.id??'') || user.role!=='authenticated'
          || !user.email_confirmed_at || typeof user.email!=='string')
        return reply(response,401,{error:'verified_account_required'});
      if(path.startsWith('/v1/notifications')||path==='/v1/me/avatar'||path==='/v1/me/profile'&&request.method==='GET')
        return await accountIdentity(request,response,{store,user,reply,path,capacity});
      if(catalog) {
        const products=(await store.products()).filter(p=>p.id!=='trial_001' || payment?.canPurchase(user.id,p.id));
        return reply(response,200,{products:products.map(p=>({...p,purchasable:payment?.canPurchase(user.id,p.id)===true})),
          checkoutEnabled:products.some(p=>payment?.canPurchase(user.id,p.id)===true)});
      }
      if(path==='/v1/ai/complete') {
        if(!model)return reply(response,503,{detail:'model_not_configured'});
        if(!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type']??''))return reply(response,400,{detail:'invalid_model_request'});
        const chunks=[];let size=0;
        for await(const chunk of request){size+=chunk.length;if(size>96000)return reply(response,413,{detail:'body_too_large'});chunks.push(chunk);}
        let input;try{input=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{return reply(response,400,{detail:'invalid_model_request'});}
        try {
          const result=await model(user.id,input);
          return reply(response,result.status,result.status===200?{text:result.text}:{detail:result.error});
        }catch(error) {
          if(error.message==='invalid_model_request')return reply(response,400,{detail:'invalid_model_request'});
          if(error.message==='quota_unavailable')return reply(response,402,{detail:'feature_quota_exhausted'});
          throw error;
        }
      }
      if(path==='/v1/orders' || path.startsWith('/v1/orders/')) {
        if(!payment)return reply(response,503,{error:'payments_not_configured'});
        try {
          if(request.method==='GET')return reply(response,200,await payment.reconcile(user.id,path.split('/').at(-1)));
          if(!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type']??''))return reply(response,400,{error:'invalid_order'});
          const chunks=[];let size=0;
          for await(const chunk of request){size+=chunk.length;if(size>4096)return reply(response,413,{error:'invalid_order'});chunks.push(chunk);}
          let input;try{input=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{return reply(response,400,{error:'invalid_order'});}
          return reply(response,201,await payment.create(user.id,input));
        }catch(error) {
          if(error.code)throw error;
          return reply(response,400,{error:'order_not_confirmed'});
        }
      }
      if(path==='/v1/feedback')return await accountFeedback(request,response,{store,user});
      if(path==='/v1/me/profile') {
        const name=await readProfile(request);
        if(name===null)return reply(response,400,{error:'invalid_profile'});
        await store.saveProfile(user.id,name);
      }
      const document=await store.accountDocument(user.id);
      return reply(response,200,{account:{id:user.id,email:user.email},...document});
    }catch (error) {
      // Never log tokens, body text, SMTP/database URLs or raw upstream errors.
      const status=error?.code==='22023'?400:error?.code==='54000'?429:error?.code==='55000'?409:503;
      const detail=error?.message==='requests_in_flight'?'requests_in_flight':status===400?'invalid_request':status===429?'rate_limited':status===409?'operation_conflict':'service_unavailable';
      if(!response.headersSent)reply(response,status,{error:detail});
      else response.end();
    }
  };
}
