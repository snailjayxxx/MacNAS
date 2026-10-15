BEGIN;
ALTER TABLE macnas.jobs
 ADD COLUMN kind text NOT NULL DEFAULT 'legacy' CHECK(kind IN ('legacy','label','appValue','fixtureHash')),
 ADD COLUMN owner_user text,
 ADD COLUMN app_id text CHECK(app_id IN ('hello-diagnostics','sample-file-index')),
 ADD COLUMN payload jsonb NOT NULL DEFAULT '{}'::jsonb,
 ADD COLUMN attempts integer NOT NULL DEFAULT 0 CHECK(attempts>=0),
 ADD COLUMN max_attempts integer NOT NULL DEFAULT 3 CHECK(max_attempts BETWEEN 1 AND 8),
 ADD COLUMN next_run_at timestamptz NOT NULL DEFAULT 'epoch',
 ADD COLUMN lease_token uuid,
 ADD COLUMN lease_until timestamptz,
 ADD COLUMN revision integer NOT NULL DEFAULT 0 CHECK(revision>=0),
 ADD COLUMN last_error text,
 ADD CONSTRAINT managed_job_scope CHECK(kind='legacy' OR ((owner_user IS NOT NULL)::int+(app_id IS NOT NULL)::int)=1),
 ADD CONSTRAINT lease_pair CHECK((lease_token IS NULL)=(lease_until IS NULL));
CREATE INDEX jobs_runnable ON macnas.jobs(next_run_at,id) WHERE kind<>'legacy' AND state IN ('queued','waiting_for_volume','running');
CREATE TABLE macnas.job_steps(
 job_id text NOT NULL REFERENCES macnas.jobs(id), step integer NOT NULL CHECK(step IN (0,1)),
 result jsonb NOT NULL, PRIMARY KEY(job_id,step));
CREATE TABLE macnas.event_clock(singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),next_sequence bigint NOT NULL CHECK(next_sequence>0));
INSERT INTO macnas.event_clock VALUES(true,1);
CREATE TABLE macnas.job_events(
 sequence bigint PRIMARY KEY CHECK(sequence>0), job_id text NOT NULL REFERENCES macnas.jobs(id),
 revision integer NOT NULL, owner_user text, app_id text, type text NOT NULL, state text NOT NULL,
 UNIQUE(job_id,revision), CHECK(((owner_user IS NOT NULL)::int+(app_id IS NOT NULL)::int)=1));
CREATE TABLE macnas.event_consumers(
 id text PRIMARY KEY, owner_user text, app_id text,
 ack_sequence bigint NOT NULL DEFAULT 0 CHECK(ack_sequence>=0),
 delivered_sequence bigint NOT NULL DEFAULT 0 CHECK(delivered_sequence>=ack_sequence),
 CHECK(((owner_user IS NOT NULL)::int+(app_id IS NOT NULL)::int)=1));
CREATE TABLE macnas.event_receipts(
 consumer_id text NOT NULL REFERENCES macnas.event_consumers(id), sequence bigint NOT NULL REFERENCES macnas.job_events(sequence),
 PRIMARY KEY(consumer_id,sequence));
INSERT INTO macnas.schema_migrations(version) VALUES(3);
COMMIT;
