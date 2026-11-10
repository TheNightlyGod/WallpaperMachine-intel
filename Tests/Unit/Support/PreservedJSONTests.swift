import XCTest
@testable import WallpaperMachine

final class PreservedJSONTests: XCTestCase {
    private struct Entry: Codable, Equatable {
        var name: String
        var count: Int
    }

    func testAValueThatDecodesWholeIsReadAndWrittenAsTheCodersDo() throws {
        let values = ["a": Entry(name: "one", count: 1), "b": Entry(name: "two", count: 2)]
        let data = try JSONEncoder().encode(values)

        let read = try XCTUnwrap(PreservedJSON.readObject(data, as: Entry.self))
        XCTAssertEqual(read.values, values)
        XCTAssertTrue(read.unread.isEmpty)
        XCTAssertEqual(
            try JSONDecoder().decode([String: Entry].self, from: PreservedJSON.writeObject(values, keeping: [:])), values)
        XCTAssertEqual(try JSONDecoder().decode([Entry].self, from: PreservedJSON.writeArray(Array(values.values), keeping: [])).count, 2)
    }

    func testAnEntryThatDoesNotDecodeOrIsRefusedIsSetAsideAndWrittenBack() throws {
        let data = Data(#"{"good":{"name":"one","count":1},"odd":{"name":"two","count":"many","deep":[1,2,{"x":null}]},"big":{"name":"three","count":99}}"#.utf8)

        let read = try XCTUnwrap(PreservedJSON.readObject(data, as: Entry.self) { _, entry in entry.count < 10 })
        XCTAssertEqual(read.values, ["good": Entry(name: "one", count: 1)])
        XCTAssertEqual(Set(read.unread.keys), ["odd", "big"])

        var values = read.values
        values["good"]?.count = 5
        let written = try PreservedJSON.writeObject(values, keeping: read.unread)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? NSDictionary)
        XCTAssertEqual(after["odd"] as? NSDictionary, original["odd"] as? NSDictionary)
        XCTAssertEqual(after["big"] as? NSDictionary, original["big"] as? NSDictionary)
        XCTAssertEqual((after["good"] as? NSDictionary)?["count"] as? Int, 5)
    }

    func testAKeyGivenAValueReplacesWhatWasSetAsideForIt() throws {
        let unread = ["odd": Data(#"{"name":2}"#.utf8)]
        let written = try PreservedJSON.writeObject(["odd": Entry(name: "now", count: 3)], keeping: unread)
        XCTAssertEqual(try JSONDecoder().decode([String: Entry].self, from: written), ["odd": Entry(name: "now", count: 3)])
    }

    func testArrayElementsKeepTheirOrderAndTheUnreadOnesFollow() throws {
        let data = Data(#"[{"name":"one","count":1},"stray",{"name":"two","count":2},{"name":3}]"#.utf8)

        let read = try XCTUnwrap(PreservedJSON.readArray(data, as: Entry.self))
        XCTAssertEqual(read.values, [Entry(name: "one", count: 1), Entry(name: "two", count: 2)])
        XCTAssertEqual(read.unread.count, 2)

        let written = try PreservedJSON.writeArray(read.values, keeping: read.unread)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [Any])
        XCTAssertEqual(after.count, 4)
        XCTAssertEqual(after[2] as? String, "stray")
        XCTAssertEqual((after[3] as? [String: Int])?["name"], 3)
    }

    func testAValueOfAnotherShapeIsNotRead() {
        XCTAssertNil(PreservedJSON.readObject(Data("not JSON".utf8), as: Entry.self))
        XCTAssertNil(PreservedJSON.readObject(Data("[1,2]".utf8), as: Entry.self))
        XCTAssertNil(PreservedJSON.readArray(Data(#"{"a":1}"#.utf8), as: Entry.self))
    }
}
