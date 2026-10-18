import XCTest

@testable import WallpaperMachine

@MainActor
final class SystemMediaEventCodecTests: XCTestCase {
    func testPropertiesKeepOptionalFieldsAndSortKeys() throws {
        let json = try XCTUnwrap(
            SystemMediaEventCodec.json(
                for: .properties(
                    SystemMediaProperties(
                        title: "Track", artist: "Artist", subTitle: "shown",
                        albumTitle: "Album", albumArtist: "Album artist", genres: "Jazz",
                        contentType: "music"))))
        XCTAssertTrue(json.contains("\"subTitle\":\"shown\""))
        XCTAssertTrue(json.contains("\"albumArtist\":\"Album artist\""))
        XCTAssertTrue(json.contains("\"genres\":\"Jazz\""))
        XCTAssertEqual(
            json,
            #"{"albumArtist":"Album artist","albumTitle":"Album","artist":"Artist","contentType":"music","genres":"Jazz","subTitle":"shown","title":"Track","type":"mediaPropertiesChanged"}"#)
    }

    func testThumbnailColoursAreUnitVectors() throws {
        let json = try XCTUnwrap(
            SystemMediaEventCodec.json(
                for: .thumbnail(
                    SystemMediaThumbnail(
                        pngBase64DataURL: "data:image/png;base64,AA==",
                        primaryColor: "rgb(255, 0, 0)",
                        secondaryColor: "rgb(0, 128, 0)",
                        tertiaryColor: "rgb(0, 0, 64)",
                        textColor: "rgb(255, 255, 255)",
                        highContrastColor: "rgb(0, 0, 0)",
                        rgba: [1, 2, 3, 4],
                        width: 1,
                        height: 1))))
        XCTAssertTrue(json.contains("\"primaryColor\":[1,0,0]"))
        XCTAssertTrue(json.contains("\"highContrastColor\":[0,0,0]"))
        XCTAssertTrue(json.contains("\"secondaryColor\""))
        XCTAssertTrue(json.contains("\"tertiaryColor\""))
        XCTAssertFalse(json.contains("pngBase64DataURL"))
    }

    func testPlaybackUsesSceneScriptMediaPlaybackEventNumbers() throws {
        XCTAssertEqual(
            SystemMediaEventCodec.json(for: .playback(.stopped)),
            #"{"state":0,"type":"mediaPlaybackChanged"}"#)
        XCTAssertEqual(
            SystemMediaEventCodec.json(for: .playback(.playing)),
            #"{"state":1,"type":"mediaPlaybackChanged"}"#)
        XCTAssertEqual(
            SystemMediaEventCodec.json(for: .playback(.paused)),
            #"{"state":2,"type":"mediaPlaybackChanged"}"#)
    }

    func testEmptyArtworkExplicitlyClearsThumbnailFlag() throws {
        let json = try XCTUnwrap(SystemMediaEventCodec.json(for: .thumbnail(.empty)))
        XCTAssertTrue(json.contains("\"hasThumbnail\":false"))
    }
}
