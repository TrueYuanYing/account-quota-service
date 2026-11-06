BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='15s';
ALTER TABLE iko.account_documents ADD COLUMN avatar_jpeg bytea CHECK(octet_length(avatar_jpeg)<=32768);
ALTER TABLE iko.account_documents ADD COLUMN avatar_updated_at timestamptz;
CREATE TABLE iko.quota_grants (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), request_id uuid NOT NULL UNIQUE,
 user_id uuid NOT NULL REFERENCES auth.users(id), actor_digest text NOT NULL CHECK(actor_digest ~ '^[a-f0-9]{64}$'),
 source_order_id uuid UNIQUE REFERENCES iko.orders(id), quotas jsonb NOT NULL,
 reason text NOT NULL CHECK(char_length(reason) BETWEEN 3 AND 500), created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE iko.entitlements ALTER COLUMN order_id DROP NOT NULL;
ALTER TABLE iko.entitlements ADD COLUMN grant_id uuid UNIQUE REFERENCES iko.quota_grants(id);
ALTER TABLE iko.entitlements ADD CONSTRAINT entitlement_origin CHECK((order_id IS NOT NULL)::integer+(grant_id IS NOT NULL)::integer=1);
CREATE INDEX quota_grants_user ON iko.quota_grants(user_id,created_at DESC);
CREATE TABLE iko.account_notifications (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 grant_id uuid UNIQUE REFERENCES iko.quota_grants(id), title text NOT NULL CHECK(char_length(title)<=80),
 body text NOT NULL CHECK(char_length(body)<=500), quotas jsonb NOT NULL DEFAULT '{}'::jsonb,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), read_at timestamptz
);
CREATE INDEX notifications_user ON iko.account_notifications(user_id,created_at DESC,id);
CREATE INDEX notifications_unread ON iko.account_notifications(user_id) WHERE read_at IS NULL;
ALTER TABLE iko.admin_audit DROP CONSTRAINT admin_audit_action_check;
ALTER TABLE iko.admin_audit ADD CONSTRAINT admin_audit_action_check CHECK(action IN('feedback_state','revoke_order','grant_quota'));

CREATE FUNCTION iko.add_quota_grant(p_actor text,p_request uuid,p_user uuid,p_quotas jsonb,p_reason text,p_order uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE previous iko.quota_grants; grant_uuid uuid; entitlement uuid; pair record;
BEGIN
 IF p_actor IS NULL OR p_actor !~ '^[a-f0-9]{64}$' OR p_request IS NULL OR p_user IS NULL
  OR p_quotas IS NULL OR jsonb_typeof(p_quotas)<>'object'
  OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 3 AND 500
  THEN RAISE EXCEPTION 'invalid_quota_grant' USING ERRCODE='22023'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_each(p_quotas)) THEN RAISE EXCEPTION 'invalid_quota_grant' USING ERRCODE='22023'; END IF;
 FOR pair IN SELECT key,value FROM jsonb_each(p_quotas) LOOP
  IF pair.key NOT IN('answer','correct','translate','summary') OR jsonb_typeof(pair.value)<>'number'
   OR pair.value::text !~ '^(0|[1-9][0-9]{0,5})$' OR pair.value::integer>100000
   THEN RAISE EXCEPTION 'invalid_quota_grant' USING ERRCODE='22023'; END IF;
 END LOOP;
 IF NOT EXISTS(SELECT 1 FROM jsonb_each_text(p_quotas) WHERE value::integer>0)
  THEN RAISE EXCEPTION 'invalid_quota_grant' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request::text,87));
 PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,64));
 SELECT * INTO previous FROM iko.quota_grants WHERE request_id=p_request;
 IF FOUND THEN
  IF previous.actor_digest<>p_actor OR previous.user_id<>p_user OR previous.quotas<>p_quotas OR previous.reason<>p_reason
    OR previous.source_order_id IS DISTINCT FROM p_order
   THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
  RETURN previous.id;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=p_user) OR EXISTS(SELECT 1 FROM iko.admin_audit WHERE request_id=p_request)
  THEN RAISE EXCEPTION 'invalid_quota_grant' USING ERRCODE='22023'; END IF;
 IF p_order IS NOT NULL AND NOT EXISTS(SELECT 1 FROM iko.orders o JOIN iko.entitlements e ON e.order_id=o.id
   WHERE o.id=p_order AND o.user_id=p_user AND o.state='paid' AND NOT e.revoked)
  THEN RAISE EXCEPTION 'source_order_not_eligible' USING ERRCODE='22023'; END IF;
 INSERT INTO iko.quota_grants(request_id,user_id,actor_digest,source_order_id,quotas,reason)
 VALUES(p_request,p_user,p_actor,p_order,p_quotas,p_reason) RETURNING id INTO grant_uuid;
 INSERT INTO iko.entitlements(user_id,grant_id,starts_at) VALUES(p_user,grant_uuid,clock_timestamp()) RETURNING id INTO entitlement;
 INSERT INTO iko.quota_balances(entitlement_id,kind,quota)
 SELECT entitlement,key,value::integer FROM jsonb_each_text(p_quotas) WHERE value::integer>0;
 INSERT INTO iko.account_notifications(user_id,grant_id,title,body,quotas)
 VALUES(p_user,grant_uuid,'额度已到账',CASE WHEN p_order IS NULL THEN '管理员为你的账号增加了额度。' ELSE '已为此前充值补齐本次调整的额度差额，原用量保留。' END,p_quotas);
 INSERT INTO iko.admin_audit(request_id,actor_digest,action,target_id,reason,previous_state,next_state)
 VALUES(p_request,p_actor,'grant_quota',p_user,p_reason,'{}'::jsonb,jsonb_build_object('grantId',grant_uuid,'sourceOrderId',p_order,'quotas',p_quotas));
 RETURN grant_uuid;
