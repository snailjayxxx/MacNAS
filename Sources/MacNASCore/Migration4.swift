import Foundation

extension StateStore {
    static let migration4SQL = #"""
BEGIN;
CREATE TABLE macnas.recycle_entries(
 entry_id uuid NOT NULL,
 entry_version integer NOT NULL,
 instance_id uuid NOT NULL,
 origin_generation bigint NOT NULL,
 owner_user_utf8 bytea NOT NULL,
 library_id_utf8 bytea NOT NULL,
 original_path_utf8 bytea NOT NULL,
 volume_id uuid NOT NULL,
 vault_id uuid NOT NULL,
 payload_id uuid NOT NULL,
 byte_count bigint NOT NULL,
 sha256 text NOT NULL,
 charge_state text NOT NULL,
 active_operation_id uuid,
 revision bigint NOT NULL,
 created_at timestamp with time zone NOT NULL,
 retain_until timestamp with time zone NOT NULL
);
CREATE TABLE macnas.file_effect_operations(
 operation_id uuid NOT NULL,
 operation_version integer NOT NULL,
 entry_id uuid NOT NULL,
 instance_id uuid NOT NULL,
 origin_generation bigint NOT NULL,
 actor_user_utf8 bytea NOT NULL,
 idempotency_key_utf8 bytea NOT NULL,
 kind text NOT NULL,
 intent jsonb NOT NULL,
 intent_sha256 text NOT NULL,
 origin_scope_sha256 text NOT NULL,
 pre_evidence jsonb NOT NULL,
 post_evidence jsonb,
 phase text NOT NULL,
 revision bigint NOT NULL,
 prepared_at timestamp with time zone NOT NULL,
 armed_at timestamp with time zone,
 observed_at timestamp with time zone,
 completed_at timestamp with time zone,
 cancelled_at timestamp with time zone,
 source_parent_synced_at timestamp with time zone,
 target_parent_synced_at timestamp with time zone,
 error_code text,
 reconciler_user_utf8 bytea,
 reconciled_at timestamp with time zone
);
CREATE FUNCTION macnas.valid_file_effect_path(value text, allow_empty boolean) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog SET TimeZone = 'UTC' AS $function$
SELECT coalesce((allow_empty AND value = '') OR
 (value <> '' AND octet_length(value) <= 4096 AND left(value,1) <> '/'
  AND strpos(value, E'\\') = 0 AND strpos(value, ':') = 0
  AND cardinality(string_to_array(value,'/')) <= 128
  AND NOT EXISTS (SELECT 1 FROM unnest(string_to_array(value,'/')) part
    WHERE part IN ('','.','..') OR octet_length(part) > 255 OR btrim(part) = '')),false)
$function$;
CREATE FUNCTION macnas.valid_file_effect_stamp(value jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog SET TimeZone = 'UTC' AS $function$
SELECT coalesce(CASE WHEN jsonb_typeof(value) = 'object'
 AND value ?& ARRAY['device','inode','mode','uid','links','bytes','mtimeSeconds','mtimeNanos','ctimeSeconds','ctimeNanos']
 AND value - ARRAY['device','inode','mode','uid','links','bytes','mtimeSeconds','mtimeNanos','ctimeSeconds','ctimeNanos'] = '{}'::jsonb
 AND octet_length(value::text) <= 768
 AND jsonb_typeof(value->'device') = 'string'
 AND value->>'device' ~ '^(0|[1-9][0-9]{0,19})$'
 AND jsonb_typeof(value->'inode') = 'string'
 AND value->>'inode' ~ '^(0|[1-9][0-9]{0,19})$'
 AND jsonb_typeof(value->'mtimeSeconds') = 'string'
 AND value->>'mtimeSeconds' ~ '^(0|-?[1-9][0-9]{0,18})$'
 AND jsonb_typeof(value->'ctimeSeconds') = 'string'
 AND value->>'ctimeSeconds' ~ '^(0|-?[1-9][0-9]{0,18})$'
 AND jsonb_typeof(value->'mode') = 'number'
 AND value->>'mode' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'uid') = 'number'
 AND value->>'uid' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'links') = 'number'
 AND value->>'links' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'bytes') = 'number'
 AND value->>'bytes' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'mtimeNanos') = 'number'
 AND value->>'mtimeNanos' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'ctimeNanos') = 'number'
 AND value->>'ctimeNanos' ~ '^(0|[1-9][0-9]{0,15})$'
 THEN (value->>'device')::numeric BETWEEN 0 AND 18446744073709551615
 AND (value->>'inode')::numeric BETWEEN 0 AND 18446744073709551615
 AND (value->>'mtimeSeconds')::numeric BETWEEN -9223372036854775808 AND 9223372036854775807
 AND (value->>'ctimeSeconds')::numeric BETWEEN -9223372036854775808 AND 9223372036854775807
 AND (value->>'mode')::numeric BETWEEN 0 AND 65535
 AND (value->>'uid')::numeric BETWEEN 0 AND 4294967295
 AND (value->>'links')::numeric BETWEEN 1 AND 4294967295
 AND (value->>'bytes')::numeric BETWEEN 0 AND 9007199254740991
 AND (value->>'mtimeNanos')::numeric BETWEEN 0 AND 999999999
 AND (value->>'ctimeNanos')::numeric BETWEEN 0 AND 999999999 ELSE false END,false)
