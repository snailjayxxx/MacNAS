import Foundation

extension StateStore {
    static let migration6SQL = #"""
BEGIN;
CREATE TABLE macnas.physical_capacity_scopes(
 scope_id uuid NOT NULL,
 binding_version integer NOT NULL,
 registry_sha256 text NOT NULL,
 device text NOT NULL,
 library_inode text NOT NULL,
 vault_inode text NOT NULL,
 staging_inode text NOT NULL,
 owner_uid bigint NOT NULL,
 created_at timestamptz NOT NULL
);
CREATE TABLE macnas.capacity_file_ownership(
 allocation_id uuid NOT NULL,
 ownership_version integer NOT NULL,
 baseline_stamp jsonb,
 sha256 text,
 published_at timestamptz
);
CREATE FUNCTION macnas.valid_physical_capacity_scope(p macnas.physical_capacity_scopes) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $physical_check$
SELECT coalesce(p.binding_version=1 AND p.registry_sha256 ~ '^[0-9a-f]{64}$'
 AND (p.device ~ '^(0|[1-9][0-9]{0,19})$' AND (p.device)::numeric<=4294967295)
 AND (p.library_inode ~ '^(0|[1-9][0-9]{0,19})$' AND (p.library_inode)::numeric<=18446744073709551615)
 AND (p.vault_inode ~ '^(0|[1-9][0-9]{0,19})$' AND (p.vault_inode)::numeric<=18446744073709551615)
 AND (p.staging_inode ~ '^(0|[1-9][0-9]{0,19})$' AND (p.staging_inode)::numeric<=18446744073709551615)
 AND p.library_inode<>p.vault_inode AND p.library_inode<>p.staging_inode AND p.vault_inode<>p.staging_inode
 AND p.owner_uid BETWEEN 0 AND 4294967295 AND isfinite(p.created_at)
 AND octet_length(to_jsonb(p)::text)<=3072,false)
$physical_check$;
CREATE FUNCTION macnas.valid_capacity_file_ownership(o macnas.capacity_file_ownership) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $physical_check$
SELECT coalesce(o.ownership_version=1 AND (
 (o.baseline_stamp IS NULL AND o.sha256 IS NULL AND o.published_at IS NULL)
 OR (o.baseline_stamp IS NOT NULL AND o.sha256 ~ '^[0-9a-f]{64}$' AND isfinite(o.published_at)
     AND macnas.valid_file_effect_stamp(o.baseline_stamp)
     AND (((o.baseline_stamp->>'mode')::bigint) & 61440)=32768
     AND (((o.baseline_stamp->>'mode')::bigint) & 4095)=384
     AND (o.baseline_stamp->>'links')::bigint=1
     AND (o.baseline_stamp->>'bytes')::bigint BETWEEN 0 AND 16777216))
 AND octet_length(to_jsonb(o)::text)<=2048,false)
$physical_check$;
ALTER TABLE macnas.physical_capacity_scopes ADD CONSTRAINT physical_capacity_scopes_pkey PRIMARY KEY (scope_id);
ALTER TABLE macnas.physical_capacity_scopes ADD CONSTRAINT physical_capacity_scopes_scope_fk FOREIGN KEY (scope_id) REFERENCES macnas.capacity_scopes(scope_id) ON DELETE RESTRICT;
ALTER TABLE macnas.capacity_file_ownership ADD CONSTRAINT capacity_file_ownership_pkey PRIMARY KEY (allocation_id);
ALTER TABLE macnas.capacity_file_ownership ADD CONSTRAINT capacity_file_ownership_allocation_fk FOREIGN KEY (allocation_id) REFERENCES macnas.capacity_allocations(allocation_id) ON DELETE RESTRICT;
ALTER TABLE macnas.physical_capacity_scopes ADD CONSTRAINT physical_capacity_scopes_data_check CHECK (macnas.valid_physical_capacity_scope(ROW(scope_id, binding_version, registry_sha256, device, library_inode, vault_inode, staging_inode, owner_uid, created_at)::macnas.physical_capacity_scopes));
ALTER TABLE macnas.capacity_file_ownership ADD CONSTRAINT capacity_file_ownership_data_check CHECK (macnas.valid_capacity_file_ownership(ROW(allocation_id, ownership_version, baseline_stamp, sha256, published_at)::macnas.capacity_file_ownership));
REVOKE ALL ON FUNCTION macnas.valid_physical_capacity_scope(macnas.physical_capacity_scopes) FROM PUBLIC;
REVOKE ALL ON FUNCTION macnas.valid_capacity_file_ownership(macnas.capacity_file_ownership) FROM PUBLIC;
INSERT INTO macnas.schema_migrations(version) VALUES(6);
COMMIT;
"""#
    static let schema6Columns: [String: [[String]]] = [
        "physical_capacity_scopes": [
            ["scope_id", "uuid", "NO"],
            ["binding_version", "integer", "NO"],
            ["registry_sha256", "text", "NO"],
            ["device", "text", "NO"],
            ["library_inode", "text", "NO"],
            ["vault_inode", "text", "NO"],
            ["staging_inode", "text", "NO"],
            ["owner_uid", "bigint", "NO"],
            ["created_at", "timestamp with time zone", "NO"],
        ],
        "capacity_file_ownership": [
            ["allocation_id", "uuid", "NO"],
            ["ownership_version", "integer", "NO"],
            ["baseline_stamp", "jsonb", "YES"],
            ["sha256", "text", "YES"],
            ["published_at", "timestamp with time zone", "YES"],
        ],
    ]
    static let schema6Constraints: [String: String] = [
        "physical_capacity_scopes.physical_capacity_scopes_pkey": "PRIMARY KEY (scope_id)",
        "physical_capacity_scopes.physical_capacity_scopes_scope_fk": "FOREIGN KEY (scope_id) REFERENCES macnas.capacity_scopes(scope_id) ON DELETE RESTRICT",
        "capacity_file_ownership.capacity_file_ownership_pkey": "PRIMARY KEY (allocation_id)",
        "capacity_file_ownership.capacity_file_ownership_allocation_fk": "FOREIGN KEY (allocation_id) REFERENCES macnas.capacity_allocations(allocation_id) ON DELETE RESTRICT",
        "physical_capacity_scopes.physical_capacity_scopes_data_check": "CHECK (macnas.valid_physical_capacity_scope(ROW(scope_id, binding_version, registry_sha256, device, library_inode, vault_inode, staging_inode, owner_uid, created_at)::macnas.physical_capacity_scopes))",
        "capacity_file_ownership.capacity_file_ownership_data_check": "CHECK (macnas.valid_capacity_file_ownership(ROW(allocation_id, ownership_version, baseline_stamp, sha256, published_at)::macnas.capacity_file_ownership))",
    ]
    static let schema6Functions: [(String, String, String)] = [
        ("valid_physical_capacity_scope", "macnas.physical_capacity_scopes", #"""
SELECT coalesce(p.binding_version=1 AND p.registry_sha256 ~ '^[0-9a-f]{64}$'
 AND (p.device ~ '^(0|[1-9][0-9]{0,19})$' AND (p.device)::numeric<=4294967295)
 AND (p.library_inode ~ '^(0|[1-9][0-9]{0,19})$' AND (p.library_inode)::numeric<=18446744073709551615)
 AND (p.vault_inode ~ '^(0|[1-9][0-9]{0,19})$' AND (p.vault_inode)::numeric<=18446744073709551615)
 AND (p.staging_inode ~ '^(0|[1-9][0-9]{0,19})$' AND (p.staging_inode)::numeric<=18446744073709551615)
 AND p.library_inode<>p.vault_inode AND p.library_inode<>p.staging_inode AND p.vault_inode<>p.staging_inode
 AND p.owner_uid BETWEEN 0 AND 4294967295 AND isfinite(p.created_at)
 AND octet_length(to_jsonb(p)::text)<=3072,false)
"""#),
        ("valid_capacity_file_ownership", "macnas.capacity_file_ownership", #"""
SELECT coalesce(o.ownership_version=1 AND (
 (o.baseline_stamp IS NULL AND o.sha256 IS NULL AND o.published_at IS NULL)
 OR (o.baseline_stamp IS NOT NULL AND o.sha256 ~ '^[0-9a-f]{64}$' AND isfinite(o.published_at)
     AND macnas.valid_file_effect_stamp(o.baseline_stamp)
     AND (((o.baseline_stamp->>'mode')::bigint) & 61440)=32768
     AND (((o.baseline_stamp->>'mode')::bigint) & 4095)=384
     AND (o.baseline_stamp->>'links')::bigint=1
     AND (o.baseline_stamp->>'bytes')::bigint BETWEEN 0 AND 16777216))
 AND octet_length(to_jsonb(o)::text)<=2048,false)
"""#),
    ]
}
