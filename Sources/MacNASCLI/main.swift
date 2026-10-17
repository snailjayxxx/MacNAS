import Foundation
import Darwin
import MacNASCore
import CryptoKit

func json<T: Encodable>(_ value: T) throws {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try e.encode(value), as: UTF8.self))
}
func path(_ value: String) -> URL { URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL }
let usage = """
MacNAS 0.1 synthetic prototype (no listener or system services)
  macnas capabilities [--mock-os 15|26]
  macnas fixture create --dest PATH [--schema 1|2|3|4]
  macnas fixture capacity-crash-probe --source TESTLAB-PATH --stop-after reserved|armed|afterPublish|owned --confirm-synthetic-effect
  macnas fixture recycle-crash-probe --source TESTLAB-PATH --path RELATIVE-FILE --stop-after beforeRename|afterRename|observed --confirm-synthetic-effect
  macnas fixture restore-crash-probe --source TESTLAB-PATH --entry UUID --parent RELATIVE-DIRECTORY --name NAME --stop-after beforeRename|afterRename|observed --confirm-synthetic-effect --confirm-synthetic-destination
  macnas doctor --portable PATH                 verifies exported fixture, read only
  macnas migrate preview --source PATH          live synthetic fixture, read only
  macnas migrate export --source PATH --dest PATH
  macnas migrate restore --source PATH --dest PATH [--confirm-create --host-id LOGICAL-ID]
  macnas migrate upgrade --source PATH --dest PATH [--target-schema 2|3|4|5|6 --confirm-create --host-id ID]
  macnas migrate status --dest PATH
  macnas migrate rollback --dest PATH [--confirm]
  macnas migrate cutover                        unavailable, always refuses
  macnas jobs demo --source PATH               fixture sessions only; schema 3/4
  macnas jobs work-once --source PATH          trusted synthetic jobs only
  macnas bridge fixture --source PATH --user LOGICAL-ID [--approve-synthetic-recycle-observation] [--approve-synthetic-capacity-ledger-read]    schema 3/4/5/6, stdin/stdout JSON only
  macnas storage demo --source PATH            creates and reads synthetic files only
  macnas photo-smoke --dest NEW-DIRECTORY        generates synthetic images only
"""
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args == ["--help"] { print(usage); exit(0) }
    func option(_ name: String) throws -> String {
        guard let i = args.firstIndex(of: name), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw NASError.invalidSchema }
        return args[i + 1]
    }
    func checkOptions(prefix: Int, valued: Set<String>, flags: Set<String> = []) throws {
        var i = prefix; var seen: Set<String> = []
        while i < args.count {
            let arg = args[i]
            guard seen.insert(arg).inserted else { throw NASError.invalidSchema }
            if flags.contains(arg) { i += 1 }
            else if valued.contains(arg) { _ = try option(arg); i += 2 }
            else { throw NASError.invalidSchema }
        }
    }
    if args == ["fixture", "signing-key"] {
        let key = Curve25519.Signing.PrivateKey()
        try json(["private": key.rawRepresentation.base64EncodedString(), "public": key.publicKey.rawRepresentation.base64EncodedString()])
    } else if args[0] == "capabilities" {
        try checkOptions(prefix: 1, valued: ["--mock-os"])
        if args.contains("--mock-os") {
            guard let os = Int(try option("--mock-os")) else { throw NASError.invalidSchema }
            try json(MockCapabilityProbe(osMajor: os).inspect())
        } else { try json(BasicHostProbe().inspect()) }
    } else if args.prefix(2) == ["fixture", "create"] {
        try checkOptions(prefix: 2, valued: ["--dest","--schema"])
        let schema=args.contains("--schema") ? Int(try option("--schema")) : 1
        guard let schema else { throw NASError.invalidSchema }
        try PortableInstance.createSynthetic(at: path(option("--dest")),databaseVersion:schema)
        try json(["status": "created-synthetic-fixture"])
    } else if args.prefix(2) == ["fixture", "capacity-crash-probe"] {
        try checkOptions(prefix:2,valued:["--source","--stop-after"],flags:["--confirm-synthetic-effect"])
        try json(SyntheticPhysicalCapacityCrashProbe.run(root:path(option("--source")),stopAfter:option("--stop-after"),
            confirmed:args.contains("--confirm-synthetic-effect")))
    } else if args.prefix(2) == ["fixture", "recycle-crash-probe"] {
        try checkOptions(prefix: 2, valued: ["--source", "--path", "--stop-after"], flags: ["--confirm-synthetic-effect"])
        try json(SyntheticRecycleCrashProbe.run(root: path(option("--source")), path: option("--path"),
            stopAfter: option("--stop-after"), confirmed: args.contains("--confirm-synthetic-effect")))
    } else if args.prefix(2) == ["fixture", "restore-crash-probe"] {
        try checkOptions(prefix: 2, valued: ["--source", "--entry", "--parent", "--name", "--stop-after"],
            flags: ["--confirm-synthetic-effect", "--confirm-synthetic-destination"])
        guard let entry = UUID(uuidString: try option("--entry")) else { throw NASError.invalidSchema }
        try json(SyntheticRecycleCrashProbe.restore(root: path(option("--source")), entryID: entry, parentPath: option("--parent"),
            name: option("--name"), stopAfter: option("--stop-after"), confirmed: args.contains("--confirm-synthetic-effect"),
            destinationConfirmed: args.contains("--confirm-synthetic-destination")))
    } else if args.prefix(2) == ["jobs","work-once"] {
        try checkOptions(prefix:2,valued:["--source","--lease-seconds","--synthetic-test-hold-after"])
        let root=path(try option("--source")),queue=try DurableJobQueue(store:PortableInstance.store(root))
        let seconds=args.contains("--lease-seconds") ? Double(try option("--lease-seconds")) : 5
        guard let seconds else { throw NASError.invalidSchema }
        let hold=args.contains("--synthetic-test-hold-after") ? try option("--synthetic-test-hold-after") : ""
        guard ["","claimed","prepared","completed"].contains(hold) else { throw NASError.invalidSchema }
        func checkpoint(_ point:String) throws {
            if hold==point {
                try Data(point.utf8).write(to:root.appendingPathComponent("host-binding/job-test-checkpoint"),options:.atomic)
                while true { Thread.sleep(forTimeInterval:0.05) }
            }
        }
        if let lease=try queue.claim(leaseSeconds:seconds) {
            try checkpoint("claimed");try queue.prepare(lease);try checkpoint("prepared")
            try queue.finish(lease);try checkpoint("completed")
            try json(["status":"completed","jobID":lease.job.id])
        } else { try json(["status":"idle"]) }
    } else if args.prefix(2) == ["jobs","demo"] {
        try checkOptions(prefix:2,valued:["--source"])
        let root=path(try option("--source")),api=try PrototypePlatformAPI(root:root)
        let session=try api.beginFixtureSession(userID:"fixture-owner")
        _=try api.submitLabelJob(id:"durable-demo",key:"durable-demo",label:"durable-label",value:"任务・ジョブ",session:session)
        let queue=try DurableJobQueue(store:PortableInstance.store(root));_=try queue.workOne()
        let events=try api.jobEvents(consumerID:"demo-consumer",session:session)
        if let last=events.last { try api.acknowledgeJobEvents(consumerID:"demo-consumer",through:last.sequence,session:session) }
        try json(try api.durableJobs(session:session))
    } else if args.prefix(2) == ["bridge", "fixture"] {
        try checkOptions(prefix: 2, valued: ["--source", "--user"], flags: ["--approve-synthetic-recycle-observation", "--approve-synthetic-capacity-ledger-read"])
        try DesktopBridgeCLI.run(root: path(option("--source")), fixtureUser: option("--user"),
            recycleObservationConfirmed: args.contains("--approve-synthetic-recycle-observation"),
            capacityLedgerReadConfirmed: args.contains("--approve-synthetic-capacity-ledger-read"))
    } else if args.prefix(2) == ["storage", "demo"] {
        try checkOptions(prefix: 2, valued: ["--source"])
        try json(FixtureStorageDemo.run(root: path(option("--source"))))
    } else if args[0] == "doctor" {
        try checkOptions(prefix: 1, valued: ["--portable"])
        try json(PortableInstance.verify(path(option("--portable"))))
    } else if args[0] == "photo-smoke" {
        try checkOptions(prefix: 1, valued: ["--dest"])
        try json(PhotoSmoke.run(outputDirectory: path(option("--dest"))))
    } else if args.count >= 2 && args[0] == "migrate" {
        switch args[1] {
        case "preview":
            try checkOptions(prefix: 2, valued: ["--source"])
            try json(PortableInstance.preview(path(option("--source"))))
        case "export":
            try checkOptions(prefix: 2, valued: ["--source", "--dest"])
            try json(PortableInstance.export(from: path(option("--source")), to: path(option("--dest"))))
        case "restore":
            try checkOptions(prefix: 2, valued: ["--source", "--dest", "--host-id", "--synthetic-test-hold-after"], flags: ["--confirm-create"])
            let host = args.contains("--host-id") ? try option("--host-id") : "mock-new-host"
            if args.contains("--synthetic-test-hold-after") {
                guard args.contains("--confirm-create"), let point = MigrationCheckpoint(rawValue: try option("--synthetic-test-hold-after")) else { throw NASError.invalidSchema }
                let destination = path(try option("--dest"))
                let hook: (MigrationCheckpoint) -> Void = { checkpoint in
                    if checkpoint == point {
                        let marker = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).macnas-test-checkpoint")
                        try? Data(point.rawValue.utf8).write(to: marker, options: .atomic)
                        while true { Thread.sleep(forTimeInterval: 0.05) }
                    }
                }
                try json(MigrationCoordinator.restore(from:path(option("--source")),to:destination,hostID:host,checkpoint:hook))
            } else {
                try json(PortableInstance.restore(from: path(option("--source")), to: path(option("--dest")), hostID: host, confirmCreate: args.contains("--confirm-create")))
            }
        case "upgrade":
            try checkOptions(prefix:2,valued:["--source","--dest","--host-id","--target-schema"],flags:["--confirm-create"])
            let version = args.contains("--target-schema") ? Int(try option("--target-schema")) : 2
            guard let version,[2,3,4,5,6].contains(version) else { throw NASError.unsupported }
            let source = path(try option("--source")), destination = path(try option("--dest"))
            if args.contains("--confirm-create") {
                let host = args.contains("--host-id") ? try option("--host-id") : "mock-upgrade-host"
                try json(MigrationCoordinator.upgrade(from:source,to:destination,hostID:host,targetVersion:version))
            } else { try json(PortableInstance.preview(source)) }
        case "status":
            try checkOptions(prefix:2,valued:["--dest"])
            try json(MigrationCoordinator.status(destination:path(option("--dest"))))
        case "rollback":
            try checkOptions(prefix:2,valued:["--dest"],flags:["--confirm"])
            try json(MigrationCoordinator.rollback(destination:path(option("--dest")),confirm:args.contains("--confirm")))
        case "cutover": try PortableInstance.cutover()
        default: throw NASError.unsupported
        }
    } else { throw NASError.invalidSchema }
} catch {
    // Do not echo user paths, tokens, SQL or arbitrary exception messages.
    let code = (error as? NASError)?.rawValue ?? "invalidInputOrIO"
    fputs("macnas: \(code)\n", stderr)
    exit(1)
}