$function$;
CREATE FUNCTION macnas.valid_file_effect_intent(value jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog SET TimeZone = 'UTC' AS $function$
SELECT coalesce(jsonb_typeof(value) = 'object'
 AND value ?& ARRAY['intentVersion','kind','libraryID','sourcePath','targetParentPath','name']
 AND value - ARRAY['intentVersion','kind','libraryID','sourcePath','targetParentPath','name'] = '{}'::jsonb
 AND value->'intentVersion' = '1'::jsonb
 AND jsonb_typeof(value->'kind') = 'string' AND value->>'kind' IN ('recycle','restore')
 AND jsonb_typeof(value->'libraryID') = 'string' AND octet_length(value->>'libraryID') BETWEEN 1 AND 128
 AND jsonb_typeof(value->'sourcePath') = 'string' AND macnas.valid_file_effect_path(value->>'sourcePath',false)
 AND jsonb_typeof(value->'targetParentPath') = 'string' AND macnas.valid_file_effect_path(value->>'targetParentPath',true)
 AND cardinality(string_to_array(value->>'targetParentPath','/')) < 128
 AND jsonb_typeof(value->'name') = 'string' AND macnas.valid_file_effect_path(value->>'name',false)
 AND strpos(value->>'name','/') = 0 AND octet_length(value->>'name') <= 255
 AND octet_length(concat_ws('/',nullif(value->>'targetParentPath',''),value->>'name')) <= 4096
 AND (value->>'kind' <> 'recycle' OR (value->>'targetParentPath' = '' AND value->>'name' = (string_to_array(value->>'sourcePath','/'))[cardinality(string_to_array(value->>'sourcePath','/'))]))
 AND octet_length(value::text) <= 4096,false)
$function$;
CREATE FUNCTION macnas.valid_file_effect_evidence(value jsonb) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog SET TimeZone = 'UTC' AS $function$
SELECT coalesce(CASE WHEN jsonb_typeof(value) = 'object'
 AND value ?& ARRAY['evidenceVersion','object','sourceParent','targetParent','sha256']
 AND value - ARRAY['evidenceVersion','object','sourceParent','targetParent','sha256'] = '{}'::jsonb
 AND value->'evidenceVersion' = '1'::jsonb AND octet_length(value::text) <= 2048
 AND macnas.valid_file_effect_stamp(value->'object') AND macnas.valid_file_effect_stamp(value->'sourceParent')
 AND macnas.valid_file_effect_stamp(value->'targetParent')
 AND jsonb_typeof(value->'sha256') = 'string' AND value->>'sha256' ~ '^[0-9a-f]{64}$'
 THEN (value->'object'->>'links')::bigint = 1 AND ((value->'object'->>'mode')::integer & 61440) = 32768
 AND ((value->'sourceParent'->>'mode')::integer & 61440) = 16384
 AND ((value->'targetParent'->>'mode')::integer & 61440) = 16384 ELSE false END,false)
$function$;
CREATE FUNCTION macnas.valid_recycle_entry(e macnas.recycle_entries) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog SET TimeZone = 'UTC' AS $function$
SELECT coalesce(e.entry_version = 1 AND e.origin_generation >= 0 AND e.revision > 0
 AND octet_length(e.owner_user_utf8) BETWEEN 1 AND 128 AND convert_from(e.owner_user_utf8,'UTF8') IS NOT NULL
 AND octet_length(e.library_id_utf8) BETWEEN 1 AND 128 AND convert_from(e.library_id_utf8,'UTF8') IS NOT NULL
 AND octet_length(e.original_path_utf8) BETWEEN 1 AND 4096 AND macnas.valid_file_effect_path(convert_from(e.original_path_utf8,'UTF8'),false)
 AND e.byte_count BETWEEN 0 AND 16777216 AND e.sha256 ~ '^[0-9a-f]{64}$'
 AND e.charge_state IN ('reserved','retained','released')
 AND (e.charge_state <> 'reserved' OR e.active_operation_id IS NOT NULL)
 AND (e.charge_state <> 'released' OR e.active_operation_id IS NULL)
 AND isfinite(e.created_at) AND isfinite(e.retain_until) AND e.retain_until >= e.created_at
 AND extract(year FROM e.created_at) BETWEEN 1 AND 9999 AND extract(year FROM e.retain_until) BETWEEN 1 AND 9999
 AND octet_length(to_jsonb(e)::text) <= 4096,false)
$function$;
CREATE FUNCTION macnas.valid_file_effect_operation(o macnas.file_effect_operations) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog SET TimeZone = 'UTC' AS $function$
SELECT coalesce(o.operation_version = 1 AND o.origin_generation >= 0 AND o.revision > 0
 AND octet_length(o.actor_user_utf8) BETWEEN 1 AND 128 AND convert_from(o.actor_user_utf8,'UTF8') IS NOT NULL
 AND octet_length(o.idempotency_key_utf8) BETWEEN 1 AND 128 AND convert_from(o.idempotency_key_utf8,'UTF8') IS NOT NULL
 AND o.kind IN ('recycle','restore') AND macnas.valid_file_effect_intent(o.intent) AND o.intent->>'kind' = o.kind
 AND o.intent_sha256 ~ '^[0-9a-f]{64}$' AND o.intent_sha256 = encode(sha256(convert_to(o.intent::text,'UTF8')),'hex')
 AND o.origin_scope_sha256 ~ '^[0-9a-f]{64}$' AND macnas.valid_file_effect_evidence(o.pre_evidence)
 AND (o.post_evidence IS NULL OR macnas.valid_file_effect_evidence(o.post_evidence))
 AND o.phase IN ('prepared','armed','observed','completed','uncertain','cancelled')
 AND isfinite(o.prepared_at) AND extract(year FROM o.prepared_at) BETWEEN 1 AND 9999
 AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY[o.armed_at,o.observed_at,o.completed_at,o.cancelled_at,o.source_parent_synced_at,o.target_parent_synced_at,o.reconciled_at]) t WHERE t IS NOT NULL AND (NOT isfinite(t) OR extract(year FROM t) NOT BETWEEN 1 AND 9999 OR t < o.prepared_at))
 AND (o.armed_at IS NULL OR o.observed_at IS NULL OR o.observed_at >= o.armed_at)
 AND (o.observed_at IS NULL OR o.source_parent_synced_at IS NULL OR o.source_parent_synced_at >= o.observed_at)
 AND (o.observed_at IS NULL OR o.target_parent_synced_at IS NULL OR o.target_parent_synced_at >= o.observed_at)
 AND (o.completed_at IS NULL OR (o.completed_at >= o.source_parent_synced_at AND o.completed_at >= o.target_parent_synced_at))
 AND ((o.reconciler_user_utf8 IS NULL) = (o.reconciled_at IS NULL))
 AND (o.reconciler_user_utf8 IS NULL OR (octet_length(o.reconciler_user_utf8) BETWEEN 1 AND 128 AND convert_from(o.reconciler_user_utf8,'UTF8') IS NOT NULL))
 AND ((o.phase = 'prepared' AND o.armed_at IS NULL AND o.observed_at IS NULL AND o.post_evidence IS NULL AND o.completed_at IS NULL AND o.cancelled_at IS NULL AND o.source_parent_synced_at IS NULL AND o.target_parent_synced_at IS NULL AND o.error_code IS NULL)
 OR (o.phase = 'armed' AND o.armed_at IS NOT NULL AND o.observed_at IS NULL AND o.post_evidence IS NULL AND o.completed_at IS NULL AND o.cancelled_at IS NULL AND o.source_parent_synced_at IS NULL AND o.target_parent_synced_at IS NULL AND o.error_code IS NULL)
 OR (o.phase = 'observed' AND o.armed_at IS NOT NULL AND o.observed_at IS NOT NULL AND o.post_evidence IS NOT NULL AND o.completed_at IS NULL AND o.cancelled_at IS NULL AND o.error_code IS NULL)
 OR (o.phase = 'completed' AND o.armed_at IS NOT NULL AND o.observed_at IS NOT NULL AND o.post_evidence IS NOT NULL AND o.completed_at IS NOT NULL AND o.cancelled_at IS NULL AND o.source_parent_synced_at IS NOT NULL AND o.target_parent_synced_at IS NOT NULL AND o.error_code IS NULL)
 OR (o.phase = 'uncertain' AND o.armed_at IS NOT NULL AND ((o.observed_at IS NULL) = (o.post_evidence IS NULL)) AND (o.post_evidence IS NOT NULL OR (o.source_parent_synced_at IS NULL AND o.target_parent_synced_at IS NULL)) AND o.completed_at IS NULL AND o.cancelled_at IS NULL AND o.error_code IN ('unsafeFile','staleState','denied','expired','integrity','database','interrupted','unsupported','missingVolume','timedOut','unavailable','collision','budgetExceeded'))
 OR (o.phase = 'cancelled' AND o.armed_at IS NULL AND o.observed_at IS NULL AND o.post_evidence IS NULL AND o.completed_at IS NULL AND o.cancelled_at IS NOT NULL AND o.source_parent_synced_at IS NULL AND o.target_parent_synced_at IS NULL AND o.error_code IS NULL))
 AND octet_length(to_jsonb(o)::text) <= 8192
 AND (o.phase <> 'prepared' OR octet_length(to_jsonb(o)::text) + 3072 <= 8192),false)
