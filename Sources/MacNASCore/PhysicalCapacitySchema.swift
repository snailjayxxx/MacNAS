import Foundation

extension StateStore {
    func validatePhysicalCapacitySchema6() throws {
        let tables = ["physical_capacity_scopes", "capacity_file_ownership"]
        let relationIDs = tables.map { "'macnas.\($0)'::regclass" }.joined(separator: ",")
        for table in tables {
            let columns = try rows("SELECT a.attname,format_type(a.atttypid,a.atttypmod),CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END FROM pg_attribute a WHERE a.attrelid='macnas.\(table)'::regclass AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum;")
            try require(columns == Self.schema6Columns[table], .invalidSchema)
            try require(try rows("SELECT relkind,relispartition,relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid='macnas.\(table)'::regclass;") == [["r","f","f","f"]], .invalidSchema)
            try require(try rows("SELECT count(*) FROM pg_attribute WHERE attrelid='macnas.\(table)'::regclass AND attnum>0 AND (attisdropped OR atthasdef OR attidentity<>'' OR attgenerated<>'');") == [["0"]], .invalidSchema)
        }
        let constraints = try rows("SELECT c.relname||'.'||p.conname,pg_get_constraintdef(p.oid),p.convalidated,p.conislocal FROM pg_constraint p JOIN pg_class c ON c.oid=p.conrelid WHERE p.conrelid IN (\(relationIDs)) AND p.contype IN ('c','p','u','f','x') ORDER BY 1;")
        try require(constraints.count == Self.schema6Constraints.count, .invalidSchema)
        for row in constraints {
            guard row.count == 4, let expected = Self.schema6Constraints[row[0]] else { throw NASError.invalidSchema }
            try require(row[2] == "t" && row[3] == "t" && Self.definition(row[1]) == Self.definition(expected), .invalidSchema)
        }
        // The complete ten-function namespace was checked before invoking these bodies.
        try require(try rows("SELECT NOT EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes p WHERE macnas.valid_physical_capacity_scope(p) IS NOT TRUE) AND NOT EXISTS(SELECT 1 FROM macnas.capacity_file_ownership o WHERE macnas.valid_capacity_file_ownership(o) IS NOT TRUE);") == [["t"]], .invalidSchema)
        let indexes = try rows("SELECT i.relname,x.indisvalid,x.indisready,pg_get_indexdef(i.oid) FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid WHERE x.indrelid IN (\(relationIDs)) ORDER BY i.relname;")
        let expected = [
            ["capacity_file_ownership_pkey","t","t","CREATE UNIQUE INDEX capacity_file_ownership_pkey ON macnas.capacity_file_ownership USING btree (allocation_id)"],
            ["physical_capacity_scopes_pkey","t","t","CREATE UNIQUE INDEX physical_capacity_scopes_pkey ON macnas.physical_capacity_scopes USING btree (scope_id)"]
        ]
        try require(indexes.map { $0.map(Self.definition) } == expected.map { $0.map(Self.definition) }, .invalidSchema)
        try require(try rows("SELECT count(*) FROM pg_trigger WHERE tgrelid IN (\(relationIDs)) AND NOT tgisinternal;") == [["0"]], .invalidSchema)
        try require(try rows("""
        SELECT (SELECT count(*) FROM macnas.physical_capacity_scopes)<=1
          AND (SELECT count(*) FROM macnas.capacity_file_ownership)<=64
          AND NOT EXISTS(SELECT 1 FROM macnas.capacity_file_ownership o JOIN macnas.capacity_allocations a USING(allocation_id)
            LEFT JOIN macnas.physical_capacity_scopes p USING(scope_id)
            WHERE p.scope_id IS NULL OR (a.state='owned') IS DISTINCT FROM (o.baseline_stamp IS NOT NULL)
              OR (a.state='owned' AND (o.sha256 IS DISTINCT FROM a.sha256 OR o.published_at IS DISTINCT FROM a.owned_at
                OR (o.baseline_stamp->>'bytes')::bigint<>a.declared_bytes
                OR o.baseline_stamp->>'device'<>p.device OR (o.baseline_stamp->>'uid')::bigint<>p.owner_uid)))
          AND NOT EXISTS(SELECT 1 FROM macnas.capacity_allocations a JOIN macnas.physical_capacity_scopes p USING(scope_id)
            LEFT JOIN macnas.capacity_file_ownership o USING(allocation_id)
            WHERE o.allocation_id IS NULL OR a.origin_kind='initial');
        """) == [["t"]], .invalidSchema)
        for app in SampleApp.allCases {
            let role = try Self.quote(app.role(database: databaseName))
            let permissions = tables.map { "has_table_privilege(r.oid,'macnas.\($0)','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')" }.joined(separator: " OR ")
            try require(try rows("SELECT NOT EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname=\(role) AND (\(permissions)));") == [["t"]], .denied)
        }
    }
}
