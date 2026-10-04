import Foundation
import XCTest
@testable import PiksCore

private actor WorkCounter {
    var active = 0
    var maximum = 0
    var starts = 0
    func enter() { active += 1; starts += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
    func summary() -> (Int, Int, Int) { (active, maximum, starts) }
}

final class MediaGateTests: XCTestCase {
    func testSeveralMediaJobsNeverRunMoreThanOneEncoder() async throws {
        let gate = MediaWorkGate(), counter = WorkCounter()
        let jobs = (0..<8).map { _ in
            Task { try await gate.withPermit {
                await counter.enter()
                try await Task.sleep(nanoseconds: 5_000_000)
                await counter.leave()
            } }
        }
        for job in jobs { try await job.value }
        let result = await counter.summary()
        XCTAssertEqual(result.0, 0); XCTAssertEqual(result.1, 1); XCTAssertEqual(result.2, 8)
    }
    func testCancelledWaitingJobDoesNotRunOrBlockFollowingJob() async throws {
        let gate = MediaWorkGate(), counter = WorkCounter()
        let first = Task { try await gate.withPermit {
            await counter.enter(); try await Task.sleep(nanoseconds: 100_000_000); await counter.leave()
        } }
        while await counter.summary().2 == 0 { await Task.yield() }
        let cancelled = Task { try await gate.withPermit { await counter.enter(); await counter.leave() } }
        try await Task.sleep(nanoseconds: 5_000_000); cancelled.cancel()
        let last = Task { try await gate.withPermit { await counter.enter(); await counter.leave() } }
        try await first.value
        do { try await cancelled.value; XCTFail("Cancelled queued work must not run") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await last.value
        let result = await counter.summary()
        XCTAssertEqual(result.0, 0); XCTAssertEqual(result.1, 1); XCTAssertEqual(result.2, 2)
    }
    func testFailedJobReleasesItsEncoderPermit() async throws {
        enum FixtureError: Error { case failed }
        let gate = MediaWorkGate()
        do { try await gate.withPermit { throw FixtureError.failed }; XCTFail("Expected failure") } catch FixtureError.failed {}
        let value = try await gate.withPermit { 42 }
        XCTAssertEqual(value, 42)
    }
}