$function$;
ALTER TABLE macnas.recycle_entries ADD CONSTRAINT recycle_entries_pkey PRIMARY KEY (entry_id);
ALTER TABLE macnas.recycle_entries ADD CONSTRAINT recycle_entries_payload_unique UNIQUE (instance_id, volume_id, vault_id, payload_id);
ALTER TABLE macnas.file_effect_operations ADD CONSTRAINT file_effect_operations_pkey PRIMARY KEY (operation_id);
ALTER TABLE macnas.file_effect_operations ADD CONSTRAINT file_effect_operations_entry_operation_unique UNIQUE (entry_id, operation_id);
ALTER TABLE macnas.file_effect_operations ADD CONSTRAINT file_effect_operations_idempotency_unique UNIQUE (instance_id, actor_user_utf8, kind, idempotency_key_utf8);
ALTER TABLE macnas.file_effect_operations ADD CONSTRAINT file_effect_operations_entry_fk FOREIGN KEY (entry_id) REFERENCES macnas.recycle_entries(entry_id) ON DELETE RESTRICT;
ALTER TABLE macnas.recycle_entries ADD CONSTRAINT recycle_entries_active_operation_fk FOREIGN KEY (entry_id, active_operation_id) REFERENCES macnas.file_effect_operations(entry_id, operation_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE macnas.recycle_entries ADD CONSTRAINT recycle_entries_data_check CHECK (macnas.valid_recycle_entry(ROW(entry_id, entry_version, instance_id, origin_generation, owner_user_utf8, library_id_utf8, original_path_utf8, volume_id, vault_id, payload_id, byte_count, sha256, charge_state, active_operation_id, revision, created_at, retain_until)::macnas.recycle_entries));
ALTER TABLE macnas.file_effect_operations ADD CONSTRAINT file_effect_operations_data_check CHECK (macnas.valid_file_effect_operation(ROW(operation_id, operation_version, entry_id, instance_id, origin_generation, actor_user_utf8, idempotency_key_utf8, kind, intent, intent_sha256, origin_scope_sha256, pre_evidence, post_evidence, phase, revision, prepared_at, armed_at, observed_at, completed_at, cancelled_at, source_parent_synced_at, target_parent_synced_at, error_code, reconciler_user_utf8, reconciled_at)::macnas.file_effect_operations));
CREATE UNIQUE INDEX file_effect_operations_one_active ON macnas.file_effect_operations USING btree (entry_id) WHERE phase = ANY (ARRAY['prepared'::text, 'armed'::text, 'observed'::text, 'uncertain'::text]);
CREATE INDEX recycle_entries_audience ON macnas.recycle_entries USING btree (instance_id, owner_user_utf8, created_at, entry_id);
CREATE INDEX recycle_entries_charge ON macnas.recycle_entries USING btree (instance_id, volume_id, vault_id, charge_state);
REVOKE ALL ON FUNCTION macnas.valid_file_effect_path(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION macnas.valid_file_effect_stamp(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION macnas.valid_file_effect_intent(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION macnas.valid_file_effect_evidence(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION macnas.valid_recycle_entry(macnas.recycle_entries) FROM PUBLIC;
REVOKE ALL ON FUNCTION macnas.valid_file_effect_operation(macnas.file_effect_operations) FROM PUBLIC;
INSERT INTO macnas.schema_migrations(version) VALUES(4);
COMMIT;
"""#
    static let schema4Columns: [String: [[String]]] = [
        "recycle_entries": [
            ["entry_id", "uuid", "NO"],
            ["entry_version", "integer", "NO"],
            ["instance_id", "uuid", "NO"],
            ["origin_generation", "bigint", "NO"],
            ["owner_user_utf8", "bytea", "NO"],
            ["library_id_utf8", "bytea", "NO"],
            ["original_path_utf8", "bytea", "NO"],
            ["volume_id", "uuid", "NO"],
            ["vault_id", "uuid", "NO"],
            ["payload_id", "uuid", "NO"],
            ["byte_count", "bigint", "NO"],
            ["sha256", "text", "NO"],
            ["charge_state", "text", "NO"],
            ["active_operation_id", "uuid", "YES"],
            ["revision", "bigint", "NO"],
            ["created_at", "timestamp with time zone", "NO"],
            ["retain_until", "timestamp with time zone", "NO"]
        ],
        "file_effect_operations": [
            ["operation_id", "uuid", "NO"],
            ["operation_version", "integer", "NO"],
            ["entry_id", "uuid", "NO"],
            ["instance_id", "uuid", "NO"],
            ["origin_generation", "bigint", "NO"],
            ["actor_user_utf8", "bytea", "NO"],
            ["idempotency_key_utf8", "bytea", "NO"],
            ["kind", "text", "NO"],
            ["intent", "jsonb", "NO"],
            ["intent_sha256", "text", "NO"],
            ["origin_scope_sha256", "text", "NO"],
            ["pre_evidence", "jsonb", "NO"],
            ["post_evidence", "jsonb", "YES"],
            ["phase", "text", "NO"],
            ["revision", "bigint", "NO"],
            ["prepared_at", "timestamp with time zone", "NO"],
            ["armed_at", "timestamp with time zone", "YES"],
            ["observed_at", "timestamp with time zone", "YES"],
            ["completed_at", "timestamp with time zone", "YES"],
            ["cancelled_at", "timestamp with time zone", "YES"],
            ["source_parent_synced_at", "timestamp with time zone", "YES"],
            ["target_parent_synced_at", "timestamp with time zone", "YES"],
            ["error_code", "text", "YES"],
            ["reconciler_user_utf8", "bytea", "YES"],
            ["reconciled_at", "timestamp with time zone", "YES"]
        ],
    ]
    static let schema4Constraints: [String: String] = [
        "recycle_entries.recycle_entries_pkey": "PRIMARY KEY (entry_id)",
        "recycle_entries.recycle_entries_payload_unique": "UNIQUE (instance_id, volume_id, vault_id, payload_id)",
        "file_effect_operations.file_effect_operations_pkey": "PRIMARY KEY (operation_id)",
        "file_effect_operations.file_effect_operations_entry_operation_unique": "UNIQUE (entry_id, operation_id)",
        "file_effect_operations.file_effect_operations_idempotency_unique": "UNIQUE (instance_id, actor_user_utf8, kind, idempotency_key_utf8)",
        "file_effect_operations.file_effect_operations_entry_fk": "FOREIGN KEY (entry_id) REFERENCES macnas.recycle_entries(entry_id) ON DELETE RESTRICT",
        "recycle_entries.recycle_entries_active_operation_fk": "FOREIGN KEY (entry_id, active_operation_id) REFERENCES macnas.file_effect_operations(entry_id, operation_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED",
        "recycle_entries.recycle_entries_data_check": "CHECK (macnas.valid_recycle_entry(ROW(entry_id, entry_version, instance_id, origin_generation, owner_user_utf8, library_id_utf8, original_path_utf8, volume_id, vault_id, payload_id, byte_count, sha256, charge_state, active_operation_id, revision, created_at, retain_until)::macnas.recycle_entries))",
        "file_effect_operations.file_effect_operations_data_check": "CHECK (macnas.valid_file_effect_operation(ROW(operation_id, operation_version, entry_id, instance_id, origin_generation, actor_user_utf8, idempotency_key_utf8, kind, intent, intent_sha256, origin_scope_sha256, pre_evidence, post_evidence, phase, revision, prepared_at, armed_at, observed_at, completed_at, cancelled_at, source_parent_synced_at, target_parent_synced_at, error_code, reconciler_user_utf8, reconciled_at)::macnas.file_effect_operations))",
    ]
    static let schema4Functions: [(String, String, String)] = [
        ("valid_file_effect_path", "text, boolean", #"""
SELECT coalesce((allow_empty AND value = '') OR
 (value <> '' AND octet_length(value) <= 4096 AND left(value,1) <> '/'
  AND strpos(value, E'\\') = 0 AND strpos(value, ':') = 0
  AND cardinality(string_to_array(value,'/')) <= 128
  AND NOT EXISTS (SELECT 1 FROM unnest(string_to_array(value,'/')) part
    WHERE part IN ('','.','..') OR octet_length(part) > 255 OR btrim(part) = '')),false)
"""#),
        ("valid_file_effect_stamp", "jsonb", #"""
SELECT coalesce(CASE WHEN jsonb_typeof(value) = 'object'
 AND value ?& ARRAY['device','inode','mode','uid','links','bytes','mtimeSeconds','mtimeNanos','ctimeSeconds','ctimeNanos']
 AND value - ARRAY['device','inode','mode','uid','links','bytes','mtimeSeconds','mtimeNanos','ctimeSeconds','ctimeNanos'] = '{}'::jsonb
 AND octet_length(value::text) <= 768
 AND jsonb_typeof(value->'device') = 'string'
 AND value->>'device' ~ '^(0|[1-9][0-9]{0,19})$'
 AND jsonb_typeof(value->'inode') = 'string'
 AND value->>'inode' ~ '^(0|[1-9][0-9]{0,19})$'
 AND jsonb_typeof(value->'mtimeSeconds') = 'string'
 AND value->>'mtimeSeconds' ~ '^(0|-?[1-9][0-9]{0,18})$'
 AND jsonb_typeof(value->'ctimeSeconds') = 'string'
 AND value->>'ctimeSeconds' ~ '^(0|-?[1-9][0-9]{0,18})$'
 AND jsonb_typeof(value->'mode') = 'number'
 AND value->>'mode' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'uid') = 'number'
 AND value->>'uid' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'links') = 'number'
 AND value->>'links' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'bytes') = 'number'
 AND value->>'bytes' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'mtimeNanos') = 'number'
 AND value->>'mtimeNanos' ~ '^(0|[1-9][0-9]{0,15})$'
 AND jsonb_typeof(value->'ctimeNanos') = 'number'
 AND value->>'ctimeNanos' ~ '^(0|[1-9][0-9]{0,15})$'
 THEN (value->>'device')::numeric BETWEEN 0 AND 18446744073709551615
 AND (value->>'inode')::numeric BETWEEN 0 AND 18446744073709551615
 AND (value->>'mtimeSeconds')::numeric BETWEEN -9223372036854775808 AND 9223372036854775807
 AND (value->>'ctimeSeconds')::numeric BETWEEN -9223372036854775808 AND 9223372036854775807
 AND (value->>'mode')::numeric BETWEEN 0 AND 65535
 AND (value->>'uid')::numeric BETWEEN 0 AND 4294967295
 AND (value->>'links')::numeric BETWEEN 1 AND 4294967295
 AND (value->>'bytes')::numeric BETWEEN 0 AND 9007199254740991
 AND (value->>'mtimeNanos')::numeric BETWEEN 0 AND 999999999
 AND (value->>'ctimeNanos')::numeric BETWEEN 0 AND 999999999 ELSE false END,false)
"""#),
        ("valid_file_effect_intent", "jsonb", #"""
SELECT coalesce(jsonb_typeof(value) = 'object'
 AND value ?& ARRAY['intentVersion','kind','libraryID','sourcePath','targetParentPath','name']
 AND value - ARRAY['intentVersion','kind','libraryID','sourcePath','targetParentPath','name'] = '{}'::jsonb
 AND value->'intentVersion' = '1'::jsonb
 AND jsonb_typeof(value->'kind') = 'string' AND value->>'kind' IN ('recycle','restore')
 AND jsonb_typeof(value->'libraryID') = 'string' AND octet_length(value->>'libraryID') BETWEEN 1 AND 128
 AND jsonb_typeof(value->'sourcePath') = 'string' AND macnas.valid_file_effect_path(value->>'sourcePath',false)
 AND jsonb_typeof(value->'targetParentPath') = 'string' AND macnas.valid_file_effect_path(value->>'targetParentPath',true)
 AND cardinality(string_to_array(value->>'targetParentPath','/')) < 128
 AND jsonb_typeof(value->'name') = 'string' AND macnas.valid_file_effect_path(value->>'name',false)
 AND strpos(value->>'name','/') = 0 AND octet_length(value->>'name') <= 255
 AND octet_length(concat_ws('/',nullif(value->>'targetParentPath',''),value->>'name')) <= 4096
 AND (value->>'kind' <> 'recycle' OR (value->>'targetParentPath' = '' AND value->>'name' = (string_to_array(value->>'sourcePath','/'))[cardinality(string_to_array(value->>'sourcePath','/'))]))
 AND octet_length(value::text) <= 4096,false)
"""#),
        ("valid_file_effect_evidence", "jsonb", #"""
SELECT coalesce(CASE WHEN jsonb_typeof(value) = 'object'
 AND value ?& ARRAY['evidenceVersion','object','sourceParent','targetParent','sha256']
 AND value - ARRAY['evidenceVersion','object','sourceParent','targetParent','sha256'] = '{}'::jsonb
 AND value->'evidenceVersion' = '1'::jsonb AND octet_length(value::text) <= 2048
 AND macnas.valid_file_effect_stamp(value->'object') AND macnas.valid_file_effect_stamp(value->'sourceParent')
 AND macnas.valid_file_effect_stamp(value->'targetParent')
 AND jsonb_typeof(value->'sha256') = 'string' AND value->>'sha256' ~ '^[0-9a-f]{64}$'
 THEN (value->'object'->>'links')::bigint = 1 AND ((value->'object'->>'mode')::integer & 61440) = 32768
 AND ((value->'sourceParent'->>'mode')::integer & 61440) = 16384
 AND ((value->'targetParent'->>'mode')::integer & 61440) = 16384 ELSE false END,false)
"""#),
        ("valid_recycle_entry", "macnas.recycle_entries", #"""
SELECT coalesce(e.entry_version = 1 AND e.origin_generation >= 0 AND e.revision > 0
 AND octet_length(e.owner_user_utf8) BETWEEN 1 AND 128 AND convert_from(e.owner_user_utf8,'UTF8') IS NOT NULL
 AND octet_length(e.library_id_utf8) BETWEEN 1 AND 128 AND convert_from(e.library_id_utf8,'UTF8') IS NOT NULL
 AND octet_length(e.original_path_utf8) BETWEEN 1 AND 4096 AND macnas.valid_file_effect_path(convert_from(e.original_path_utf8,'UTF8'),false)
 AND e.byte_count BETWEEN 0 AND 16777216 AND e.sha256 ~ '^[0-9a-f]{64}$'
 AND e.charge_state IN ('reserved','retained','released')
 AND (e.charge_state <> 'reserved' OR e.active_operation_id IS NOT NULL)
 AND (e.charge_state <> 'released' OR e.active_operation_id IS NULL)
 AND isfinite(e.created_at) AND isfinite(e.retain_until) AND e.retain_until >= e.created_at
 AND extract(year FROM e.created_at) BETWEEN 1 AND 9999 AND extract(year FROM e.retain_until) BETWEEN 1 AND 9999
 AND octet_length(to_jsonb(e)::text) <= 4096,false)
"""#),
        ("valid_file_effect_operation", "macnas.file_effect_operations", #"""
SELECT coalesce(o.operation_version = 1 AND o.origin_generation >= 0 AND o.revision > 0
 AND octet_length(o.actor_user_utf8) BETWEEN 1 AND 128 AND convert_from(o.actor_user_utf8,'UTF8') IS NOT NULL
 AND octet_length(o.idempotency_key_utf8) BETWEEN 1 AND 128 AND convert_from(o.idempotency_key_utf8,'UTF8') IS NOT NULL
 AND o.kind IN ('recycle','restore') AND macnas.valid_file_effect_intent(o.intent) AND o.intent->>'kind' = o.kind
 AND o.intent_sha256 ~ '^[0-9a-f]{64}$' AND o.intent_sha256 = encode(sha256(convert_to(o.intent::text,'UTF8')),'hex')
 AND o.origin_scope_sha256 ~ '^[0-9a-f]{64}$' AND macnas.valid_file_effect_evidence(o.pre_evidence)
 AND (o.post_evidence IS NULL OR macnas.valid_file_effect_evidence(o.post_evidence))
 AND o.phase IN ('prepared','armed','observed','completed','uncertain','cancelled')
 AND isfinite(o.prepared_at) AND extract(year FROM o.prepared_at) BETWEEN 1 AND 9999
 AND NOT EXISTS (SELECT 1 FROM unnest(ARRAY[o.armed_at,o.observed_at,o.completed_at,o.cancelled_at,o.source_parent_synced_at,o.target_parent_synced_at,o.reconciled_at]) t WHERE t IS NOT NULL AND (NOT isfinite(t) OR extract(year FROM t) NOT BETWEEN 1 AND 9999 OR t < o.prepared_at))
 AND (o.armed_at IS NULL OR o.observed_at IS NULL OR o.observed_at >= o.armed_at)
 AND (o.observed_at IS NULL OR o.source_parent_synced_at IS NULL OR o.source_parent_synced_at >= o.observed_at)
 AND (o.observed_at IS NULL OR o.target_parent_synced_at IS NULL OR o.target_parent_synced_at >= o.observed_at)
 AND (o.completed_at IS NULL OR (o.completed_at >= o.source_parent_synced_at AND o.completed_at >= o.target_parent_synced_at))
 AND ((o.reconciler_user_utf8 IS NULL) = (o.reconciled_at IS NULL))
 AND (o.reconciler_user_utf8 IS NULL OR (octet_length(o.reconciler_user_utf8) BETWEEN 1 AND 128 AND convert_from(o.reconciler_user_utf8,'UTF8') IS NOT NULL))
 AND ((o.phase = 'prepared' AND o.armed_at IS NULL AND o.observed_at IS NULL AND o.post_evidence IS NULL AND o.completed_at IS NULL AND o.cancelled_at IS NULL AND o.source_parent_synced_at IS NULL AND o.target_parent_synced_at IS NULL AND o.error_code IS NULL)
 OR (o.phase = 'armed' AND o.armed_at IS NOT NULL AND o.observed_at IS NULL AND o.post_evidence IS NULL AND o.completed_at IS NULL AND o.cancelled_at IS NULL AND o.source_parent_synced_at IS NULL AND o.target_parent_synced_at IS NULL AND o.error_code IS NULL)
 OR (o.phase = 'observed' AND o.armed_at IS NOT NULL AND o.observed_at IS NOT NULL AND o.post_evidence IS NOT NULL AND o.completed_at IS NULL AND o.cancelled_at IS NULL AND o.error_code IS NULL)
 OR (o.phase = 'completed' AND o.armed_at IS NOT NULL AND o.observed_at IS NOT NULL AND o.post_evidence IS NOT NULL AND o.completed_at IS NOT NULL AND o.cancelled_at IS NULL AND o.source_parent_synced_at IS NOT NULL AND o.target_parent_synced_at IS NOT NULL AND o.error_code IS NULL)
 OR (o.phase = 'uncertain' AND o.armed_at IS NOT NULL AND ((o.observed_at IS NULL) = (o.post_evidence IS NULL)) AND (o.post_evidence IS NOT NULL OR (o.source_parent_synced_at IS NULL AND o.target_parent_synced_at IS NULL)) AND o.completed_at IS NULL AND o.cancelled_at IS NULL AND o.error_code IN ('unsafeFile','staleState','denied','expired','integrity','database','interrupted','unsupported','missingVolume','timedOut','unavailable','collision','budgetExceeded'))
 OR (o.phase = 'cancelled' AND o.armed_at IS NULL AND o.observed_at IS NULL AND o.post_evidence IS NULL AND o.completed_at IS NULL AND o.cancelled_at IS NOT NULL AND o.source_parent_synced_at IS NULL AND o.target_parent_synced_at IS NULL AND o.error_code IS NULL))
 AND octet_length(to_jsonb(o)::text) <= 8192
 AND (o.phase <> 'prepared' OR octet_length(to_jsonb(o)::text) + 3072 <= 8192),false)
"""#),
    ]
    static let schema4Indexes: [String: String] = [
        "file_effect_operations_one_active": "CREATE UNIQUE INDEX file_effect_operations_one_active ON macnas.file_effect_operations USING btree (entry_id) WHERE phase = ANY (ARRAY['prepared'::text, 'armed'::text, 'observed'::text, 'uncertain'::text])",
        "recycle_entries_audience": "CREATE INDEX recycle_entries_audience ON macnas.recycle_entries USING btree (instance_id, owner_user_utf8, created_at, entry_id)",
        "recycle_entries_charge": "CREATE INDEX recycle_entries_charge ON macnas.recycle_entries USING btree (instance_id, volume_id, vault_id, charge_state)",
    ]
}
