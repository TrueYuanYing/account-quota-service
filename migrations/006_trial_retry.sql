BEGIN;
-- Inactive in the normal catalog, including when the API is rolled back to 69.
UPDATE iko.products SET active=false WHERE id='trial_001';
CREATE OR REPLACE FUNCTION iko.open_checkout(p_user uuid,p_request uuid,p_product text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; previous text;
BEGIN
 IF p_user IS NULL OR p_request IS NULL OR p_product IS NULL THEN RAISE EXCEPTION 'invalid_order' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,68));
 SELECT o.id,o.product_id INTO result,previous FROM iko.payment_intents i JOIN iko.orders o ON o.id=i.order_id
 WHERE i.user_id=p_user AND i.request_id=p_request;
 IF FOUND THEN
  IF previous<>p_product THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
  RETURN result;
 END IF;
 IF p_product='trial_001' THEN
  IF NOT EXISTS(SELECT 1 FROM iko.payment_trial_users WHERE user_id=p_user)
   THEN RAISE EXCEPTION 'trial_not_available' USING ERRCODE='55000'; END IF;
  SELECT id INTO result FROM iko.orders WHERE user_id=p_user AND product_id='trial_001' AND state='pending';
  IF FOUND THEN RETURN result; END IF;
  IF EXISTS(SELECT 1 FROM iko.orders WHERE user_id=p_user AND product_id='trial_001')
   THEN RAISE EXCEPTION 'trial_not_available' USING ERRCODE='55000'; END IF;
 END IF;
 IF (SELECT count(*) FROM iko.orders WHERE user_id=p_user AND created_at>clock_timestamp()-interval '1 hour')>=10
 THEN RAISE EXCEPTION 'order_rate_limit' USING ERRCODE='54000'; END IF;
 IF p_product='trial_001' THEN
  INSERT INTO iko.orders(user_id,product_id,price_cents,days,quotas)
   SELECT p_user,id,price_cents,days,quotas FROM iko.products WHERE id='trial_001' RETURNING id INTO result;
 ELSE result:=iko.create_order(p_user,p_product); END IF;
 INSERT INTO iko.payment_intents(order_id,user_id,request_id) VALUES(result,p_user,p_request);
 RETURN result;
END $$;
INSERT INTO iko.schema_migrations(version) VALUES('006_trial_retry');
COMMIT;
