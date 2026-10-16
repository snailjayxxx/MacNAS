import Foundation
import XCTest
@testable import MacNASCore

final class FileTransferPipeTests:FileOperationLab {
    func testActualClientTransfersBinaryEmptyAndCancelledFilesAndObservesMaskedPublication() throws {
        let c=try context();try c.api.authorizeFixtureLibraryUploads(libraryID:c.reference.libraryID,session:c.owner)
        let host=try DesktopBridge(api:c.api,session:c.owner);defer{host.close()}
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
        process.executableURL=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_NODE_BINARY"]))
        process.arguments=[repo.appendingPathComponent("scripts/test_file_transfers_bridge.cjs").path,c.reference.libraryID]
        process.currentDirectoryURL=repo;process.environment=["LANG":"C","LC_ALL":"C","HOME":lab.path]
        process.standardInput=input;process.standardOutput=output;process.standardError=errors
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global());timer.schedule(deadline:.now()+180)
        timer.setEventHandler{if process.isRunning{process.terminate()}};timer.resume()
        defer{timer.cancel();if process.isRunning{process.terminate()};try? input.fileHandleForWriting.close()}
        try process.run();var frame=Data(),requests=0
        while true {
            let block=output.fileHandleForReading.availableData;if block.isEmpty{break};frame.append(block)
            try require(frame.count<=65536,.budgetExceeded)
            while let end=frame.firstIndex(of:10) {
                requests+=1;try require(requests<=64,.budgetExceeded)
                let reply=host.handle(Data(frame[..<end]));frame.removeSubrange(...end)
                try input.fileHandleForWriting.write(contentsOf:reply+Data([10]))
            }
        }
        process.waitUntilExit();let diagnostics=try errors.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertTrue(frame.isEmpty);XCTAssertEqual(process.terminationStatus,0,String(decoding:diagnostics,as:UTF8.self))
        XCTAssertGreaterThan(requests,30);XCTAssertTrue(String(decoding:diagnostics,as:UTF8.self).contains("file-transfers-pipe: PASS"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:c.library.path)),["a.txt","empty.bin","lost.bin","中日.bin"])
        XCTAssertEqual(try Data(contentsOf:c.library.appendingPathComponent("中日.bin")),Data((0..<70001).map{UInt8($0%251)}))
        XCTAssertEqual(try Data(contentsOf:c.library.appendingPathComponent("lost.bin")),Data("data".utf8))
        XCTAssertEqual(try Data(contentsOf:c.library.appendingPathComponent("empty.bin")).count,0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:c.api.root.appendingPathComponent("host-binding/transfer-staging").path),[])
    }
}
