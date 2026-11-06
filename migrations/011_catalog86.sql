BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='10s';
-- Only future orders read these values. Never rewrite orders.quotas or balances.
UPDATE iko.products SET quotas='{"answer":150,"correct":400,"translate":150,"summary":25}'::jsonb
 WHERE id='topup_599';
UPDATE iko.products SET quotas='{"answer":400,"correct":1000,"translate":400,"summary":60}'::jsonb
 WHERE id='topup_999';
UPDATE iko.products SET quotas='{"answer":2000,"correct":5000,"translate":2000,"summary":300}'::jsonb
 WHERE id='topup_2999';
INSERT INTO iko.schema_migrations(version) VALUES('011_catalog86');
COMMIT;
