BEGIN;
ALTER TABLE iko.products ADD COLUMN active boolean NOT NULL DEFAULT true;
ALTER TABLE iko.products ADD COLUMN name text NOT NULL DEFAULT '';
UPDATE iko.products SET active=false WHERE id IN('monthly_5','monthly_999','permanent_2999');
INSERT INTO iko.products(id,price_cents,days,quotas,name) VALUES
 ('topup_599',599,NULL,'{"answer":150,"correct":400,"translate":150,"summary":25}','5.99元额度包'),
 ('topup_999',999,NULL,'{"answer":300,"correct":700,"translate":250,"summary":50}','9.99元额度包'),
 ('topup_2999',2999,NULL,'{"answer":1000,"correct":2000,"translate":700,"summary":150}','29.99元额度包');

CREATE OR REPLACE FUNCTION iko.create_order(p_user uuid,p_product text) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE result uuid;
BEGIN
 INSERT INTO iko.orders(user_id,product_id,price_cents,days,quotas)
 SELECT p_user,id,price_cents,days,quotas FROM iko.products WHERE id=p_product AND active
 RETURNING id INTO result;
 IF result IS NULL THEN RAISE EXCEPTION 'unknown_product' USING ERRCODE='22023'; END IF;
 RETURN result;
END $$;

CREATE TABLE iko.feedback (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES auth.users(id),
 request_id uuid NOT NULL,
 order_id uuid REFERENCES iko.orders(id),
 category text NOT NULL CHECK(category IN('product','order')),
 message text NOT NULL CHECK(char_length(message) BETWEEN 3 AND 4000),
 state text NOT NULL DEFAULT 'open' CHECK(state IN('open','processing','resolved')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(user_id,request_id)
);
CREATE INDEX ON iko.feedback(state,created_at DESC);
CREATE INDEX ON iko.feedback(user_id,created_at DESC);
CREATE TABLE iko.admin_audit (
 request_id uuid PRIMARY KEY,
 actor_digest text NOT NULL CHECK(actor_digest ~ '^[a-f0-9]{64}$'),
 action text NOT NULL CHECK(action IN('feedback_state','revoke_order')),
 target_id uuid NOT NULL,
 reason text NOT NULL CHECK(char_length(reason) BETWEEN 3 AND 500),
 previous_state jsonb NOT NULL,
 next_state jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION iko.audit_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION 'audit_is_append_only' USING ERRCODE='55000'; END $$;
CREATE TRIGGER immutable_audit BEFORE UPDATE OR DELETE ON iko.admin_audit
FOR EACH ROW EXECUTE FUNCTION iko.audit_append_only();

CREATE FUNCTION iko.submit_feedback(p_user uuid,p_request uuid,p_order uuid,p_category text,p_message text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE previous iko.feedback; result uuid;
BEGIN
 IF p_user IS NULL OR p_request IS NULL OR p_category IS NULL OR p_category NOT IN('product','order')
   OR p_message IS NULL OR char_length(p_message) NOT BETWEEN 3 AND 4000
   OR (p_category='order' AND p_order IS NULL)
   THEN RAISE EXCEPTION 'invalid_feedback' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,66));
 SELECT * INTO previous FROM iko.feedback WHERE user_id=p_user AND request_id=p_request;
 IF FOUND THEN
   IF previous.order_id IS DISTINCT FROM p_order OR previous.category<>p_category OR previous.message<>p_message
     THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
   RETURN previous.id;
 END IF;
 IF p_order IS NOT NULL AND NOT EXISTS(SELECT 1 FROM iko.orders WHERE id=p_order AND user_id=p_user)
   THEN RAISE EXCEPTION 'invalid_feedback_order' USING ERRCODE='22023'; END IF;
 IF (SELECT count(*) FROM iko.feedback WHERE user_id=p_user AND created_at>clock_timestamp()-interval '1 day')>=10
   THEN RAISE EXCEPTION 'feedback_rate_limited' USING ERRCODE='54000'; END IF;
 INSERT INTO iko.feedback(user_id,request_id,order_id,category,message)
 VALUES(p_user,p_request,p_order,p_category,p_message) RETURNING id INTO result;
 RETURN result;
END $$;

CREATE FUNCTION iko.update_feedback(p_actor text,p_request uuid,p_id uuid,p_state text,p_reason text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE previous iko.admin_audit; item iko.feedback;
BEGIN
 IF p_actor IS NULL OR p_actor !~ '^[a-f0-9]{64}$' OR p_request IS NULL
   OR p_state IS NULL OR p_state NOT IN('open','processing','resolved')
   OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 3 AND 500
   THEN RAISE EXCEPTION 'invalid_admin_action' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request::text,67));
 SELECT * INTO previous FROM iko.admin_audit WHERE request_id=p_request;
 IF FOUND THEN
   IF previous.actor_digest<>p_actor OR previous.action<>'feedback_state' OR previous.target_id<>p_id
     OR previous.reason<>p_reason OR previous.next_state->>'state'<>p_state
     THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
   RETURN previous.next_state->>'state';
 END IF;
 SELECT * INTO item FROM iko.feedback WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'unknown_feedback' USING ERRCODE='22023'; END IF;
 UPDATE iko.feedback SET state=p_state,updated_at=clock_timestamp() WHERE id=p_id;
 INSERT INTO iko.admin_audit(request_id,actor_digest,action,target_id,reason,previous_state,next_state)
 VALUES(p_request,p_actor,'feedback_state',p_id,p_reason,jsonb_build_object('state',item.state),jsonb_build_object('state',p_state));
 RETURN p_state;
