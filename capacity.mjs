import {statfs,readFile} from 'node:fs/promises';

/** One small API replica: bounded work, no unbounded waiting queue. */
export function capacityGuard({maxRequests=32,minimumDiskBytes=2*1024**3,
  readDisk=()=>statfs('/var/lib/iko-model-journal'),
  readHost=()=>readFile('/var/lib/iko-host-metrics/snapshot.json','utf8'),
  rss=()=>process.memoryUsage().rss,now=()=>Date.now()}={}) {
  let active=0,last=null,reading=null;
  async function resources() {
    if(last && now()>=last.checkedAt && now()-last.checkedAt<5000)return last;
    if(reading)return reading;
    reading=(async()=>{
      try {
        const disk=await readDisk();let memoryFraction=0;
        try {
          const host=JSON.parse(await readHost());
          const sampled=Date.parse(host.sampledAt);
          if(Number.isFinite(sampled) && now()>=sampled && now()-sampled<180000 && host.memoryTotalBytes>0)
            memoryFraction=host.memoryUsedBytes/host.memoryTotalBytes;
        }catch{/* Missing host telemetry never fabricates a low-memory state. */}
        const freeBytes=Number(disk.bavail)*Number(disk.bsize);
        last={checkedAt:now(),available:true,freeBytes,
          writesAllowed:Number.isFinite(freeBytes) && freeBytes>=minimumDiskBytes && memoryFraction<.94 && rss()<160*1024**2};
      }catch{last={checkedAt:now(),available:false,writesAllowed:false};}
      return last;
    })().finally(()=>{reading=null;});
    return reading;
  }
  const snapshot=()=>({activeRequests:active,maxRequests,minimumDiskBytes,...last});
  const wrap=handler=>async(req,res)=>{
    if(active>=maxRequests) {reject(req,res);return;}
    active++;
    let done=false;
    const release=()=>{if(!done){done=true;active--;}};
    res.once('close',release);res.once('finish',release);
    try {
      const path=new URL(req.url,'http://internal').pathname;
      // Notifications/reconciliation must still settle already-paid orders at low disk.
      if(req.method==='POST' && ['/v1/ai/complete','/v1/orders','/v1/feedback'].includes(path)
        && !(await resources()).writesAllowed){reject(req,res);return;}
      await handler(req,res);
    }catch{if(!res.headersSent)reject(req,res);else res.end();}
  };
  return {wrap,snapshot,refresh:resources};
}
function reject(req,res) {
  res.writeHead(503,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','Retry-After':'5','Connection':'close'});
  res.end(JSON.stringify({error:'service_busy',detail:'ai_service_busy'}));
  req.resume();
}
