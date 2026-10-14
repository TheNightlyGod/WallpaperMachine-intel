import Foundation
import XCTest
@testable import WallpaperMachine

final class LivePropertyPayloadTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testASceneDocumentFollowsTheDraftExceptTheFrozenProperties() throws {
        let started = #"{"size":10,"flag":true,"tint":"1 0 0","picture":"a.png","message":"Hi"}"#
        let latest = #"{"message":"Hello","picture":"b.png","tint":"0 1 0","flag":false,"size":25.5}"#
        let merged = try XCTUnwrap(LivePropertyPayload.merge(started: started, latest: latest, frozen: ["picture"]))
        let live = try object(merged.json)
        XCTAssertEqual(live["size"] as? Double, 25.5)
        XCTAssertEqual(live["flag"] as? Bool, false)
        XCTAssertEqual(live["tint"] as? String, "0 1 0")
        XCTAssertEqual(live["message"] as? String, "Hello")
        XCTAssertEqual(live["picture"] as? String, "a.png", "a picture is read when the scene loads, so the one it started with stays")
        XCTAssertTrue(merged.frozenChanged)
    }

    func testChangingOnlyLiveValuesLeavesTheFrozenOnesUnchanged() throws {
        let started = #"{"size":10,"picture":"a.png"}"#
        let merged = try XCTUnwrap(LivePropertyPayload.merge(started: started, latest: #"{"size":11,"picture":"a.png"}"#, frozen: ["picture"]))
        XCTAssertFalse(merged.frozenChanged)
        XCTAssertEqual(try object(merged.json)["size"] as? Double, 11)
    }

    func testAWebDocumentKeepsWholeEntriesAndFrozenFilesAsTheyStarted() throws {
        let started = #"{"choice":{"type":"combo","value":2},"pic":{"type":"file","value":"/old/a.png","fileFilter":"image"},"folder":{"type":"directory","value":"/old"}}"#
        let latest = #"{"folder":{"type":"directory","value":"/new"},"pic":{"fileFilter":"image","value":"/new/b.png","type":"file"},"choice":{"value":3,"type":"combo"}}"#
        let merged = try XCTUnwrap(LivePropertyPayload.merge(started: started, latest: latest, frozen: ["pic", "folder"]))
        let live = try object(merged.json)
        XCTAssertEqual((live["choice"] as? [String: Any])?["value"] as? Int, 3)
        XCTAssertEqual((live["pic"] as? [String: Any])?["value"] as? String, "/old/a.png")
        XCTAssertEqual((live["pic"] as? [String: Any])?["fileFilter"] as? String, "image")
        XCTAssertEqual((live["folder"] as? [String: Any])?["value"] as? String, "/old")
        XCTAssertTrue(merged.frozenChanged)
    }

    func testKeyOrderIsNotAChange() throws {
        let started = #"{"a":{"type":"file","value":"x","z":1},"b":2}"#
        let reordered = #"{"b":2,"a":{"z":1,"value":"x","type":"file"}}"#
        let merged = try XCTUnwrap(LivePropertyPayload.merge(started: started, latest: reordered, frozen: ["a"]))
        XCTAssertFalse(merged.frozenChanged)
        let again = try XCTUnwrap(LivePropertyPayload.merge(started: started, latest: started, frozen: ["a"]))
        XCTAssertEqual(merged.json, again.json, "the same state is the same text however the keys were ordered")
        XCTAssertEqual(LivePropertyPayload.canonical(reordered), merged.json)
    }

    func testAFrozenPropertyThatWasAbsentStaysAbsentAndOneThatWentAwayComesBack() throws {
        let added = try XCTUnwrap(LivePropertyPayload.merge(started: #"{"size":1}"#, latest: #"{"size":2,"pic":"p.png"}"#, frozen: ["pic"]))
        XCTAssertNil(try object(added.json)["pic"])
        XCTAssertTrue(added.frozenChanged)
        let removed = try XCTUnwrap(LivePropertyPayload.merge(started: #"{"size":1,"pic":"p.png"}"#, latest: #"{"size":2}"#, frozen: ["pic"]))
        XCTAssertEqual(try object(removed.json)["pic"] as? String, "p.png")
        XCTAssertTrue(removed.frozenChanged)
        let none = try XCTUnwrap(LivePropertyPayload.merge(started: #"{"size":1}"#, latest: #"{"size":2}"#, frozen: ["pic"]))
        XCTAssertFalse(none.frozenChanged)
    }

    func testDocumentsThatAreNotObjectsYieldNothing() {
        for bad in ["", "not json", "[1,2]", "3", "null"] {
            XCTAssertNil(LivePropertyPayload.merge(started: "{}", latest: bad, frozen: []), bad)
            XCTAssertNil(LivePropertyPayload.merge(started: bad, latest: "{}", frozen: []), bad)
            XCTAssertNil(LivePropertyPayload.canonical(bad), bad)
        }
    }
}
