import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {once} from 'node:events';
import {capacityGuard} from './capacity.mjs';
async function fixture(t,guard,handler){
 const server=http.createServer(guard.wrap(handler));server.listen(0,'127.0.0.1');await once(server,'listening');
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);}));
 return 'http://127.0.0.1:'+server.address().port;
}
test('disk reserve rejects new costly writes without touching quotas; paid notification and reads remain available',async t=>{
 let calls=0;
 const guard=capacityGuard({readDisk:async()=>({bavail:1,bsize:4096}),readHost:async()=>'{"memoryTotalBytes":1}',rss:()=>1});
 const url=await fixture(t,guard,(req,res)=>{calls++;res.end('OK');});
 const failed=await fetch(url+'/v1/ai/complete',{method:'POST',body:'{}'});
 assert.equal(failed.status,503);assert.equal(failed.headers.get('retry-after'),'5');assert.equal(calls,0);
 assert.equal((await fetch(url+'/v1/payments/notify')).status,200);
 assert.equal((await fetch(url+'/v1/me')).status,200);
 assert.equal(calls,2);
});
test('global capacity bounds live requests and releases slots on completion',async t=>{
 let first,release;
 const started=new Promise(r=>first=r),blocked=new Promise(r=>release=r);
 const guard=capacityGuard({maxRequests:1});
 const url=await fixture(t,guard,async(req,res)=>{first();await blocked;res.end('OK');});
 const live=fetch(url+'/v1/me');await started;
 assert.equal((await fetch(url+'/v1/me')).status,503);
 assert.equal(guard.snapshot().activeRequests,1);
 release();assert.equal((await live).status,200);assert.equal(guard.snapshot().activeRequests,0);
});
