BEGIN;
ALTER TABLE iko.orders DROP CONSTRAINT orders_state_check;
ALTER TABLE iko.orders ADD CONSTRAINT orders_state_check CHECK(state IN('pending','paid','refunded','expired'));
ALTER TABLE iko.orders ADD COLUMN closed_at timestamptz;
CREATE INDEX pending_order_expiry ON iko.orders(created_at,id) WHERE state='pending';
CREATE FUNCTION iko.expire_checkouts(p_order uuid DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE affected integer;
BEGIN
 UPDATE iko.orders SET state='expired',closed_at=clock_timestamp()
 WHERE id IN(SELECT id FROM iko.orders WHERE state='pending' AND (p_order IS NULL OR id=p_order)
   AND created_at<=clock_timestamp()-interval '15 minutes'
   ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 200);
 GET DIAGNOSTICS affected=ROW_COUNT;
 RETURN affected;
END $$;
REVOKE ALL ON FUNCTION iko.expire_checkouts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iko.expire_checkouts(uuid) TO iko_api,iko_payments;
CREATE OR REPLACE VIEW iko.admin_accounts AS SELECT id,email,created_at,
 last_sign_in_at,email_confirmed_at,(coalesce(encrypted_password,'')<>'') AS password_set
 FROM auth.users;
CREATE OR REPLACE FUNCTION iko.grant_paid_order(p_order uuid,p_trade text,p_cents integer) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE sale iko.orders; result uuid; moment timestamptz:=clock_timestamp();
BEGIN
  SELECT * INTO sale FROM iko.orders WHERE id=p_order FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown_order' USING ERRCODE='22023'; END IF;
  IF p_cents IS DISTINCT FROM sale.price_cents OR p_trade IS NULL OR char_length(p_trade) NOT BETWEEN 1 AND 128
    THEN RAISE EXCEPTION 'payment_mismatch' USING ERRCODE='22023'; END IF;
  IF sale.state='paid' AND sale.provider_trade_no=p_trade THEN
    SELECT id INTO STRICT result FROM iko.entitlements WHERE order_id=p_order;
    RETURN result;
  END IF;
  IF sale.state NOT IN('pending','expired') THEN RAISE EXCEPTION 'order_not_pending' USING ERRCODE='22023'; END IF;
  UPDATE iko.orders SET state='paid',provider_trade_no=p_trade,paid_at=moment WHERE id=p_order;
  INSERT INTO iko.entitlements(order_id,user_id,starts_at,ends_at)
  VALUES(p_order,sale.user_id,moment,CASE WHEN sale.days IS NULL THEN NULL ELSE moment+make_interval(days=>sale.days) END)
  RETURNING id INTO result;
  INSERT INTO iko.quota_balances(entitlement_id,kind,quota)
  SELECT result,key,value::integer FROM jsonb_each_text(sale.quotas);
  RETURN result;
END $$;
CREATE OR REPLACE FUNCTION iko.open_checkout(p_user uuid,p_request uuid,p_product text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; previous text;
BEGIN
 IF p_user IS NULL OR p_request IS NULL OR p_product IS NULL THEN RAISE EXCEPTION 'invalid_order' USING ERRCODE='22023'; END IF;
 PERFORM iko.expire_checkouts();
 PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,68));
 SELECT o.id,o.product_id INTO result,previous FROM iko.checkout_requests r JOIN iko.orders o ON o.id=r.order_id
  WHERE r.user_id=p_user AND r.request_id=p_request;
 IF FOUND THEN
  IF previous<>p_product THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
  PERFORM iko.expire_checkouts(result);
  RETURN result;
 END IF;
 -- Historical trial orders can settle, but no new trial is sold at launch.
 IF p_product='trial_001' THEN RAISE EXCEPTION 'trial_not_available' USING ERRCODE='55000'; END IF;
 IF p_product NOT IN('topup_599','topup_999','topup_2999') OR
  NOT EXISTS(SELECT 1 FROM iko.products WHERE id=p_product AND active)
  THEN RAISE EXCEPTION 'invalid_product' USING ERRCODE='22023'; END IF;
 IF (SELECT count(*) FROM iko.checkout_requests WHERE user_id=p_user AND created_at>clock_timestamp()-interval '1 hour')>=60
  THEN RAISE EXCEPTION 'checkout_request_rate_limit' USING ERRCODE='54000'; END IF;
 SELECT id INTO result FROM iko.orders WHERE user_id=p_user AND product_id=p_product AND state='pending'
  AND created_at>clock_timestamp()-interval '15 minutes'
  ORDER BY created_at DESC,id LIMIT 1;
 IF NOT FOUND THEN
  IF (SELECT count(*) FROM iko.orders WHERE user_id=p_user AND created_at>clock_timestamp()-interval '1 hour')>=10
   THEN RAISE EXCEPTION 'order_rate_limit' USING ERRCODE='54000'; END IF;
  result:=iko.create_order(p_user,p_product);
  INSERT INTO iko.payment_intents(order_id,user_id,request_id,account_label)
   SELECT result,p_user,p_request,CASE WHEN position('@' IN email)>0 THEN
    left(split_part(email,'@',1),2)||'***'||right(split_part(email,'@',1),2)||'@'||split_part(email,'@',2)
    ELSE '账号尾号 '||right(id::text,8) END FROM auth.users WHERE id=p_user;
 END IF;
 INSERT INTO iko.checkout_requests(user_id,request_id,order_id) VALUES(p_user,p_request,result);
 RETURN result;
END $$;
INSERT INTO iko.schema_migrations(version) VALUES('010_order_expiry_profiles');
COMMIT;
