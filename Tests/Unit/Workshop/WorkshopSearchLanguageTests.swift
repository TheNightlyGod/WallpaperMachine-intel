import XCTest

@testable import WallpaperMachine

/// Which language a Workshop search reads as: Chinese in either script, Japanese with or without
/// kana, Korean, Portuguese only while the app is in Portuguese, and never English.
final class WorkshopSearchLanguageTests: XCTestCase {
    private let english = AppLanguage.english
    private var portuguese: AppLanguage { AppLanguage.named("pt-BR")! }

    private func detected(_ text: String, app: AppLanguage? = nil) -> String? {
        WorkshopSearchLanguage.detect(text, app: app ?? english)?.tag
    }

    func testSimplifiedAndTraditionalChineseAreToldApartByTheirCharacters() {
        for text in ["风景", "动漫女孩", "壁纸", "电脑", "猫"] {
            XCTAssertEqual(detected(text), "zh-Hans", text)
        }
        // The recognizer alone calls some of these Simplified, or short Simplified titles
        // Traditional; the characters decide.
        for text in ["風景", "動漫女孩", "壁紙", "電腦", "龍"] {
            XCTAssertEqual(detected(text), "zh-Hant", text)
        }
    }

    func testJapaneseIsReadFromKanaAndFromKanjiTheRecognizerIsSureOf() {
        for text in ["初音ミク", "雨の街", "可愛い", "さくら"] {
            XCTAssertEqual(detected(text), "ja", text)
        }
        // 桜 is the Japanese form (Chinese writes 樱 or 櫻): kanji alone, but plainly Japanese.
        XCTAssertEqual(detected("桜"), "ja")
        // Kanji that Chinese writes the same way is read as Chinese unless the recognizer is sure.
        XCTAssertEqual(detected("宇宙"), "zh-Hans")
    }

    func testKoreanIsReadFromHangul() {
        for text in ["고양이", "풍경", "애니메이션"] {
            XCTAssertEqual(detected(text), "ko", text)
        }
    }

    func testMixedTextIsReadByItsCJKCharacters() {
        XCTAssertEqual(detected("anime 女孩"), "zh-Hans")
        XCTAssertEqual(detected("hatsune miku 初音ミク"), "ja")
        XCTAssertEqual(detected("4K 고양이"), "ko")
    }

    func testEnglishAndTextWithNoLanguageAreNotRead() {
        for text in ["anime girl", "rain", "cyberpunk 2077", "na", "2077", "!!!", "", "кошка"] {
            XCTAssertNil(detected(text), text)
            XCTAssertNil(detected(text, app: portuguese), text)
        }
        // A name the recognizer takes for Portuguese is still English text in an English app.
        XCTAssertNil(detected("Totoro"))
    }

    func testPortugueseIsReadOnlyWhileTheAppIsInPortuguese() {
        for text in ["gato preto", "paisagem", "noite estrelada", "carro esportivo"] {
            XCTAssertEqual(detected(text, app: portuguese), "pt-BR", text)
            XCTAssertNil(detected(text), "\(text) is searched as typed while the app is in English")
        }
        XCTAssertEqual(
            WorkshopSearchLanguage.candidates(app: english).map(\.tag), ["zh-Hans", "zh-Hant", "ja", "ko"])
        XCTAssertEqual(
            WorkshopSearchLanguage.candidates(app: portuguese).map(\.tag),
            ["zh-Hans", "zh-Hant", "ja", "ko", "pt-BR"])
    }
}
