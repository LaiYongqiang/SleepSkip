import Darwin
import Foundation
import XCTest
@testable import SleepSkipCore

final class CLIHookInputTests: XCTestCase {
    private func read(_ fragments: [(TimeInterval, Data)], timeout: TimeInterval = 0.5, maximumBytes: Int = 1_048_576) throws -> String? {
        let input = Pipe()
        let writer = input.fileHandleForWriting
        let done = expectation(description: "writer closes")
        DispatchQueue.global().async {
            defer { try? writer.close(); done.fulfill() }
            for (delay, bytes) in fragments {
                Thread.sleep(forTimeInterval: delay)
                try? writer.write(contentsOf: bytes)
            }
        }
        defer { wait(for: [done], timeout: 2); try? input.fileHandleForReading.close() }
        return try CLIHookInput.readSessionID(fd: input.fileHandleForReading.fileDescriptor, timeout: timeout, maximumBytes: maximumBytes)
    }

    func testReadsCompleteLargePayloadWithoutReturningPrompt() throws {
        let payload = "{\"prompt\":\"\(String(repeating: "x", count: 10_000))\",\"session_id\":\"long-id\"}"
        XCTAssertEqual(try read([(0, Data(payload.utf8))]), "long-id")
    }

    func testWaitsForDelayedAndFragmentedJSONUntilEOF() throws {
        XCTAssertEqual(try read([(0.04, Data("{\"session_".utf8)), (0.04, Data("id\":\"fragment-id\"}".utf8))]), "fragment-id")
    }

    func testEmptyEOFMeansNoPayload() throws {
        XCTAssertNil(try read([]))
    }

    func testMalformedAndMissingIdentityAreErrors() throws {
        for payload in ["{", "{}", "{\"session_id\":3}", "{\"session_id\":\" \"}"] {
            XCTAssertThrowsError(try read([(0, Data(payload.utf8))]), payload)
        }
    }

    func testOversizedInputIsRejected() throws {
        XCTAssertThrowsError(try read([(0, Data("{\"session_id\":\"oversize\"}".utf8))], maximumBytes: 10))
    }

    func testNoInputHasFiniteDeadline() throws {
        let input = Pipe()
        let start = Date()
        XCTAssertThrowsError(try CLIHookInput.readSessionID(fd: input.fileHandleForReading.fileDescriptor, timeout: 0.04))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        try input.fileHandleForWriting.close()
    }
}
