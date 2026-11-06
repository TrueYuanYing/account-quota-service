BEGIN;
CREATE SEQUENCE iko.payment_order_numbers START 20261027000000000;
CREATE TABLE iko.payment_intents (
 order_id uuid PRIMARY KEY REFERENCES iko.orders(id),
 out_trade_no text NOT NULL UNIQUE DEFAULT nextval('iko.payment_order_numbers')::text CHECK(out_trade_no ~ '^[0-9]{1,32}$'),
 user_id uuid NOT NULL REFERENCES auth.users(id),
 request_id uuid NOT NULL,
 UNIQUE(user_id,request_id)
);
CREATE FUNCTION iko.open_checkout(p_user uuid,p_request uuid,p_product text) RETURNS uuid
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
 IF (SELECT count(*) FROM iko.orders WHERE user_id=p_user AND created_at>clock_timestamp()-interval '1 hour')>=10
 THEN RAISE EXCEPTION 'order_rate_limit' USING ERRCODE='54000'; END IF;
 result:=iko.create_order(p_user,p_product);
 INSERT INTO iko.payment_intents(order_id,user_id,request_id) VALUES(result,p_user,p_request);
 RETURN result;
END $$;
CREATE FUNCTION iko.accept_payment(p_order uuid,p_trade text,p_cents integer) RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT iko.grant_paid_order(p_order,p_trade,p_cents);
$$;
REVOKE ALL ON iko.payment_intents,iko.payment_order_numbers FROM PUBLIC;
REVOKE ALL ON FUNCTION iko.open_checkout(uuid,uuid,text),iko.accept_payment(uuid,text,integer) FROM PUBLIC;
GRANT USAGE ON SCHEMA iko TO iko_payments;
GRANT SELECT ON iko.payment_intents,iko.orders,iko.products TO iko_payments;
GRANT EXECUTE ON FUNCTION iko.open_checkout(uuid,uuid,text),iko.accept_payment(uuid,text,integer) TO iko_payments;
INSERT INTO iko.schema_migrations(version) VALUES('004_zpay_checkout');
COMMIT;
