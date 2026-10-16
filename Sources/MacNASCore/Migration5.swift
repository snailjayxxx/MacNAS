import Foundation

extension StateStore {
    static let migration5SQL = #"""
BEGIN;
CREATE TABLE macnas.capacity_scopes(
 singleton boolean NOT NULL,
 scope_id uuid NOT NULL,
 scope_version integer NOT NULL,
 instance_id uuid NOT NULL,
 origin_generation bigint NOT NULL,
 owner_user_utf8 bytea NOT NULL,
 library_id_utf8 bytea NOT NULL,
 database_name_utf8 bytea NOT NULL,
 host_id_utf8 bytea NOT NULL,
 origin_scope_sha256 text NOT NULL,
 byte_limit bigint NOT NULL,
 mode text NOT NULL,
 created_at timestamptz NOT NULL
);
CREATE TABLE macnas.capacity_allocations(
 allocation_id uuid NOT NULL,
 scope_id uuid NOT NULL,
 allocation_version integer NOT NULL,
 origin_kind text NOT NULL,
 idempotency_key_utf8 bytea NOT NULL,
 intent_sha256 text NOT NULL,
 declared_bytes bigint NOT NULL,
 state text NOT NULL,
 revision bigint NOT NULL,
 sha256 text,
 created_at timestamptz NOT NULL,
 armed_at timestamptz,
 owned_at timestamptz,
 cancelled_at timestamptz
);
CREATE FUNCTION macnas.valid_capacity_scope(s macnas.capacity_scopes) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $capacity_check$
SELECT coalesce(s.singleton AND s.scope_version=1 AND s.origin_generation BETWEEN 0 AND 9007199254740991
 AND octet_length(s.owner_user_utf8) BETWEEN 1 AND 128 AND position(decode('00','hex') IN s.owner_user_utf8)=0
 AND convert_to(convert_from(s.owner_user_utf8,'UTF8'),'UTF8')=s.owner_user_utf8
 AND octet_length(s.library_id_utf8) BETWEEN 1 AND 128 AND position(decode('00','hex') IN s.library_id_utf8)=0
 AND convert_to(convert_from(s.library_id_utf8,'UTF8'),'UTF8')=s.library_id_utf8
 AND octet_length(s.database_name_utf8) BETWEEN 16 AND 60
 AND convert_from(s.database_name_utf8,'UTF8') ~ '^macnas_fixture_[a-z0-9_]+$'
 AND octet_length(s.host_id_utf8) BETWEEN 1 AND 256 AND position(decode('00','hex') IN s.host_id_utf8)=0
 AND convert_to(convert_from(s.host_id_utf8,'UTF8'),'UTF8')=s.host_id_utf8
 AND s.origin_scope_sha256 ~ '^[0-9a-f]{64}$' AND s.byte_limit=67108864
 AND s.mode='metadata_only' AND isfinite(s.created_at) AND octet_length(to_jsonb(s)::text)<=3072,false)
$capacity_check$;
CREATE FUNCTION macnas.valid_capacity_allocation(a macnas.capacity_allocations) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $capacity_check$
SELECT coalesce(a.allocation_version=1 AND a.origin_kind IN ('initial','upload','copy')
 AND octet_length(a.idempotency_key_utf8) BETWEEN 1 AND 128 AND position(decode('00','hex') IN a.idempotency_key_utf8)=0
 AND convert_to(convert_from(a.idempotency_key_utf8,'UTF8'),'UTF8')=a.idempotency_key_utf8
 AND a.intent_sha256 ~ '^[0-9a-f]{64}$' AND a.declared_bytes BETWEEN 0 AND 16777216
 AND a.revision BETWEEN 1 AND 9007199254740991 AND isfinite(a.created_at)
 AND (a.armed_at IS NULL OR (isfinite(a.armed_at) AND a.armed_at>=a.created_at))
 AND (a.owned_at IS NULL OR (isfinite(a.owned_at) AND a.owned_at>=a.armed_at))
 AND (a.cancelled_at IS NULL OR (isfinite(a.cancelled_at) AND a.cancelled_at>=a.created_at))
 AND CASE a.state
  WHEN 'reserved' THEN a.revision=1 AND a.sha256 IS NULL AND a.armed_at IS NULL AND a.owned_at IS NULL AND a.cancelled_at IS NULL
  WHEN 'armed' THEN a.revision=2 AND a.sha256 IS NULL AND a.armed_at IS NOT NULL AND a.owned_at IS NULL AND a.cancelled_at IS NULL
  WHEN 'owned' THEN a.revision=3 AND a.sha256 ~ '^[0-9a-f]{64}$' AND a.armed_at IS NOT NULL AND a.owned_at IS NOT NULL AND a.cancelled_at IS NULL
  WHEN 'cancelled' THEN a.revision=2 AND a.sha256 IS NULL AND a.armed_at IS NULL AND a.owned_at IS NULL AND a.cancelled_at IS NOT NULL
  ELSE false END AND octet_length(to_jsonb(a)::text)<=2048,false)
$capacity_check$;
ALTER TABLE macnas.capacity_scopes ADD CONSTRAINT capacity_scopes_pkey PRIMARY KEY (singleton);
ALTER TABLE macnas.capacity_scopes ADD CONSTRAINT capacity_scopes_scope_unique UNIQUE (scope_id);
ALTER TABLE macnas.capacity_allocations ADD CONSTRAINT capacity_allocations_pkey PRIMARY KEY (allocation_id);
ALTER TABLE macnas.capacity_allocations ADD CONSTRAINT capacity_allocations_idempotency_unique UNIQUE (scope_id, origin_kind, idempotency_key_utf8);
ALTER TABLE macnas.capacity_allocations ADD CONSTRAINT capacity_allocations_scope_fk FOREIGN KEY (scope_id) REFERENCES macnas.capacity_scopes(scope_id) ON DELETE RESTRICT;
ALTER TABLE macnas.capacity_scopes ADD CONSTRAINT capacity_scopes_data_check CHECK (macnas.valid_capacity_scope(ROW(singleton, scope_id, scope_version, instance_id, origin_generation, owner_user_utf8, library_id_utf8, database_name_utf8, host_id_utf8, origin_scope_sha256, byte_limit, mode, created_at)::macnas.capacity_scopes));
ALTER TABLE macnas.capacity_allocations ADD CONSTRAINT capacity_allocations_data_check CHECK (macnas.valid_capacity_allocation(ROW(allocation_id, scope_id, allocation_version, origin_kind, idempotency_key_utf8, intent_sha256, declared_bytes, state, revision, sha256, created_at, armed_at, owned_at, cancelled_at)::macnas.capacity_allocations));
REVOKE ALL ON FUNCTION macnas.valid_capacity_scope(macnas.capacity_scopes) FROM PUBLIC;
REVOKE ALL ON FUNCTION macnas.valid_capacity_allocation(macnas.capacity_allocations) FROM PUBLIC;
INSERT INTO macnas.schema_migrations(version) VALUES(5);
COMMIT;
"""#
    static let schema5Columns: [String: [[String]]] = [
        "capacity_scopes": [
            ["singleton", "boolean", "NO"],
            ["scope_id", "uuid", "NO"],
            ["scope_version", "integer", "NO"],
            ["instance_id", "uuid", "NO"],
            ["origin_generation", "bigint", "NO"],
            ["owner_user_utf8", "bytea", "NO"],
            ["library_id_utf8", "bytea", "NO"],
            ["database_name_utf8", "bytea", "NO"],
            ["host_id_utf8", "bytea", "NO"],
            ["origin_scope_sha256", "text", "NO"],
            ["byte_limit", "bigint", "NO"],
            ["mode", "text", "NO"],
            ["created_at", "timestamp with time zone", "NO"],
        ],
        "capacity_allocations": [
            ["allocation_id", "uuid", "NO"],
            ["scope_id", "uuid", "NO"],
            ["allocation_version", "integer", "NO"],
            ["origin_kind", "text", "NO"],
            ["idempotency_key_utf8", "bytea", "NO"],
            ["intent_sha256", "text", "NO"],
            ["declared_bytes", "bigint", "NO"],
            ["state", "text", "NO"],
            ["revision", "bigint", "NO"],
            ["sha256", "text", "YES"],
            ["created_at", "timestamp with time zone", "NO"],
            ["armed_at", "timestamp with time zone", "YES"],
            ["owned_at", "timestamp with time zone", "YES"],
            ["cancelled_at", "timestamp with time zone", "YES"],
        ],
    ]
    static let schema5Constraints: [String: String] = [
        "capacity_scopes.capacity_scopes_pkey": "PRIMARY KEY (singleton)",
        "capacity_scopes.capacity_scopes_scope_unique": "UNIQUE (scope_id)",
        "capacity_allocations.capacity_allocations_pkey": "PRIMARY KEY (allocation_id)",
        "capacity_allocations.capacity_allocations_idempotency_unique": "UNIQUE (scope_id, origin_kind, idempotency_key_utf8)",
        "capacity_allocations.capacity_allocations_scope_fk": "FOREIGN KEY (scope_id) REFERENCES macnas.capacity_scopes(scope_id) ON DELETE RESTRICT",
        "capacity_scopes.capacity_scopes_data_check": "CHECK (macnas.valid_capacity_scope(ROW(singleton, scope_id, scope_version, instance_id, origin_generation, owner_user_utf8, library_id_utf8, database_name_utf8, host_id_utf8, origin_scope_sha256, byte_limit, mode, created_at)::macnas.capacity_scopes))",
        "capacity_allocations.capacity_allocations_data_check": "CHECK (macnas.valid_capacity_allocation(ROW(allocation_id, scope_id, allocation_version, origin_kind, idempotency_key_utf8, intent_sha256, declared_bytes, state, revision, sha256, created_at, armed_at, owned_at, cancelled_at)::macnas.capacity_allocations))",
    ]
    static let schema5Functions: [(String, String, String)] = [
        ("valid_capacity_scope", "macnas.capacity_scopes", #"""
SELECT coalesce(s.singleton AND s.scope_version=1 AND s.origin_generation BETWEEN 0 AND 9007199254740991
 AND octet_length(s.owner_user_utf8) BETWEEN 1 AND 128 AND position(decode('00','hex') IN s.owner_user_utf8)=0
 AND convert_to(convert_from(s.owner_user_utf8,'UTF8'),'UTF8')=s.owner_user_utf8
 AND octet_length(s.library_id_utf8) BETWEEN 1 AND 128 AND position(decode('00','hex') IN s.library_id_utf8)=0
 AND convert_to(convert_from(s.library_id_utf8,'UTF8'),'UTF8')=s.library_id_utf8
 AND octet_length(s.database_name_utf8) BETWEEN 16 AND 60
 AND convert_from(s.database_name_utf8,'UTF8') ~ '^macnas_fixture_[a-z0-9_]+$'
 AND octet_length(s.host_id_utf8) BETWEEN 1 AND 256 AND position(decode('00','hex') IN s.host_id_utf8)=0
 AND convert_to(convert_from(s.host_id_utf8,'UTF8'),'UTF8')=s.host_id_utf8
 AND s.origin_scope_sha256 ~ '^[0-9a-f]{64}$' AND s.byte_limit=67108864
 AND s.mode='metadata_only' AND isfinite(s.created_at) AND octet_length(to_jsonb(s)::text)<=3072,false)
"""#),
        ("valid_capacity_allocation", "macnas.capacity_allocations", #"""
SELECT coalesce(a.allocation_version=1 AND a.origin_kind IN ('initial','upload','copy')
 AND octet_length(a.idempotency_key_utf8) BETWEEN 1 AND 128 AND position(decode('00','hex') IN a.idempotency_key_utf8)=0
 AND convert_to(convert_from(a.idempotency_key_utf8,'UTF8'),'UTF8')=a.idempotency_key_utf8
 AND a.intent_sha256 ~ '^[0-9a-f]{64}$' AND a.declared_bytes BETWEEN 0 AND 16777216
 AND a.revision BETWEEN 1 AND 9007199254740991 AND isfinite(a.created_at)
 AND (a.armed_at IS NULL OR (isfinite(a.armed_at) AND a.armed_at>=a.created_at))
 AND (a.owned_at IS NULL OR (isfinite(a.owned_at) AND a.owned_at>=a.armed_at))
 AND (a.cancelled_at IS NULL OR (isfinite(a.cancelled_at) AND a.cancelled_at>=a.created_at))
 AND CASE a.state
  WHEN 'reserved' THEN a.revision=1 AND a.sha256 IS NULL AND a.armed_at IS NULL AND a.owned_at IS NULL AND a.cancelled_at IS NULL
  WHEN 'armed' THEN a.revision=2 AND a.sha256 IS NULL AND a.armed_at IS NOT NULL AND a.owned_at IS NULL AND a.cancelled_at IS NULL
  WHEN 'owned' THEN a.revision=3 AND a.sha256 ~ '^[0-9a-f]{64}$' AND a.armed_at IS NOT NULL AND a.owned_at IS NOT NULL AND a.cancelled_at IS NULL
  WHEN 'cancelled' THEN a.revision=2 AND a.sha256 IS NULL AND a.armed_at IS NULL AND a.owned_at IS NULL AND a.cancelled_at IS NOT NULL
  ELSE false END AND octet_length(to_jsonb(a)::text)<=2048,false)
"""#),
    ]
}
