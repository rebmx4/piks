import XCTest
import Foundation

final class MediaDiagnosticsTests: XCTestCase {
    private let meta: [String: Any] = ["v": 1, "session": "abcdefgh23", "device": "beyd9q",
                                     "site": "ryn-next", "ver": "20261101-test", "commit": "478b92b"]
    private let origin = URL(string: "https://rynpro.ru/ryn-next/")!
    private func enable(_ state: MediaDiagnosticsState) {
        XCTAssertTrue(state.configure(meta, origin: origin, mainFrame: true, allowed: true), "origin path: \(origin.path)")
    }
    private func body(_ batch: MediaDiagnosticsState.Batch?) throws -> [String: Any] {
        let batch = try XCTUnwrap(batch)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: batch.data) as? [String: Any])
    }
    private func records(_ body: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(body["lines"] as? [[String: Any]]).map { line in
            let text = try XCTUnwrap(line["text"] as? String)
            let json = try XCTUnwrap(text.range(of: "{" )).lowerBound
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[json...].utf8)) as? [String: Any])
        }
    }

    func testOnlyTrustedTestMainFrameCanEnable() {
        for (url, main, allowed) in [
            ("https://rynpro.ru/ryn/", true, true), ("https://example.com/ryn-next/", true, true),
            ("http://rynpro.ru/ryn-next/", true, true), (origin.absoluteString, false, true),
            (origin.absoluteString, true, false), ("https://rynpro.ru:444/ryn-next/", true, true)
            , ("https://rynpro.ru/ryn-next-wrong/", true, true)
        ] {
            let state = MediaDiagnosticsState(build: "42")
            XCTAssertFalse(state.configure(meta, origin: URL(string: url), mainFrame: main, allowed: allowed))
            state.record(["op": "player.play"])
            XCTAssertNil(state.takeBatch()); XCTAssertNil(state.tick())
        }
        let state = MediaDiagnosticsState(build: "42"); enable(state)
        XCTAssertNotNil(state.takeBatch())
    }

    func testIndependentSessionAndTechnicalFieldsOnly() throws {
        let state = MediaDiagnosticsState(build: "42"); enable(state)
        state.record(["op": "audio.resume", "phase": "begin", "id": 9, "attempt": 2,
                      "state": "suspended", "url": "SECRET", "reason": "SECRET", "t": 4.079])
        state.record(["op": "SECRET", "t": 1])
        let batch = try XCTUnwrap(state.takeBatch()), result = try body(batch)
        XCTAssertEqual(result["device"] as? String, "beyd9q")
        XCTAssertEqual(result["site"] as? String, "ryn-next")
        let session = try XCTUnwrap(result["session"] as? String)
        XCTAssertNotEqual(session, meta["session"] as? String)
        XCTAssertNotNil(session.range(of: "^[a-z0-9]{4,32}$", options: .regularExpression))
        XCTAssertFalse(String(decoding: batch.data, as: UTF8.self).contains("SECRET"))
        let rows = try records(result)
        XCTAssertEqual(rows.first?["web"] as? String, "abcdefgh23")
        XCTAssertEqual(rows.last?["attempt"] as? Int, 2)
        XCTAssertEqual(rows.last?["t"] as? Double, 4.079)
    }

    func testNoJavaScriptStillProducesHealthAndOnlyOneOutstandingMainPing() throws {
        var now = 0.0
        let state = MediaDiagnosticsState(build: "42", now: { now }, wall: { 100000 + now })
        enable(state)
        let first = try XCTUnwrap(state.tick())
        now = 11000
        XCTAssertNil(state.tick(), "a blocked main queue must not accumulate ping blocks")
        let rows = try records(body(state.takeBatch()))
        let health = try XCTUnwrap(rows.last { $0["op"] as? String == "health" })
        XCTAssertEqual(health["webGapMs"] as? Int, 11000)
        XCTAssertEqual(health["mainGapMs"] as? Int, 11000)
        state.mainReplied(first)
        state.heartbeat(session: "abcdefgh23", hidden: false)
        now += 2000
        XCTAssertNotNil(state.tick())
        let recovered = try XCTUnwrap(try records(body(state.takeBatch())).last { $0["op"] as? String == "health" })
        XCTAssertEqual(recovered["mainLastMs"] as? Int, 11000)
    }

    func testForegroundMainStillRespondsWhileWebIsBlocked() throws {
        var now = 0.0
        let state = MediaDiagnosticsState(build: "42", now: { now }); enable(state)
        for _ in 0..<6 {
            if let ping = state.tick() { state.mainReplied(ping) }
            now += 2000
        }
        let health = try XCTUnwrap(try records(body(state.takeBatch())).last { $0["op"] as? String == "health" })
        XCTAssertGreaterThanOrEqual(health["webGapMs"] as? Int ?? 0, 10000)
        XCTAssertEqual(health["mainGapMs"] as? Int, 0)
    }

    func testBackgroundAndHiddenPageDoNotBecomeFalseHangReports() throws {
        var now = 0.0
        let state = MediaDiagnosticsState(build: "42", now: { now }); enable(state)
        state.setForeground(false); now += 60000
        XCTAssertNil(state.tick())
        state.setForeground(true)
        state.heartbeat(session: "abcdefgh23", hidden: true); now += 60000
        XCTAssertNil(state.tick())
        state.heartbeat(session: "abcdefgh23", hidden: false)
        XCTAssertNotNil(state.tick())
        let health = try XCTUnwrap(try records(body(state.takeBatch())).last { $0["op"] as? String == "health" })
        XCTAssertEqual(health["webGapMs"] as? Int, 0)
    }

    func testQueueAndBatchStayBoundedAndFailedUploadKeepsRecords() throws {
        let state = MediaDiagnosticsState(build: "42"); enable(state)
        for i in 0..<10000 { state.record(["op": "audio.resume", "id": i, "phase": "return", "ms": 10]) }
        let first = try XCTUnwrap(state.takeBatch()), result = try body(first)
        XCTAssertLessThan(first.data.count, 64000)
        XCTAssertGreaterThan(result["dropped"] as? Int ?? 0, 0)
        XCTAssertEqual(try XCTUnwrap(state.takeBatch()).to, first.to, "unacknowledged records remain")
        var total = 0
        while let batch = state.takeBatch() {
            total += try XCTUnwrap(body(batch)["lines"] as? [[String: Any]]).count
            state.acknowledge(batch)
        }
        XCTAssertLessThanOrEqual(total, 128)
    }

    func testLateUploadAndPingCannotAffectNewSession() throws {
        let state = MediaDiagnosticsState(build: "42"); enable(state)
        let old = try XCTUnwrap(state.takeBatch()), ping = try XCTUnwrap(state.tick())
        state.stop(); XCTAssertNil(state.tick()); XCTAssertNil(state.takeBatch())
        enable(state)
        state.acknowledge(old); state.mainReplied(ping)
        let fresh = try XCTUnwrap(state.takeBatch())
        XCTAssertNotEqual(try body(old)["session"] as? String, try body(fresh)["session"] as? String)
        XCTAssertNotNil(state.tick())
    }

    func testWrongSessionHeartbeatDoesNotHideStall() throws {
        var now = 0.0
        let state = MediaDiagnosticsState(build: "42", now: { now }); enable(state)
        now = 11000; state.heartbeat(session: "oldsession", hidden: false)
        _ = state.tick()
        let health = try XCTUnwrap(try records(body(state.takeBatch())).last { $0["op"] as? String == "health" })
        XCTAssertEqual(health["webGapMs"] as? Int, 11000)
    }

    func testReturningToForegroundCanDetectAWebPageThatNeverResumes() throws {
        var now = 0.0
        let state = MediaDiagnosticsState(build: "42", now: { now }); enable(state)
        state.heartbeat(session: "abcdefgh23", hidden: true)
        state.setForeground(false); now += 60000
        state.setForeground(true)
        let ping = try XCTUnwrap(state.tick())
        state.mainReplied(ping)
        now += 11000; _ = state.tick()
        let health = try XCTUnwrap(try records(body(state.takeBatch())).last { $0["op"] as? String == "health" })
        XCTAssertEqual(health["webGapMs"] as? Int, 11000)
        XCTAssertEqual(health["mainGapMs"] as? Int, 0)
    }

    func testNativeAndWebShareOneAnonymousRunWithoutLeakingRequestIDs() throws {
        let state = MediaDiagnosticsState(build: "42"); enable(state)
        state.bindContext(requestId: "request-1", run: 9, attempt: 1, command: "play-start")
        state.bindContext(requestId: "request-1", run: 9, attempt: 2, command: "play-pause")
        state.record(["op": "received.play-pause", "requestId": "request-1"])
        state.record(["op": "native.play-started", "requestId": "request-1"])
        state.record(["op": "native.play-paused", "requestId": "request-1"])
        let batch = try XCTUnwrap(state.takeBatch()), rows = try records(body(batch))
        XCTAssertEqual(rows.suffix(3).compactMap { $0["run"] as? Int }, [9, 9, 9])
        XCTAssertEqual(rows.suffix(3).compactMap { $0["attempt"] as? Int }, [2, 1, 2])
        XCTAssertFalse(String(decoding: batch.data, as: UTF8.self).contains("request-1"))
        state.record(["op": "native.play-started", "requestId": "unknown"])
        XCTAssertEqual(try records(body(state.takeBatch())).last?["correlated"] as? Bool, false)
    }
}
