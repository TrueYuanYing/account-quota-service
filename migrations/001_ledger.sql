BEGIN;
CREATE SCHEMA IF NOT EXISTS iko;
REVOKE ALL ON SCHEMA iko FROM PUBLIC;
CREATE TABLE iko.schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO iko.schema_migrations(version) VALUES('001_ledger');

CREATE TABLE iko.products (
  id text PRIMARY KEY,
  price_cents integer NOT NULL CHECK(price_cents>0),
  days integer CHECK(days>0),
  quotas jsonb NOT NULL CHECK(jsonb_typeof(quotas)='object')
);
INSERT INTO iko.products VALUES
 ('monthly_5',500,30,'{"answer":200,"correct":500,"translate":180,"summary":50}'),
 ('monthly_999',999,30,'{"answer":500,"correct":1000,"translate":300,"summary":100}'),
 ('permanent_2999',2999,NULL,'{"answer":2000,"correct":3000,"translate":1000,"summary":300}');

CREATE TABLE iko.account_documents (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NOT NULL DEFAULT '' CHECK(char_length(display_name)<=40),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE iko.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  product_id text NOT NULL REFERENCES iko.products(id),
  price_cents integer NOT NULL CHECK(price_cents>0),
  days integer CHECK(days>0),
  quotas jsonb NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','paid','refunded')),
  provider_trade_no text UNIQUE CHECK(char_length(provider_trade_no) BETWEEN 1 AND 128),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  paid_at timestamptz
);
CREATE INDEX ON iko.orders(user_id,created_at);
CREATE TABLE iko.entitlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES iko.orders(id),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  starts_at timestamptz NOT NULL,
  ends_at timestamptz,
  revoked boolean NOT NULL DEFAULT false
);
CREATE INDEX ON iko.entitlements(user_id,ends_at);
CREATE TABLE iko.quota_balances (
  entitlement_id uuid NOT NULL REFERENCES iko.entitlements(id),
  kind text NOT NULL CHECK(kind IN ('answer','correct','translate','summary')),
  quota integer NOT NULL CHECK(quota>=0),
  used integer NOT NULL DEFAULT 0,
  reserved integer NOT NULL DEFAULT 0,
  PRIMARY KEY(entitlement_id,kind),
  CHECK(used>=0 AND reserved>=0 AND used+reserved<=quota)
);
CREATE TABLE iko.usage_requests (
  user_id uuid NOT NULL REFERENCES auth.users(id),
  request_id uuid NOT NULL,
  entitlement_id uuid NOT NULL,
  kind text NOT NULL,
  input_digest text NOT NULL CHECK(input_digest ~ '^[0-9a-f]{64}$'),
  state text NOT NULL CHECK(state IN ('reserved','completed','released')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  finished_at timestamptz,
  PRIMARY KEY(user_id,request_id),
  FOREIGN KEY(entitlement_id,kind) REFERENCES iko.quota_balances(entitlement_id,kind)
);
CREATE INDEX ON iko.usage_requests(user_id,state,created_at);

CREATE FUNCTION iko.create_order(p_user uuid,p_product text) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE result uuid;
BEGIN
  INSERT INTO iko.orders(user_id,product_id,price_cents,days,quotas)
  SELECT p_user,id,price_cents,days,quotas FROM iko.products WHERE id=p_product
  RETURNING id INTO result;
  IF result IS NULL THEN RAISE EXCEPTION 'unknown_product' USING ERRCODE='22023'; END IF;
  RETURN result;
END $$;

-- Only the trusted payment handler calls this AFTER signature + server query validation.
CREATE FUNCTION iko.grant_paid_order(p_order uuid,p_trade text,p_cents integer) RETURNS uuid
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
  IF sale.state<>'pending' THEN RAISE EXCEPTION 'order_not_pending' USING ERRCODE='22023'; END IF;
  UPDATE iko.orders SET state='paid',provider_trade_no=p_trade,paid_at=moment WHERE id=p_order;
  INSERT INTO iko.entitlements(order_id,user_id,starts_at,ends_at)
  VALUES(p_order,sale.user_id,moment,CASE WHEN sale.days IS NULL THEN NULL ELSE moment+make_interval(days=>sale.days) END)
  RETURNING id INTO result;
  INSERT INTO iko.quota_balances(entitlement_id,kind,quota)
  SELECT result,key,value::integer FROM jsonb_each_text(sale.quotas);
  RETURN result;
END $$;

CREATE FUNCTION iko.settle_usage(p_user uuid,p_request uuid,p_success boolean) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE request iko.usage_requests; result text;
BEGIN
  IF p_user IS NULL OR p_request IS NULL OR p_success IS NULL
    THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,64));
  SELECT * INTO request FROM iko.usage_requests WHERE user_id=p_user AND request_id=p_request FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown_request' USING ERRCODE='22023'; END IF;
  IF request.state<>'reserved' THEN RETURN request.state; END IF;
  result:=CASE WHEN p_success THEN 'completed' ELSE 'released' END;
  UPDATE iko.quota_balances SET reserved=reserved-1,used=used+CASE WHEN p_success THEN 1 ELSE 0 END
  WHERE entitlement_id=request.entitlement_id AND kind=request.kind;
  UPDATE iko.usage_requests SET state=result,finished_at=clock_timestamp()
  WHERE user_id=p_user AND request_id=p_request;
  RETURN result;
END $$;

CREATE FUNCTION iko.reserve_usage(p_user uuid,p_request uuid,p_kind text,p_digest text) RETURNS text
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE previous iko.usage_requests; selected uuid;
BEGIN
  IF p_user IS NULL OR p_request IS NULL OR p_kind IS NULL
    OR p_kind NOT IN ('answer','correct','translate','summary') OR p_digest IS NULL OR p_digest !~ '^[0-9a-f]{64}$'
    THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user::text,64));
  -- Elapsed time alone cannot prove that the upstream operation failed.
  -- Release only after the trusted executor confirms failure/cancellation.
  SELECT * INTO previous FROM iko.usage_requests WHERE user_id=p_user AND request_id=p_request;
  IF FOUND THEN
    IF previous.kind<>p_kind OR previous.input_digest<>p_digest
      THEN RAISE EXCEPTION 'request_id_conflict' USING ERRCODE='22023'; END IF;
    RETURN previous.state;
  END IF;
  SELECT b.entitlement_id INTO selected FROM iko.quota_balances b JOIN iko.entitlements e ON e.id=b.entitlement_id
  WHERE e.user_id=p_user AND NOT e.revoked AND (e.ends_at IS NULL OR e.ends_at>clock_timestamp())
    AND b.kind=p_kind AND b.used+b.reserved<b.quota
  ORDER BY e.ends_at NULLS LAST,e.starts_at LIMIT 1 FOR UPDATE OF b;
  IF selected IS NULL THEN RAISE EXCEPTION 'quota_unavailable' USING ERRCODE='P0001'; END IF;
  UPDATE iko.quota_balances SET reserved=reserved+1 WHERE entitlement_id=selected AND kind=p_kind;
  INSERT INTO iko.usage_requests(user_id,request_id,entitlement_id,kind,input_digest,state)
  VALUES(p_user,p_request,selected,p_kind,p_digest,'reserved');
  RETURN 'reserved';
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA iko FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA iko FROM PUBLIC;
COMMIT;
