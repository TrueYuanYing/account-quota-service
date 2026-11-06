import assert from 'node:assert/strict';
import pg from 'pg';
import {accountStore} from '../account_store.mjs';

// This runner is intentionally limited to a disposable synthetic database.
if(!/^iko_ledger_verify64_[0-9]+$/.test(process.env.PGDATABASE??''))
  throw new Error('disposable_verification_database_required');
const pool=new pg.Pool({max:1,statement_timeout:5000});
const store=accountStore(pool);
const alice='00000000-0000-0000-0000-000000000067';
const bob='00000000-0000-0000-0000-000000000068';
try {
  await pool.query('BEGIN');
  await pool.query('INSERT INTO auth.users(id) VALUES($1),($2)',[alice,bob]);
  const empty=await store.accountDocument(alice);
  assert.equal(empty.displayName,'');assert.deepEqual(empty.orders,[]);
  assert.deepEqual(empty.entitlements,[]);
  assert.deepEqual(Object.keys(empty.todayUsage).sort(),['answer','correct','summary','translate']);
  for(const balance of empty.quota)assert.deepEqual(balance,
    {kind:balance.kind,total:0,used:0,reserved:0,remaining:0});
  assert.equal(empty.quota.length,4);
  const hostileName="O'Neil; SELECT 'synthetic'";
  await store.saveProfile(alice,hostileName);
  assert.equal((await store.accountDocument(alice)).displayName,hostileName);
  assert.equal((await store.accountDocument(bob)).displayName,'');

  const sale=(await pool.query("SELECT iko.create_order($1,'monthly_5') id",[alice])).rows[0].id;
  const grant=(await pool.query("SELECT iko.grant_paid_order($1,'store-synthetic64',500) id",[sale])).rows[0].id;
  const request='00000000-0000-0000-0000-000000000069';
  await pool.query("SELECT iko.reserve_usage($1,$2,'answer',repeat('a',64))",[alice,request]);
  const reserved=await store.accountDocument(alice);
  assert.deepEqual(reserved.quota.find(x=>x.kind==='answer'),
    {kind:'answer',total:200,used:0,reserved:1,remaining:199});
  await pool.query('SELECT iko.settle_usage($1,$2,true)',[alice,request]);
  const completed=await store.accountDocument(alice);
  assert.equal(completed.todayUsage.answer,1);
  assert.equal(completed.todayUsage.correct,0);
  assert.equal(completed.orders[0].id,sale);
  assert.equal(completed.entitlements[0].id,grant);
  const isolated=await store.accountDocument(bob);
  assert.deepEqual(isolated.orders,[]);assert.deepEqual(isolated.entitlements,[]);
  assert.equal(isolated.todayUsage.answer,0);
  assert.equal(isolated.quota.find(x=>x.kind==='answer').total,0);

  await pool.query("UPDATE iko.usage_requests SET finished_at=(date_trunc('day',clock_timestamp() AT TIME ZONE 'Asia/Shanghai') AT TIME ZONE 'Asia/Shanghai')-interval '1 second' WHERE user_id=$1",[alice]);
  assert.equal((await store.accountDocument(alice)).todayUsage.answer,0);
  await pool.query("UPDATE iko.entitlements SET ends_at=clock_timestamp()-interval '1 second' WHERE id=$1",[grant]);
  assert.equal((await store.accountDocument(alice)).quota.find(x=>x.kind==='answer').remaining,0);
  await pool.query('ROLLBACK');
  console.log('PASS: real account-store queries, all four zero balances, independent profiles/orders/usage, reservation/expiry and Shanghai daily counts');
} finally {await pool.end();}
