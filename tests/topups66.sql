BEGIN;
INSERT INTO auth.users(id,email) VALUES
 ('00000000-0000-0000-0000-000000000166','topup-a@example.invalid'),
 ('00000000-0000-0000-0000-000000000167','topup-b@example.invalid');
DO $$
DECLARE
 a uuid:='00000000-0000-0000-0000-000000000166';
 b uuid:='00000000-0000-0000-0000-000000000167';
 sale uuid; second_sale uuid; other_sale uuid; grant_id uuid; note_id uuid;
 request uuid:=gen_random_uuid(); audit_id uuid:=gen_random_uuid();
 actor text:=repeat('a',64); denied boolean; total integer;
BEGIN
 IF (SELECT count(*) FROM iko.products WHERE active)<>3
   OR (SELECT price_cents FROM iko.products WHERE id='topup_599')<>599
   OR EXISTS(SELECT 1 FROM iko.products WHERE active AND days IS NOT NULL)
   THEN RAISE EXCEPTION 'New products must be three non-expiring credit packs'; END IF;
 denied:=false;
 BEGIN PERFORM iko.create_order(a,'monthly_5');
 EXCEPTION WHEN SQLSTATE '22023' THEN denied:=true; END;
 IF NOT denied THEN RAISE EXCEPTION 'Historical plan remains on sale'; END IF;
 sale:=iko.create_order(a,'topup_599');
 grant_id:=iko.grant_paid_order(sale,'synthetic-topup66-a',599);
 second_sale:=iko.create_order(a,'topup_599');
 PERFORM iko.grant_paid_order(second_sale,'synthetic-topup66-b',599);
 other_sale:=iko.create_order(a,'topup_999');
 PERFORM iko.grant_paid_order(other_sale,'synthetic-topup66-c',999);
 IF EXISTS(SELECT 1 FROM iko.entitlements WHERE user_id=a AND ends_at IS NOT NULL)
   THEN RAISE EXCEPTION 'New paid pack expires by calendar'; END IF;
 SELECT sum(quota) INTO total FROM iko.quota_balances q JOIN iko.entitlements e ON e.id=q.entitlement_id
   WHERE e.user_id=a AND kind='answer';
 IF total<>600 THEN RAISE EXCEPTION 'Repeated/cross-tier purchases did not add balances'; END IF;
 PERFORM iko.grant_paid_order(sale,'synthetic-topup66-a',599);
 IF (SELECT count(*) FROM iko.entitlements WHERE order_id=sale)<>1
   THEN RAISE EXCEPTION 'Duplicate payment added credits twice'; END IF;
 denied:=false;
 BEGIN PERFORM iko.submit_feedback(b,gen_random_uuid(),sale,'order','This is not my order');
 EXCEPTION WHEN SQLSTATE '22023' THEN denied:=true; END;
 IF NOT denied THEN RAISE EXCEPTION 'Feedback attached another account order'; END IF;
 note_id:=iko.submit_feedback(a,request,sale,'order','Public synthetic order feedback');
 IF iko.submit_feedback(a,request,sale,'order','Public synthetic order feedback')<>note_id
   THEN RAISE EXCEPTION 'Feedback retry created another ticket'; END IF;
 denied:=false;
 BEGIN PERFORM iko.submit_feedback(a,request,sale,'order','Changed request payload');
 EXCEPTION WHEN SQLSTATE '22023' THEN denied:=true; END;
 IF NOT denied THEN RAISE EXCEPTION 'Feedback request id reused with different body'; END IF;
 PERFORM iko.update_feedback(actor,audit_id,note_id,'processing','Investigating synthetic issue');
 PERFORM iko.update_feedback(actor,audit_id,note_id,'processing','Investigating synthetic issue');
 IF (SELECT count(*) FROM iko.admin_audit WHERE request_id=audit_id)<>1
   THEN RAISE EXCEPTION 'Admin retry duplicated audit'; END IF;
 PERFORM iko.reserve_usage(a,gen_random_uuid(),'answer',repeat('b',64));
 denied:=false;
 BEGIN PERFORM iko.revoke_order(actor,gen_random_uuid(),sale,'Synthetic manual cancellation');
 EXCEPTION WHEN SQLSTATE '55000' THEN denied:=true; END;
 IF NOT denied THEN RAISE EXCEPTION 'Revoked a pack with an in-flight request'; END IF;
 SELECT request_id INTO request FROM iko.usage_requests WHERE user_id=a;
 PERFORM iko.settle_usage(a,request,true);
 audit_id:=gen_random_uuid();
 PERFORM iko.revoke_order(actor,audit_id,sale,'Synthetic manual cancellation');
 PERFORM iko.revoke_order(actor,audit_id,sale,'Synthetic manual cancellation');
 IF NOT (SELECT revoked FROM iko.entitlements WHERE id=grant_id)
   OR (SELECT used FROM iko.quota_balances WHERE entitlement_id=grant_id AND kind='answer')<>1
   OR (SELECT state FROM iko.orders WHERE id=sale)<>'paid'
   THEN RAISE EXCEPTION 'Revocation deleted usage or pretended a monetary refund'; END IF;
 IF EXISTS(SELECT 1 FROM iko.entitlements WHERE user_id=a AND order_id<>sale AND revoked)
   THEN RAISE EXCEPTION 'Revocation affected another credit pack'; END IF;
 SELECT sum(quota-used-reserved) INTO total FROM iko.quota_balances q JOIN iko.entitlements e ON e.id=q.entitlement_id
   WHERE e.user_id=a AND NOT e.revoked AND kind='answer';
 IF total<>450 THEN RAISE EXCEPTION 'Remaining credits after one-pack revocation differ'; END IF;
 denied:=false;
 BEGIN UPDATE iko.admin_audit SET reason='tampered' WHERE request_id=audit_id;
 EXCEPTION WHEN SQLSTATE '55000' THEN denied:=true; END;
 IF NOT denied THEN RAISE EXCEPTION 'Audit history can be rewritten'; END IF;
END $$;
ROLLBACK;
