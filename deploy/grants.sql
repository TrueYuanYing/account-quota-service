-- Explicit API privileges missing from the historical one-time deploy scripts.
GRANT CONNECT ON DATABASE iko TO iko_api,iko_model,iko_payments;
GRANT USAGE ON SCHEMA iko TO iko_api;
GRANT SELECT ON iko.products,iko.account_documents,iko.orders,iko.entitlements,
 iko.quota_balances,iko.usage_requests,iko.feedback,iko.admin_audit,
 iko.admin_accounts,iko.account_notifications,iko.quota_grants TO iko_api;
GRANT INSERT(user_id,display_name),UPDATE(display_name) ON iko.account_documents TO iko_api;
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p
 JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='iko'
 AND p.proname IN ('submit_feedback','update_feedback','revoke_order','add_quota_grant','expire_checkouts')
 LOOP EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO iko_api',f.signature); END LOOP;
END $$;