END $$;
REVOKE ALL ON iko.quota_grants,iko.account_notifications FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION iko.add_quota_grant(text,uuid,uuid,jsonb,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iko.add_quota_grant(text,uuid,uuid,jsonb,text,uuid) TO iko_api;
GRANT SELECT ON iko.account_documents,iko.quota_grants,iko.account_notifications TO iko_api;
GRANT INSERT,UPDATE ON iko.account_documents TO iko_api;
GRANT UPDATE(read_at) ON iko.account_notifications TO iko_api;

-- Refund/revocation includes every supplementary grant backed by the same sale.
CREATE OR REPLACE FUNCTION iko.revoke_order(p_actor text,p_request uuid,p_order uuid,p_reason text) RETURNS boolean
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
 PERFORM pg_advisory_xact_lock(hashtextextended(sale.user_id::text,64));
 SELECT * INTO sale FROM iko.orders WHERE id=p_order FOR UPDATE;
 SELECT * INTO pack FROM iko.entitlements WHERE order_id=p_order FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'missing_entitlement' USING ERRCODE='22023'; END IF;
 PERFORM 1 FROM iko.entitlements WHERE order_id=p_order OR grant_id IN(SELECT id FROM iko.quota_grants WHERE source_order_id=p_order) FOR UPDATE;
 IF EXISTS(SELECT 1 FROM iko.quota_balances b JOIN iko.entitlements e ON e.id=b.entitlement_id
    WHERE (e.order_id=p_order OR e.grant_id IN(SELECT id FROM iko.quota_grants WHERE source_order_id=p_order)) AND b.reserved>0)
  THEN RAISE EXCEPTION 'requests_in_flight' USING ERRCODE='55000'; END IF;
 UPDATE iko.entitlements SET revoked=true WHERE order_id=p_order OR grant_id IN(SELECT id FROM iko.quota_grants WHERE source_order_id=p_order);
 INSERT INTO iko.admin_audit(request_id,actor_digest,action,target_id,reason,previous_state,next_state)
 VALUES(p_request,p_actor,'revoke_order',p_order,p_reason,jsonb_build_object('revoked',pack.revoked,'paymentState',sale.state),
  jsonb_build_object('revoked',true,'paymentState',sale.state,'moneyRefunded',false,'supplementsRevoked',true));
 RETURN true;
END $$;
INSERT INTO iko.schema_migrations(version) VALUES('012_account_extras87');
COMMIT;
