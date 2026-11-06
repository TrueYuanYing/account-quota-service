import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {accountStore} from '../account_store.mjs';

if(!/^iko_topups_verify66_[0-9]+$/.test(process.env.PGDATABASE??''))
  throw new Error('disposable_verification_database_required');
const pool=new pg.Pool({max:1,statement_timeout:5000});
const store=accountStore(pool);
const alice='00000000-0000-0000-0000-000000000176';
const bob='00000000-0000-0000-0000-000000000177';
try {
  await pool.query('BEGIN');
  await pool.query("INSERT INTO auth.users(id,email) VALUES($1,'store-a@example.invalid'),($2,'store-b@example.invalid')",[alice,bob]);
  const products=await store.products();
  assert.deepEqual(products.map(p=>p.price_cents),[599,999,2999]);
  assert(products.every(p=>p.days===null));
  const sale=(await pool.query("SELECT iko.create_order($1,'topup_599') AS id",[alice])).rows[0].id;
  await pool.query("SELECT iko.grant_paid_order($1,'synthetic-store66',599)",[sale]);
  const id=await store.submitFeedback(alice,{requestId:'00000000-0000-0000-0000-000000000178',orderId:sale,category:'order',message:'Public synthetic feedback'});
  assert.equal((await store.feedback(alice))[0].id,id);
  assert.deepEqual(await store.feedback(bob),[]);
  const accounts=await store.adminQuery('accounts',{page:1,search:'store-a@'});
  assert.equal(accounts.rows.length,1);assert.equal(accounts.rows[0].id,alice);
  const orders=await store.adminQuery('orders',{page:1,search:'store-a@'});
  assert.equal(orders.rows[0].id,sale);assert.equal(orders.rows[0].balances.length,4);
  const feedback=await store.adminQuery('feedback',{page:1,search:'store-a@'});
  assert.equal(feedback.rows[0].id,id);
  assert.deepEqual((await store.adminQuery('orders',{page:1,search:"' OR true --"})).rows,[]);
  assert.deepEqual((await store.adminQuery('accounts',{page:2,search:''})).rows,[]);
  await store.adminAction('a'.repeat(64),'feedback',{requestId:'00000000-0000-0000-0000-000000000179',feedbackId:id,state:'resolved',reason:'Synthetic reviewed issue'});
  assert.equal((await store.feedback(alice))[0].state,'resolved');
  await store.adminAction('a'.repeat(64),'revoke',{requestId:'00000000-0000-0000-0000-000000000180',orderId:sale,reason:'Synthetic admin revocation'});
  assert((await store.accountDocument(alice)).quota.every(q=>q.remaining===0));
  assert.equal((await store.adminQuery('audit',{page:1,search:sale})).rows[0].action,'revoke_order');
  await pool.query('ROLLBACK');
  await verifyConcurrentRevocation();
  console.log('PASS: real products/profile/feedback/administrator queries, parameter isolation, four balances, revocation and audit');
} finally {await pool.end();}

async function verifyConcurrentRevocation() {
  const clients=new pg.Pool({max:3,statement_timeout:8000});
  const a=await clients.connect(), b=await clients.connect();
  const [{pid}]=(await b.query('SELECT pg_backend_pid() AS pid')).rows;
  async function waitUntilBlocked() {
    const until=Date.now()+5000;
    while(Date.now()<until) {
      if((await clients.query('SELECT cardinality(pg_blocking_pids($1))>0 AS blocked',[pid])).rows[0].blocked)return;
      await new Promise(resolve=>setTimeout(resolve,20));
    }
    throw new Error('second_real_connection_did_not_wait_for_account_lock');
  }
  try {
    for(const reserveFirst of [true,false]) {
      const user=randomUUID(),request=randomUUID();
      await clients.query("INSERT INTO auth.users(id,email) VALUES($1,'race66@example.invalid')",[user]);
      const sale=(await clients.query("SELECT iko.create_order($1,'topup_599') AS id",[user])).rows[0].id;
      await clients.query('SELECT iko.grant_paid_order($1,$2,599)',[sale,`synthetic-race66-${user}`]);
      await a.query('BEGIN');
      const reserve=[user,request,'answer','b'.repeat(64)];
      const revoke=['a'.repeat(64),randomUUID(),sale,'Synthetic two-connection race'];
      await a.query(reserveFirst?'SELECT iko.reserve_usage($1,$2,$3,$4)':'SELECT iko.revoke_order($1,$2,$3,$4)',reserveFirst?reserve:revoke);
      const waiting=b.query(reserveFirst?'SELECT iko.revoke_order($1,$2,$3,$4)':'SELECT iko.reserve_usage($1,$2,$3,$4)',reserveFirst?revoke:reserve)
        .then(()=>({code:'unexpected_success'}),error=>({code:error.code}));
      await waitUntilBlocked();
      await a.query('COMMIT');
      assert.equal((await waiting).code,reserveFirst?'55000':'P0001');
      const row=(await clients.query(`SELECT e.revoked,q.reserved,q.used FROM iko.entitlements e
        JOIN iko.quota_balances q ON q.entitlement_id=e.id WHERE e.order_id=$1 AND q.kind='answer'`,[sale])).rows[0];
      assert.deepEqual(row,{revoked:!reserveFirst,reserved:reserveFirst?1:0,used:0});
      if(reserveFirst)await clients.query('SELECT iko.settle_usage($1,$2,false)',[user,request]);
    }
    console.log('PASS: two real PostgreSQL connections serialize reservation/revocation in both orders, no revoked in-flight pack or overspend');
  }finally {
    await a.query('ROLLBACK');a.release();b.release();await clients.end();
  }
}
