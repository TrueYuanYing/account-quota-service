BEGIN;
CREATE INDEX IF NOT EXISTS usage_requests_kind_state_finished ON iko.usage_requests(kind,state,finished_at);
INSERT INTO iko.schema_migrations(version) VALUES('007_usage_indexes');
COMMIT;
