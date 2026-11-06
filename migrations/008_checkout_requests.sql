BEGIN;
ALTER TABLE iko.payment_intents ADD COLUMN account_label text;
UPDATE iko.payment_intents i SET account_label=CASE WHEN position('@' IN u.email)>0 THEN
 left(split_part(u.email,'@',1),2)||'***'||right(split_part(u.email,'@',1),2)||'@'||split_part(u.email,'@',2)
 ELSE '账号尾号 '||right(u.id::text,8) END FROM auth.users u WHERE u.id=i.user_id;
ALTER TABLE iko.payment_intents ALTER COLUMN account_label SET NOT NULL;
CREATE TABLE iko.checkout_requests (
 user_id uuid NOT NULL,
 request_id uuid NOT NULL,
 order_id uuid NOT NULL REFERENCES iko.orders(id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(user_id,request_id)
);
INSERT INTO iko.checkout_requests(user_id,request_id,order_id,created_at)
 SELECT i.user_id,i.request_id,i.order_id,o.created_at FROM iko.payment_intents i JOIN iko.orders o ON o.id=i.order_id;
REVOKE ALL ON iko.checkout_requests FROM PUBLIC;
CREATE INDEX checkout_request_hourly ON iko.checkout_requests(user_id,created_at);
CREATE INDEX pending_checkout_by_account ON iko.orders(user_id,product_id,created_at DESC) WHERE state='pending';

CREATE OR REPLACE FUNCTION iko.open_checkout(p_user uuid,p_request uuid,p_product text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result uuid; previous text;
BEGIN
 IF p_user IS NULL OR p_request IS NULL OR p_product IS NULL THEN RAISE EXCEPTION 'invalid_order' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,68));
 SELECT o.id,o.product_id INTO result,previous FROM iko.checkout_requests r JOIN iko.orders o ON o.id=r.order_id
  WHERE r.user_id=p_user AND r.request_id=p_request;
 IF FOUND THEN
  IF previous<>p_product THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
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
INSERT INTO iko.schema_migrations(version) VALUES('008_checkout_requests');
COMMIT;
