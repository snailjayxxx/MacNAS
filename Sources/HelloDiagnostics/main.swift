import Foundation
import Darwin
if CommandLine.arguments.contains("--simulate-crash") { exit(70) }
if CommandLine.arguments.contains("--simulate-hang") { Thread.sleep(forTimeInterval: 30) }
if CommandLine.arguments.contains("--simulate-output-flood") { try FileHandle.standardOutput.write(contentsOf: Data(repeating:65,count:131072)); exit(0) }
let report = ["id": "hello-diagnostics", "health": "healthy", "scope": "self-only", "os": ProcessInfo.processInfo.operatingSystemVersionString, "seesDatabaseConfiguration": String(ProcessInfo.processInfo.environment["MACNAS_PG_SOCKET"] != nil), "seesExportSigningKey": String(ProcessInfo.processInfo.environment["MACNAS_TEST_EXPORT_SIGNING_KEY"] != nil)]
let data = try JSONEncoder().encode(report)
print(String(decoding: data, as: UTF8.self))
