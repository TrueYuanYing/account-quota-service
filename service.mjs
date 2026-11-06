import http from 'node:http';
import {stat} from 'node:fs/promises';
import pg from 'pg';
import {createAccountApi} from './account_api.mjs';
import {accountStore} from './account_store.mjs';
import {accountModel} from './account_model.mjs';
import {providerRegistry} from './provider_registry.mjs';
import {providerGateway as createProviderGateway} from './provider_gateway.mjs';
import {zpayCheckout} from './zpay_checkout.mjs';
import {modelJournal} from './model_journal.mjs';
import {capacityGuard} from './capacity.mjs';

if(!process.env.DATABASE_URL || !process.env.AUTH_INTERNAL_URL)throw new Error('server_configuration_required');
const pool=new pg.Pool({connectionString:process.env.DATABASE_URL,max:5,
  connectionTimeoutMillis:3000,idleTimeoutMillis:30000,statement_timeout:5000});
pool.on('error',()=>{console.error('database_pool_unavailable');});
const modelPool=process.env.MODEL_DATABASE_URL?new pg.Pool({connectionString:process.env.MODEL_DATABASE_URL,
  max:8,connectionTimeoutMillis:3000,idleTimeoutMillis:30000,statement_timeout:5000}):null;
modelPool?.on('error',()=>{console.error('model_database_pool_unavailable');});
const modelStore=modelPool?{
  claimModel:async(user,request,kind,digest)=>(await modelPool.query('SELECT iko.claim_model_request($1,$2,$3,$4) AS state',[user,request,kind,digest])).rows[0].state,
  settleModel:async(user,request,success)=>(await modelPool.query('SELECT iko.finish_model_request($1,$2,$3) AS state',[user,request,success])).rows[0].state,
  recordModelResult:async(user,request,valid)=>modelPool.query('SELECT iko.record_model_result($1,$2,$3)',[user,request,valid]),
}:null;
const journal=modelPool?modelJournal(process.env.MODEL_JOURNAL_DIRECTORY || './runtime/model-journal'):null;
if(journal)await journal.recover(modelStore.settleModel,modelStore.recordModelResult);
let providers=null,providerGateway=null;
let existingProviderStore=false;
try{await stat((process.env.PROVIDER_DIRECTORY||'./runtime/providers')+'/registry.enc');existingProviderStore=true;}
catch(error){if(error.code!=='ENOENT')existingProviderStore=true;}
if(process.env.PROVIDER_ENCRYPTION_KEY || existingProviderStore){
  try {
    providers=await providerRegistry({directory:process.env.PROVIDER_DIRECTORY||'./runtime/providers',encryptionKey:process.env.PROVIDER_ENCRYPTION_KEY,
      legacyBalanceFetcher:()=>fetch(process.env.LEGACY_BALANCE_URL || 'https://example.invalid/v1/internal/balance',{redirect:'error',signal:AbortSignal.timeout(8000),
        headers:{Authorization:'Bearer '+process.env.ACCOUNT_PROXY_KEY}})});
    if(/^[a-f0-9]{64}$/.test(process.env.ACCOUNT_PROXY_KEY??''))providerGateway=createProviderGateway({registry:providers,proxyKey:process.env.ACCOUNT_PROXY_KEY});
  }catch{console.error('provider_store_unavailable');
    // Keep authentication and orders serving. Never silently select an old paid
    // connection when an existing encrypted selection cannot be read.
    providers={view:async()=>{throw new Error('provider_store_unavailable');},selected:async()=>{throw new Error('provider_store_unavailable');}};
    if(/^[a-f0-9]{64}$/.test(process.env.ACCOUNT_PROXY_KEY??''))providerGateway=createProviderGateway({registry:providers,proxyKey:process.env.ACCOUNT_PROXY_KEY});
  }
}
const model=modelPool?accountModel({proxyKey:process.env.ACCOUNT_PROXY_KEY,store:modelStore,journal,
  ...(providerGateway?{fetchImpl:providerGateway.relayFetch}:{})}):null;
const paymentPool=process.env.PAYMENT_DATABASE_URL?new pg.Pool({connectionString:process.env.PAYMENT_DATABASE_URL,
  max:3,connectionTimeoutMillis:3000,idleTimeoutMillis:30000,statement_timeout:5000}):null;
paymentPool?.on('error',()=>{console.error('payment_database_pool_unavailable');});
const payment=paymentPool?zpayCheckout({enabled:process.env.ZPAY_ENABLED==='1',trialUser:process.env.ZPAY_TEST_USER||null,pid:process.env.ZPAY_PID,
  cid:process.env.ZPAY_CID,key:process.env.ZPAY_KEY,linkKey:process.env.PAYMENT_LINK_KEY,store:{
    open:async(user,request,product)=>{
      const result=await paymentPool.query('SELECT iko.open_checkout($1,$2,$3) AS id',[user,request,product]);
      return (await paymentPool.query('SELECT o.*,i.out_trade_no,i.account_label,p.name FROM iko.orders o JOIN iko.payment_intents i ON i.order_id=o.id JOIN iko.products p ON p.id=o.product_id WHERE o.id=$1',[result.rows[0].id])).rows[0];
    },
    find:async id=>{await paymentPool.query('SELECT iko.expire_checkouts($1)',[id]);return (await paymentPool.query('SELECT o.*,i.out_trade_no,i.account_label,p.name FROM iko.orders o JOIN iko.payment_intents i ON i.order_id=o.id JOIN iko.products p ON p.id=o.product_id WHERE o.id=$1',[id])).rows[0];},
    findByNumber:async number=>(await paymentPool.query('SELECT o.*,i.out_trade_no FROM iko.orders o JOIN iko.payment_intents i ON i.order_id=o.id WHERE i.out_trade_no=$1',[number])).rows[0],
    grant:async(id,trade,cents)=>{await paymentPool.query('SELECT iko.accept_payment($1,$2,$3)',[id,trade,cents]);},
  }}):null;
const capacity=capacityGuard();
// Batch size and a non-overlapping interval bound the work even after downtime.
let expiring=false;
const expiryTimer=paymentPool?setInterval(async()=>{
  if(expiring)return;expiring=true;
  try{await paymentPool.query('SELECT iko.expire_checkouts()');}catch{console.error('order_expiry_retry_pending');}
  finally{expiring=false;}
},30000):null;
expiryTimer?.unref();
const server=http.createServer({maxHeaderSize:16384,headersTimeout:10000,requestTimeout:10000},
  capacity.wrap(createAccountApi({authUrl:process.env.AUTH_INTERNAL_URL,store:accountStore(pool),model,payment,capacity,providers,providerGateway})));
server.maxConnections=128;
server.setTimeout(55000,socket=>socket.destroy());
server.keepAliveTimeout=5000;
server.maxRequestsPerSocket=50;
server.listen(Number(process.env.PORT??8080),'0.0.0.0');
let stopping=false;
async function shutdown(){
  if(stopping)return;stopping=true;
  if(expiryTimer)clearInterval(expiryTimer);
  await new Promise(resolve=>server.close(resolve));
  await Promise.all([pool.end(),modelPool?.end(),paymentPool?.end()]);
}
process.on('SIGTERM',shutdown);
process.on('SIGINT',shutdown);
