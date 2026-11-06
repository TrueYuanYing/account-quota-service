BEGIN;
-- Charging and successful delivery are different facts. Historic completed
-- requests used the success-only policy, so their known result remains true.
ALTER TABLE iko.usage_requests ADD COLUMN result_valid boolean;
UPDATE iko.usage_requests SET result_valid=(state='completed') WHERE state<>'reserved';
CREATE FUNCTION iko.record_model_result(p_user uuid,p_request uuid,p_valid boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF p_user IS NULL OR p_request IS NULL OR p_valid IS NULL
  THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,64));
 UPDATE iko.usage_requests SET result_valid=p_valid
 WHERE user_id=p_user AND request_id=p_request AND state='completed' AND result_valid IS NULL;
END $$;
REVOKE ALL ON FUNCTION iko.record_model_result(uuid,uuid,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION iko.record_model_result(uuid,uuid,boolean) TO iko_model;
INSERT INTO iko.schema_migrations(version) VALUES('009_model_outcomes');
COMMIT;
