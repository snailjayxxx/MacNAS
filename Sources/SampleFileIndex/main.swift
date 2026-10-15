import Foundation
import Darwin
import MacNASCore
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2, args[0] == "--granted-synthetic-root" else { throw NASError.denied }
    let entries = try SampleFileIndex.inspect(root: URL(fileURLWithPath: args[1], isDirectory: true))
    print(String(decoding: try JSONEncoder().encode(entries), as: UTF8.self))
} catch { fputs("sample-file-index: denied or invalid synthetic input\n", stderr); exit(1) }
