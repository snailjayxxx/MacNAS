BEGIN;
CREATE SCHEMA macnas;
CREATE SCHEMA app_hello_diagnostics;
CREATE SCHEMA app_sample_file_index;
CREATE TABLE macnas.schema_migrations(version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE macnas.labels(id text PRIMARY KEY, value text NOT NULL);
CREATE TABLE macnas.jobs(id text PRIMARY KEY, idempotency_key text UNIQUE NOT NULL,
 state text NOT NULL CHECK(state IN ('queued','running','waiting_for_volume','paused','failed','completed','cancelled')),
 effects integer NOT NULL DEFAULT 0 CHECK(effects >= 0), checkpoint jsonb NOT NULL DEFAULT '{}'::jsonb);
CREATE TABLE app_hello_diagnostics.state(id text PRIMARY KEY, value text NOT NULL);
CREATE TABLE app_sample_file_index.state(id text PRIMARY KEY, value text NOT NULL);
INSERT INTO macnas.schema_migrations(version) VALUES(1);
COMMIT;
