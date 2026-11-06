import {createHash} from 'node:crypto';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const ADMIN_STATUS=process.env.ADMIN_STATUS_URL || 'https://example.invalid/v1/license/status';

function reply(res,status,body) {
  res.writeHead(status,{'Content-Type':'application/json; charset=utf-8',
    'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
  res.end(JSON.stringify(body));
}
async function body(req) {
  if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']??''))return null;
  let length=0;const parts=[];
  for await(const part of req) {
    length+=part.length;if(length>16384)return null;parts.push(part);
  }
  try {const value=JSON.parse(Buffer.concat(parts).toString('utf8'));
    return value && !Array.isArray(value) && typeof value==='object'?value:null;
  }catch{return null;}
}
function onlyKeys(value,keys) {return value && Object.keys(value).every(key=>keys.includes(key));}
function text(value,max,min=3) {return typeof value==='string' && value.trim().length>=min
  && [...value].length<=max && !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value);}

/** Explicit submissions only; no generic input collection or SQL endpoint. */
export async function accountFeedback(req,res,{store,user}) {
  if(req.method==='GET')return reply(res,200,{rows:await store.feedback(user.id)});
  const value=await body(req);
  if(!onlyKeys(value,['requestId','category','orderId','message']) || !UUID.test(value.requestId??'')
    || !['product','order'].includes(value.category) || !text(value.message,4000)
    || (value.orderId!=null && !UUID.test(value.orderId))
    || (value.category==='order' && !value.orderId))return reply(res,400,{error:'invalid_feedback'});
  const submitted={requestId:value.requestId,category:value.category,orderId:value.orderId??null,message:value.message.trim()};
  const id=await store.submitFeedback(user.id,submitted);
  return reply(res,201,{id});
}

export async function accountAdministration(req,res,{store,fetchImpl,permissions=new Map(),payment=null,capacity=null,providers=null}) {
  const authorization=req.headers.authorization,device=req.headers['x-iko-device'];
  if(typeof authorization!=='string' || !/^Bearer [A-Za-z0-9_-]{40,128}$/.test(authorization)
    || typeof device!=='string' || !/^[a-f0-9]{64}$/.test(device))return reply(res,401,{error:'admin_required'});
  const actor=createHash('sha256').update(authorization+'\n'+device).digest('hex');
  const checkedAt=permissions.get(actor),now=Date.now();
  // Only permission is cached, never account data. Read-only revocation latency <=60s;
  // every mutation still checks the authority online before touching the ledger.
  if(req.method!=='GET' || checkedAt==null || now<checkedAt || now-checkedAt>=60000) {
    permissions.delete(actor);
    const verified=await fetchImpl(ADMIN_STATUS,{headers:{Authorization:authorization,'X-IKO-Device':device},
      signal:AbortSignal.timeout(5000),redirect:'error'});
    if([401,403].includes(verified.status))return reply(res,403,{error:'admin_required'});
    if(!verified.ok)return reply(res,503,{error:'admin_verification_unavailable'});
    const permission=await verified.json();
    if(permission.active!==true || permission.administrator!==true)return reply(res,403,{error:'admin_required'});
    if(permissions.size>=128)permissions.delete(permissions.keys().next().value);
    permissions.set(actor,Date.now());
  }
  const url=new URL(req.url,'http://iko.internal'),resource=url.pathname.slice('/v1/admin/'.length);
  if(resource==='providers' || resource.startsWith('providers/')) {
    if(!providers)return reply(res,503,{error:'providers_not_configured'});
    if(req.method==='GET' && resource==='providers')return reply(res,200,await providers.view());
    if(req.method==='POST' && ['providers/save','providers/priority','providers/balance','providers/refresh'].includes(resource)) {
      const value=await body(req);
      if(!value)return reply(res,400,{error:'invalid_provider'});
      if(capacity && !(await capacity.refresh()).writesAllowed)return reply(res,503,{error:'service_unavailable'});
      try {
        const method=resource.split('/')[1];
        return reply(res,200,await providers[method](value,actor));
      }catch(error){
        const allowed=['invalid_provider','revision_conflict','provider_not_found'];
        if(allowed.includes(error.message))return reply(res,error.message==='revision_conflict'?409:400,{error:error.message});
        return reply(res,503,{error:'provider_store_unavailable'});
      }
    }
    return reply(res,404,{error:'not_found'});
  }
  if(req.method==='GET' && ['overview','accounts','orders','feedback','audit','account','usage'].includes(resource)) {
    const page=url.searchParams.get('page')??'1',search=url.searchParams.get('search')??'';
    if(!/^[1-9][0-9]{0,5}$/.test(page) || search.length>120)return reply(res,400,{error:'invalid_query'});
    if(resource==='overview') {
      const [data,paymentData]=await Promise.all([store.adminOverview(),payment?.overview(),capacity?.refresh()]);
      return reply(res,200,{...data,payment:paymentData??{available:false,mode:'closed'},capacity:capacity?.snapshot()??null});
    }
    if(resource==='account') {
      const id=url.searchParams.get('id');if(!UUID.test(id??''))return reply(res,400,{error:'invalid_query'});
      const [document,identity]=await Promise.all([store.accountDocument(id),store.identity(id)]);
      return reply(res,200,{...document,...identity});
    }
    return reply(res,200,await store.adminQuery(resource,{page:Number(page),search}));
  }
  if(req.method==='POST' && resource==='grant') {
    const value=await body(req),quotas=value?.quotas;
    if(!onlyKeys(value,['requestId','userId','quotas','reason'])||!UUID.test(value.requestId??'')||!UUID.test(value.userId??'')||!text(value.reason,500)
      ||!quotas||typeof quotas!=='object'||Array.isArray(quotas)||!Object.keys(quotas).length
      ||Object.keys(quotas).some(k=>!['answer','correct','translate','summary'].includes(k))
      ||Object.values(quotas).some(v=>!Number.isSafeInteger(v)||v<0||v>100000)||!Object.values(quotas).some(v=>v>0))
      return reply(res,400,{error:'invalid_quota_grant'});
    if(capacity && !(await capacity.refresh()).writesAllowed)return reply(res,503,{error:'service_unavailable'});
    return reply(res,200,await store.adminAction(actor,'grant',value));
  }
  if(req.method==='POST' && ['revoke','feedback'].includes(resource)) {
    const value=await body(req);
    const allowed=resource==='revoke'?['requestId','orderId','reason']:['requestId','feedbackId','state','reason'];
    if(!onlyKeys(value,allowed) || !UUID.test(value.requestId??'') || !text(value.reason,500)
      || (resource==='revoke'?!UUID.test(value.orderId??'')
        :!UUID.test(value.feedbackId??'') || !['open','processing','resolved'].includes(value.state)))
      return reply(res,400,{error:'invalid_admin_action'});
    return reply(res,200,await store.adminAction(actor,resource,value));
  }
  return reply(res,404,{error:'not_found'});
}
