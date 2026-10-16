import Foundation

extension StateStore {
    func hasCapacityHistory() throws -> Bool {
        guard try schemaVersion() >= 5 else { return false }
        return try rows("SELECT EXISTS(SELECT 1 FROM macnas.capacity_scopes) OR EXISTS(SELECT 1 FROM macnas.capacity_allocations);") != [["f"]]
    }
    func requirePortableCapacityEmpty() throws { try require(try !hasCapacityHistory(), .unsupported) }

    func validateCapacitySchema5() throws {
        let tables = ["capacity_scopes", "capacity_allocations"]
        let relationIDs = tables.map { "'macnas.\($0)'::regclass" }.joined(separator: ",")
        for table in tables {
            let columns = try rows("SELECT a.attname,format_type(a.atttypid,a.atttypmod),CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END FROM pg_attribute a WHERE a.attrelid='macnas.\(table)'::regclass AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum;")
            try require(columns == Self.schema5Columns[table], .invalidSchema)
            try require(try rows("SELECT relkind,relispartition,relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid='macnas.\(table)'::regclass;") == [["r","f","f","f"]], .invalidSchema)
            try require(try rows("SELECT count(*) FROM pg_attribute WHERE attrelid='macnas.\(table)'::regclass AND attnum>0 AND (attisdropped OR atthasdef OR attidentity<>'' OR attgenerated<>'');") == [["0"]], .invalidSchema)
        }
        let constraints = try rows("SELECT c.relname||'.'||p.conname,pg_get_constraintdef(p.oid),p.convalidated,p.conislocal FROM pg_constraint p JOIN pg_class c ON c.oid=p.conrelid WHERE p.conrelid IN (\(relationIDs)) AND p.contype IN ('c','p','u','f','x') ORDER BY 1;")
        try require(constraints.count == Self.schema5Constraints.count, .invalidSchema)
        for row in constraints {
            guard row.count == 4, let expected = Self.schema5Constraints[row[0]] else { throw NASError.invalidSchema }
            try require(row[2] == "t" && row[3] == "t" && Self.definition(row[1]) == Self.definition(expected), .invalidSchema)
        }
        // validateSchema4 verifies the complete eight-function namespace, including these
        // exact bodies and attributes, before any recheck below can execute those functions.
        try require(try rows("SELECT NOT EXISTS(SELECT 1 FROM macnas.capacity_scopes s WHERE macnas.valid_capacity_scope(s) IS NOT TRUE) AND NOT EXISTS(SELECT 1 FROM macnas.capacity_allocations a WHERE macnas.valid_capacity_allocation(a) IS NOT TRUE);") == [["t"]], .invalidSchema)
        let indexes = try rows("SELECT i.relname,x.indisvalid,x.indisready FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid WHERE x.indrelid IN (\(relationIDs)) ORDER BY i.relname;")
        let names = ["capacity_allocations_idempotency_unique","capacity_allocations_pkey","capacity_scopes_pkey","capacity_scopes_scope_unique"]
        try require(indexes == names.map { [$0,"t","t"] }, .invalidSchema)
        try require(try rows("SELECT count(*) FROM pg_trigger WHERE tgrelid IN (\(relationIDs)) AND NOT tgisinternal;") == [["0"]], .invalidSchema)
        try require(try rows("""
        SELECT (SELECT count(*) FROM macnas.capacity_scopes)<=1
          AND (SELECT count(*) FROM macnas.capacity_allocations)<=64
          AND (SELECT count(*) FROM macnas.capacity_allocations WHERE state IN ('reserved','armed'))<=8
          AND NOT EXISTS(SELECT 1 FROM macnas.capacity_scopes s WHERE
            (SELECT coalesce(sum(declared_bytes),0) FROM macnas.capacity_allocations a WHERE a.scope_id=s.scope_id AND a.state<>'cancelled')>s.byte_limit);
        """) == [["t"]], .invalidSchema)
        for app in SampleApp.allCases {
            let role = try Self.quote(app.role(database: databaseName))
            let permissions = tables.map { "has_table_privilege(r.oid,'macnas.\($0)','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')" }.joined(separator: " OR ")
            try require(try rows("SELECT NOT EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname=\(role) AND (\(permissions)));") == [["t"]], .denied)
        }
    }
}
