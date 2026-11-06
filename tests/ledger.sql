BEGIN;
INSERT INTO auth.users(id) VALUES
 ('00000000-0000-0000-0000-000000000064'),
 ('00000000-0000-0000-0000-000000000065');
DO $$
DECLARE
  a uuid:='00000000-0000-0000-0000-000000000064';
  b uuid:='00000000-0000-0000-0000-000000000065';
  sale uuid; other_sale uuid; grant_id uuid; permanent_id uuid;
  request uuid:=gen_random_uuid(); second_request uuid:=gen_random_uuid(); stale_request uuid:=gen_random_uuid();
  digest text:=repeat('a',64); denied boolean;
BEGIN
  IF (SELECT quotas FROM iko.products WHERE id='monthly_5')<>'{"answer":200,"correct":500,"translate":180,"summary":50}'::jsonb
    OR (SELECT quotas FROM iko.products WHERE id='monthly_999')<>'{"answer":500,"correct":1000,"translate":300,"summary":100}'::jsonb
    OR (SELECT quotas FROM iko.products WHERE id='permanent_2999')<>'{"answer":2000,"correct":3000,"translate":1000,"summary":300}'::jsonb
    THEN RAISE EXCEPTION 'Product quota contract differs'; END IF;
  sale:=iko.create_order(a,'monthly_5');
  denied:=false;
  BEGIN PERFORM iko.grant_paid_order(sale,'synthetic-trade-64',499);
  EXCEPTION WHEN SQLSTATE '22023' THEN denied:=SQLERRM='payment_mismatch'; END;
  IF NOT denied OR (SELECT state FROM iko.orders WHERE id=sale)<>'pending'
    THEN RAISE EXCEPTION 'Wrong amount changed the order'; END IF;
  grant_id:=iko.grant_paid_order(sale,'synthetic-trade-64',500);
  IF iko.grant_paid_order(sale,'synthetic-trade-64',500)<>grant_id
    OR (SELECT count(*) FROM iko.entitlements WHERE order_id=sale)<>1
    THEN RAISE EXCEPTION 'Duplicate callback grants twice'; END IF;
  IF (SELECT ends_at-starts_at FROM iko.entitlements WHERE id=grant_id)<>interval '30 days'
    THEN RAISE EXCEPTION 'Monthly expiry differs'; END IF;
  other_sale:=iko.create_order(b,'monthly_5');
  denied:=false;
  BEGIN PERFORM iko.grant_paid_order(other_sale,'synthetic-trade-64',500);
  EXCEPTION WHEN unique_violation THEN denied:=true; END;
  IF NOT denied OR (SELECT state FROM iko.orders WHERE id=other_sale)<>'pending'
    THEN RAISE EXCEPTION 'One payment reused across accounts'; END IF;

  -- A single remaining answer credit makes reservation/idempotency observable.
  UPDATE iko.quota_balances SET quota=1 WHERE entitlement_id=grant_id AND kind='answer';
  PERFORM iko.reserve_usage(a,request,'answer',digest);
  PERFORM iko.reserve_usage(a,request,'answer',digest);
  IF (SELECT reserved FROM iko.quota_balances WHERE entitlement_id=grant_id AND kind='answer')<>1
    THEN RAISE EXCEPTION 'Retry reserves twice'; END IF;
  denied:=false;
  BEGIN PERFORM iko.reserve_usage(a,request,'answer',repeat('b',64));
  EXCEPTION WHEN SQLSTATE '22023' THEN denied:=SQLERRM='request_id_conflict'; END;
  IF NOT denied THEN RAISE EXCEPTION 'Conflicting request ID accepted'; END IF;
  denied:=false;
  BEGIN PERFORM iko.settle_usage(b,request,true);
  EXCEPTION WHEN SQLSTATE '22023' THEN denied:=SQLERRM='unknown_request'; END;
  IF NOT denied THEN RAISE EXCEPTION 'Another account settled this request'; END IF;
  PERFORM iko.settle_usage(a,request,true);
  PERFORM iko.settle_usage(a,request,true);
  IF (SELECT used FROM iko.quota_balances WHERE entitlement_id=grant_id AND kind='answer')<>1
    THEN RAISE EXCEPTION 'Successful retry charged twice'; END IF;
  denied:=false;
  BEGIN PERFORM iko.reserve_usage(a,second_request,'answer',digest);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN denied:=SQLERRM='quota_unavailable'; END;
  IF NOT denied THEN RAISE EXCEPTION 'Exhausted answer quota accepted'; END IF;
  PERFORM iko.reserve_usage(a,second_request,'translate',digest);
  PERFORM iko.settle_usage(a,second_request,false);
  IF (SELECT reserved+used FROM iko.quota_balances WHERE entitlement_id=grant_id AND kind='translate')<>0
    THEN RAISE EXCEPTION 'Failed translation did not release quota'; END IF;
  UPDATE iko.entitlements SET ends_at=clock_timestamp()-interval '1 second' WHERE id=grant_id;
  denied:=false;
  BEGIN PERFORM iko.reserve_usage(a,gen_random_uuid(),'correct',digest);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN denied:=SQLERRM='quota_unavailable'; END;
  IF NOT denied THEN RAISE EXCEPTION 'Expired quota accepted'; END IF;
  permanent_id:=iko.grant_paid_order(iko.create_order(a,'permanent_2999'),'synthetic-permanent-64',2999);
  IF (SELECT ends_at FROM iko.entitlements WHERE id=permanent_id) IS NOT NULL
    OR (SELECT quota FROM iko.quota_balances WHERE entitlement_id=permanent_id AND kind='answer')<>2000
    THEN RAISE EXCEPTION 'Permanent plan quota differs'; END IF;
  PERFORM iko.reserve_usage(a,stale_request,'summary',digest);
  UPDATE iko.usage_requests SET created_at=clock_timestamp()-interval '20 minutes'
    WHERE user_id=a AND request_id=stale_request;
  PERFORM iko.reserve_usage(a,gen_random_uuid(),'summary',digest);
  IF (SELECT state FROM iko.usage_requests WHERE user_id=a AND request_id=stale_request)<>'reserved'
    OR (SELECT reserved FROM iko.quota_balances WHERE entitlement_id=permanent_id AND kind='summary')<>2
    THEN RAISE EXCEPTION 'Time alone released an operation that may still be running'; END IF;
  PERFORM iko.settle_usage(a,stale_request,true);
  IF (SELECT state FROM iko.usage_requests WHERE user_id=a AND request_id=stale_request)<>'completed'
    OR (SELECT used FROM iko.quota_balances WHERE entitlement_id=permanent_id AND kind='summary')<>1
    THEN RAISE EXCEPTION 'Late success was not charged'; END IF;
  denied:=false;
  BEGIN PERFORM iko.reserve_usage(b,gen_random_uuid(),'summary',digest);
  EXCEPTION WHEN SQLSTATE 'P0001' THEN denied:=SQLERRM='quota_unavailable'; END;
  IF NOT denied THEN RAISE EXCEPTION 'Account quota crossed user boundary'; END IF;
END $$;
ROLLBACK;