END $$;

CREATE FUNCTION iko.revoke_order(p_actor text,p_request uuid,p_order uuid,p_reason text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE previous iko.admin_audit; sale iko.orders; pack iko.entitlements;
BEGIN
 IF p_actor IS NULL OR p_actor !~ '^[a-f0-9]{64}$' OR p_request IS NULL OR p_order IS NULL
   OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 3 AND 500
   THEN RAISE EXCEPTION 'invalid_admin_action' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request::text,67));
 SELECT * INTO previous FROM iko.admin_audit WHERE request_id=p_request;
 IF FOUND THEN
   IF previous.actor_digest<>p_actor OR previous.action<>'revoke_order' OR previous.target_id<>p_order OR previous.reason<>p_reason
     THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
   RETURN true;
 END IF;
 SELECT * INTO sale FROM iko.orders WHERE id=p_order;
 IF NOT FOUND OR sale.state<>'paid' THEN RAISE EXCEPTION 'order_not_paid' USING ERRCODE='22023'; END IF;
 -- Use the same per-account lock as reservation/settlement; never revoke under an active request.
 PERFORM pg_advisory_xact_lock(hashtextextended(sale.user_id::text,64));
 SELECT * INTO sale FROM iko.orders WHERE id=p_order FOR UPDATE;
 SELECT * INTO pack FROM iko.entitlements WHERE order_id=p_order FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'missing_entitlement' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT 1 FROM iko.quota_balances WHERE entitlement_id=pack.id AND reserved>0)
   THEN RAISE EXCEPTION 'requests_in_flight' USING ERRCODE='55000'; END IF;
 UPDATE iko.entitlements SET revoked=true WHERE id=pack.id;
 INSERT INTO iko.admin_audit(request_id,actor_digest,action,target_id,reason,previous_state,next_state)
 VALUES(p_request,p_actor,'revoke_order',p_order,p_reason,
   jsonb_build_object('revoked',pack.revoked,'paymentState',sale.state),
   jsonb_build_object('revoked',true,'paymentState',sale.state,'moneyRefunded',false));
 RETURN true;
END $$;

CREATE VIEW iko.admin_accounts AS SELECT id,email,created_at FROM auth.users;
REVOKE ALL ON iko.feedback,iko.admin_audit,iko.admin_accounts FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION iko.audit_append_only(),iko.submit_feedback(uuid,uuid,uuid,text,text),
 iko.update_feedback(text,uuid,uuid,text,text),iko.revoke_order(text,uuid,uuid,text) FROM PUBLIC;
INSERT INTO iko.schema_migrations(version) VALUES('002_topups_feedback');
COMMIT;
