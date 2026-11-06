import {createHash} from 'node:crypto';

const FEATURES=new Set(['answer','correct','translate','summary']);
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

export function validateModelInput(body) {
  if(!body || Array.isArray(body) || Object.keys(body).some(key=>!['feature','messages','requestId'].includes(key))
    || !FEATURES.has(body.feature) || !UUID.test(body.requestId??'') || !Array.isArray(body.messages)
    || body.messages.length<1 || body.messages.length>8)throw new Error('invalid_model_request');
  let count=0;
  for(const message of body.messages) {
    if(!message || Array.isArray(message) || Object.keys(message).some(key=>!['role','content'].includes(key))
      || !['system','user','assistant'].includes(message.role) || typeof message.content!=='string'
      || !message.content.length || message.content.length>16000)throw new Error('invalid_model_request');
    count+=message.content.length;
  }
  if(count>32000 || !body.messages.some(message=>message.role==='user'))throw new Error('invalid_model_request');
  return body;
}

/** Claim once, then settle only a known terminal result. No elapsed-time refunds. */
export function accountModel({store, proxyKey, journal=null, fetchImpl=fetch}) {
  if(!/^[a-f0-9]{64}$/.test(proxyKey??''))return null;
  let inFlight=0;
  const accounts=new Map();
  return async (user, input)=>{
    validateModelInput(input);
    if(inFlight>=8 || (accounts.get(user)??0)>=2)return {status:503,error:'ai_service_busy'};
    inFlight++;
    accounts.set(user,(accounts.get(user)??0)+1);
    try {
      const payload={feature:input.feature,messages:input.messages};
      const digest=createHash('sha256').update(JSON.stringify(payload)).digest('hex');
      if(journal && !await journal.start(user,input.requestId))return {status:409,error:'ai_request_already_submitted'};
      let state;
      try {state=await store.claimModel(user,input.requestId,input.feature,digest);}
      catch(error){
        // A connection failure can hide a committed claim. Keep the journal for
        // restart recovery; deterministic rejections are safe to remove now.
        if(['22023','P0001'].includes(error.code))await journal?.remove(user,input.requestId);
        throw error;
      }
      if(state!=='claimed') {
        await journal?.remove(user,input.requestId);
        return {status:409,error:state==='completed'?'ai_request_completed':'ai_request_already_submitted'};
      }
      async function settle(success,charge=true) {
        // After a relay attempt, timeout/invalid output also consumes one call.
        // The validity of the answer is a separate auditable outcome.
        await journal?.terminal(user,input.requestId,success,{charge});
        for(let attempt=0;;attempt++){
          try {
            await store.settleModel(user,input.requestId,charge);
            if(charge)await store.recordModelResult?.(user,input.requestId,success);
            break;
          }
          catch(error){if(attempt===2)throw error;await new Promise(resolve=>setTimeout(resolve,100*(attempt+1)));}
        }
        await journal?.remove(user,input.requestId);
      }
      // Durable acceptance before dispatch. A restart must not turn an
      // already attempted request into a free retry; unknown delivery stays unknown.
      await journal?.attempted(user,input.requestId);
      let valid=false, text, billable=true,preflightError='model_not_configured';
      try {
        const response=await fetchImpl(process.env.MODEL_RELAY_URL || 'https://example.invalid/v1/internal/complete',{
          method:'POST',redirect:'error',signal:AbortSignal.timeout(38000),
          headers:{'Content-Type':'application/json',Authorization:'Bearer '+proxyKey},body:JSON.stringify(payload)});
        if(!response.ok) {
          // These bounded, allowlisted relay errors prove it rejected the request
          // before a provider call. Other failures/timeouts remain billable attempts.
          if([400,401,403,413,422,503].includes(response.status)) {
            let detail;
            const reader=response.body?.getReader();let size=0;const chunks=[];
            if(reader)try {
              while(true){const part=await reader.read();if(part.done)break;
                size+=part.value.length;if(size>4096)break;chunks.push(part.value);}
              if(size<=4096)detail=JSON.parse(Buffer.concat(chunks).toString('utf8')).detail;
            }catch{/* A malformed/unknown response cannot prove a preflight rejection. */}
            finally{await reader.cancel().catch(()=>{});}
            if(['service_required','upstream_not_configured','invalid_request','invalid_text','body_too_large','ai_service_busy'].includes(detail)) {
              billable=false;
              if(detail==='ai_service_busy')preflightError='ai_service_busy';
              throw new Error('model_not_configured');
            }
          }else await response.body?.cancel();
          throw new Error('upstream_unavailable');
        }
        const reader=response.body.getReader();let length=0;const chunks=[];
        try {while(true){const part=await reader.read();if(part.done)break;
          length+=part.value.length;if(length>250000)throw new Error('upstream_unavailable');chunks.push(part.value);}}
        finally {await reader.cancel().catch(()=>{});}
        text=JSON.parse(Buffer.concat(chunks).toString('utf8')).text;
        if(typeof text!=='string' || !text.trim() || text.length>250000)throw new Error('upstream_unavailable');
        valid=true;
      } catch {
        // The attempt was sent to the trusted relay. No automatic retry here:
        // charge once, record failure, and report it explicitly to the client.
        await settle(false,billable);
        return billable?{status:502,error:'upstream_unavailable_charged'}:{status:503,error:preflightError};
      }
      if(valid)await settle(true);
      return {status:200,text:text.trim()};
    } finally {
      inFlight--;
      const remaining=accounts.get(user)-1;
      if(remaining)accounts.set(user,remaining);else accounts.delete(user);
    }
  };
}
