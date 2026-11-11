import Foundation
import NaturalLanguage

/// Which of the app's own languages a Workshop search was typed in, when it was not English.
///
/// Steam matches search words against titles and tags that are mostly English, so a search typed
/// in another language finds little. The languages read here are the app's own, apart from
/// English: Chinese, Japanese and Korean, which their scripts give away, and Portuguese only
/// while the app itself is in Portuguese, because a short Portuguese query and an English one
/// (a name, a word cut short while typing) look alike to any recognizer.
enum WorkshopSearchLanguage {
    /// A Portuguese reading must be at least this sure, and the text at least this many letters
    /// long, before a Latin-script search counts as Portuguese.
    static let portugueseConfidence = 0.9
    static let minimumPortugueseLetters = 3
    /// Text that reads as Japanese with at least this confidence is Japanese even without kana:
    /// a name such as 東京 is written in kanji alone. Below it, Han text is Chinese.
    static let kanjiJapaneseConfidence = 0.9

    /// The languages a search can be read in while the app shows `app`, in the app's own order.
    static func candidates(app: AppLanguage) -> [AppLanguage] {
        AppLanguage.supported.filter { language in
            switch language.tag {
            case "zh-Hans", "zh-Hant", "ja", "ko": true
            case "pt-BR": app.tag == "pt-BR"
            default: false
            }
        }
    }

    /// The language `text` was typed in, or nil for English, for text in no language this reads,
    /// and for text with nothing to read (digits, symbols).
    ///
    /// Kana makes text Japanese and Hangul Korean. Han characters alone are Japanese only when the
    /// recognizer is very sure (`kanjiJapaneseConfidence`), else Chinese, and Traditional when
    /// ICU's Traditional-to-Simplified transform changes them: the recognizer often calls a short
    /// Simplified title Traditional. Mixed text such as "anime 女孩" is read by its CJK characters.
    /// Latin text is Portuguese only by the rule of `candidates(app:)` and `portugueseConfidence`.
    static func detect(_ text: String, app: AppLanguage) -> AppLanguage? {
        var han = ""
        var hasKana = false
        var hasHangul = false
        var latinLetters = 0
        var otherLetters = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: hasKana = true
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF:
                hasHangul = true
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:
                han.unicodeScalars.append(scalar)
            default:
                guard scalar.properties.isAlphabetic else { continue }
                if scalar.value <= 0x024F || (0x1E00...0x1EFF).contains(scalar.value) {
                    latinLetters += 1
                } else {
                    otherLetters += 1
                }
            }
        }
        if hasKana { return language("ja") }
        if hasHangul { return language("ko") }
        if !han.isEmpty { return chineseOrJapanese(han) }
        guard otherLetters == 0, latinLetters >= minimumPortugueseLetters,
            candidates(app: app).contains(where: { $0.tag == "pt-BR" })
        else { return nil }
        let portuguese = hypotheses(text, among: [.english, .portuguese])[.portuguese] ?? 0
        return portuguese >= portugueseConfidence ? language("pt-BR") : nil
    }

    /// Han characters with no kana: Japanese when the recognizer is very sure, else Chinese in the
    /// script the characters are written in.
    private static func chineseOrJapanese(_ han: String) -> AppLanguage? {
        let readings = hypotheses(han, among: [.simplifiedChinese, .traditionalChinese, .japanese])
        if (readings[.japanese] ?? 0) >= kanjiJapaneseConfidence { return language("ja") }
        let simplified = han.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? han
        return language(simplified == han ? "zh-Hans" : "zh-Hant")
    }

    private static func hypotheses(_ text: String, among languages: [NLLanguage]) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: languages.count)
    }

    private static func language(_ tag: String) -> AppLanguage? { AppLanguage.named(tag) }
}
