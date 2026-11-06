BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='15s';
CREATE FUNCTION iko.compensate_catalog87() RETURNS integer
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE sale record; extras jsonb; issued integer:=0;
BEGIN
 PERFORM pg_advisory_xact_lock(870013);
 FOR sale IN SELECT o.id,o.user_id,o.quotas,p.quotas AS current_quotas
   FROM iko.orders o JOIN iko.products p ON p.id=o.product_id JOIN iko.entitlements e ON e.order_id=o.id
   WHERE o.state='paid' AND NOT e.revoked AND (e.ends_at IS NULL OR e.ends_at>clock_timestamp())
    AND o.product_id IN('topup_599','topup_999','topup_2999')
    AND NOT EXISTS(SELECT 1 FROM iko.quota_grants g WHERE g.source_order_id=o.id)
   ORDER BY o.created_at,o.id
 LOOP
  SELECT jsonb_object_agg(key,greatest(value::integer-coalesce((sale.quotas->>key)::integer,0),0)) INTO extras
    FROM jsonb_each_text(sale.current_quotas);
  IF EXISTS(SELECT 1 FROM jsonb_each_text(extras) WHERE value::integer>0) THEN
    PERFORM iko.add_quota_grant(repeat('0',64),gen_random_uuid(),sale.user_id,extras,'2026-10-30 三档额度调整差额补发',sale.id);
    issued:=issued+1;
  END IF;
 END LOOP;
 RETURN issued;
END $$;
REVOKE EXECUTE ON FUNCTION iko.compensate_catalog87() FROM PUBLIC;
SELECT iko.compensate_catalog87();
INSERT INTO iko.schema_migrations(version) VALUES('013_catalog_adjustments87');
COMMIT;
