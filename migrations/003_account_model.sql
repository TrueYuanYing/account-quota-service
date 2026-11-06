BEGIN;
-- A duplicate pending request is not a second execution claim.
CREATE FUNCTION iko.claim_model_request(p_user uuid,p_request uuid,p_kind text,p_digest text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE previous iko.usage_requests;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,64));
 SELECT * INTO previous FROM iko.usage_requests WHERE user_id=p_user AND request_id=p_request;
 IF FOUND THEN
  IF previous.kind<>p_kind OR previous.input_digest<>p_digest
   THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
  RETURN previous.state;
 END IF;
 PERFORM iko.reserve_usage(p_user,p_request,p_kind,p_digest);
 RETURN 'claimed';
END $$;
CREATE FUNCTION iko.finish_model_request(p_user uuid,p_request uuid,p_success boolean) RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT iko.settle_usage(p_user,p_request,p_success);
$$;
REVOKE ALL ON FUNCTION iko.claim_model_request(uuid,uuid,text,text),iko.finish_model_request(uuid,uuid,boolean) FROM PUBLIC;
-- Separate runtime credential: no raw table writes, payment grants or auth access.
GRANT USAGE ON SCHEMA iko TO iko_model;
GRANT EXECUTE ON FUNCTION iko.claim_model_request(uuid,uuid,text,text),iko.finish_model_request(uuid,uuid,boolean) TO iko_model;
INSERT INTO iko.schema_migrations(version) VALUES('003_account_model');
COMMIT;
