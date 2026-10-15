BEGIN;
ALTER TABLE app_hello_diagnostics.state ADD COLUMN revision integer NOT NULL DEFAULT 1 CHECK(revision > 0);
ALTER TABLE app_sample_file_index.state ADD COLUMN revision integer NOT NULL DEFAULT 1 CHECK(revision > 0);
INSERT INTO macnas.schema_migrations(version) VALUES(2);
COMMIT;
