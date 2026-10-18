import Foundation

/// An author's property label, reduced to what the inspector may draw.
///
/// A label is the wallpaper author's markup: data, never the panel's own. The parser is a tolerant
/// tokenizer, not a browser: it rebuilds a typed tree from an allowlist (headings, paragraphs,
/// lists, emphasis, sizes and colours, rules, line breaks, links to a fixed list of hosts, and the
/// images the app has already registered), so nothing an author writes can add a control, run a
/// script or reach a host the panel does not name. Limits are the web panel's: 32,768 characters,
/// 1,000 nodes, 24 levels deep. Text is always text: an escaped `&lt;b&gt;` stays those characters.
struct PropertyLabelDocument: Equatable {
  /// A stretch of text with one set of attributes. A line break is a run whose text is `"\n"`.
  struct Run: Equatable {
    enum Baseline: Equatable { case normal, subscripted, superscripted }

    var text: String
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStruck = false
    /// The size relative to body text; 1 is body text.
    var scale = 1.0
    var baseline = Baseline.normal
    /// The author's colour as written (`#rrggbb` or a name), only when it is a valid spelling.
    var color: String?
    /// A link the panel may open: https, no credentials, no port, a host on the list.
    var link: URL?
    /// A link the panel will not open still shows as emphasised text.
    var isAccented = false

    var isLineBreak: Bool { text == "\n" }
  }

  /// How wide an image asks to be.
  enum Width: Equatable {
    case percent(Double)
    case pixels(Int)
  }

  struct Paragraph: Equatable {
    var runs: [Run]
    /// 1 to 6 for text inside a heading element.
    var heading: Int?
    var isCentered: Bool
    /// "•" or "1." for a list item.
    var marker: String?

    /// The words, with line breaks as spaces.
    var plainText: String {
      runs.map { $0.isLineBreak ? " " : $0.text }.joined()
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  struct Image: Equatable {
    /// The registered address; loaded only through `PanelImageSource.propertyImage`.
    var url: URL
    var alt: String
    var width: Width?
    var height: Int?
    /// The link the image sits inside, when it may be opened.
    var link: URL?
    var isCentered: Bool
  }

  enum Block: Equatable {
    case paragraph(Paragraph)
    case image(Image)
    case rule
  }

  var blocks: [Block]

  /// Nothing to draw: no words, no registered artwork and no rule. A group or description whose
  /// label is empty leaves its row out.
  var isEmpty: Bool { blocks.isEmpty }

  /// The words of every text block, one line each.
  var plainText: String {
    blocks.compactMap { block in
      if case .paragraph(let paragraph) = block { return paragraph.plainText }
      return nil
    }.joined(separator: "\n")
  }

  // MARK: Limits

  static let maximumSource = 32_768
  static let maximumNodes = 1000
  static let maximumDepth = 24

  /// The hosts a label's link may name: the web panel's list, which is narrower than the panel's own
  /// external-link list.
  static let linkHosts: Set<String> = [
    "steamcommunity.com", "store.steampowered.com", "github.com", "www.gnu.org",
    "support.apple.com", "space.bilibili.com", "www.bilibili.com",
  ]

  /// A link target the panel may open, or nil.
  static func allowedLink(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
      let host = url.host?.lowercased(), linkHosts.contains(host), ExternalLink.isAllowed(url)
    else { return nil }
    return url
  }

  // MARK: Parsing

  private static let blockTags: Set<String> = [
    "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "center", "ul", "ol", "li",
  ]
  private static let inlineTags: Set<String> = [
    "span", "b", "strong", "i", "em", "u", "s", "small", "big", "sub", "sup", "font", "a",
  ]
  private static let voidTags: Set<String> = [
    "br", "hr", "img", "input", "meta", "link", "source", "base", "embed", "wbr", "area", "col",
    "param", "track",
  ]
  private static let excludedTags: Set<String> = [
    "script", "style", "template", "iframe", "object", "embed", "svg", "math", "form", "input",
    "button", "select", "textarea", "video", "audio", "source", "link", "meta", "base",
  ]
  /// Elements whose content a browser reads as raw text up to the matching end tag.
  private static let rawTextTags: Set<String> = [
    "script", "style", "textarea", "title", "xmp", "noembed", "noframes", "iframe", "noscript",
  ]

  /// The document for `html`. `images` maps the `src` spellings that are registered to the address
  /// they load from; an image whose spelling is not a key shows its `alt` text instead.
  static func parse(_ html: String, images: [String: URL] = [:]) -> PropertyLabelDocument {
    var parser = Parser(source: String(html.prefix(maximumSource)), images: images)
    parser.run()
    return PropertyLabelDocument(blocks: parser.blocks())
  }

  // MARK: The tokenizer and tree builder

  private struct Frame {
    var name: String
    /// What the frame adds to the runs inside it.
    var apply: (inout Run) -> Void
    /// A subtree the label does not draw: everything inside is dropped.
    var isExcluded = false
    var link: URL?
    var isCentered = false
    var heading: Int?
    /// The marker of the list item this frame is, or the counter of the list it is.
    var listKind: ListKind?
    var isAnchor = false
  }

  private enum ListKind {
    case bullets
    case numbers(next: Int)
    case item(marker: String)
  }

  private enum Piece {
    case text(String, Run, BlockContext)
    case lineBreak(Run, BlockContext)
    case boundary
    case rule
    case image(Image)
  }

  private struct BlockContext: Equatable {
    var heading: Int?
    var isCentered: Bool
    var marker: String?
  }

  private struct Parser {
    let source: String
    let images: [String: URL]
    private var stack: [Frame] = []
    private var pieces: [Piece] = []
    private var remaining = PropertyLabelDocument.maximumNodes

    init(source: String, images: [String: URL]) {
      self.source = source
      self.images = images
    }

    mutating func run() {
      var index = source.startIndex
      var text = ""
      func flushText(_ parser: inout Parser) {
        if !text.isEmpty { parser.emit(text: decodeEntities(text)) }
        text = ""
      }
      while index < source.endIndex, remaining > 0 {
        let character = source[index]
        guard character == "<" else {
          text.append(character)
          index = source.index(after: index)
          continue
        }
        let next = source.index(after: index)
        guard next < source.endIndex else {
          text.append("<")
          index = next
          continue
        }
        let following = source[next]
        if following == "!" || following == "?" {
          // A comment, doctype or processing instruction is dropped.
          flushText(&self)
          if source[next...].hasPrefix("!--") {
            if let end = source.range(of: "-->", range: source.index(next, offsetBy: 3)..<source.endIndex) {
              index = end.upperBound
            } else {
              index = source.endIndex
            }
          } else if let end = source[next...].firstIndex(of: ">") {
            index = source.index(after: end)
          } else {
            index = source.endIndex
          }
          continue
        }
        let isClosing = following == "/"
        let nameStart = isClosing ? source.index(after: next) : next
        guard nameStart < source.endIndex, source[nameStart].isASCII, source[nameStart].isLetter
        else {
          // A "<" that does not start a tag is text.
          text.append("<")
          index = next
          continue
        }
        var nameEnd = nameStart
        while nameEnd < source.endIndex, isNameCharacter(source[nameEnd]) {
          nameEnd = source.index(after: nameEnd)
        }
        let name = source[nameStart..<nameEnd].lowercased()
        // The rest of the tag up to its ">" with quoted values kept whole.
        var cursor = nameEnd
        var quote: Character?
        while cursor < source.endIndex {
          let c = source[cursor]
          if let q = quote {
            if c == q { quote = nil }
          } else if c == "\"" || c == "'" {
            quote = c
          } else if c == ">" {
            break
          }
          cursor = source.index(after: cursor)
        }
        let attributeText = String(source[nameEnd..<cursor])
        let selfClosing = attributeText.hasSuffix("/")
        flushText(&self)
        index = cursor < source.endIndex ? source.index(after: cursor) : source.endIndex
        if isClosing {
          close(name)
        } else {
          open(name, attributes: attributes(of: attributeText), selfClosing: selfClosing)
          if rawTextTags.contains(name), !selfClosing {
            // Skip the raw content up to the end tag; none of it is the label's.
            if let end = source.range(
              of: "</\(name)", options: .caseInsensitive, range: index..<source.endIndex)
            {
              index = end.lowerBound
            } else {
              index = source.endIndex
            }
          }
        }
      }
      flushText(&self)
    }

    private func isNameCharacter(_ c: Character) -> Bool {
      c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == ":")
    }

    // MARK: Elements

    private var isSkipping: Bool { stack.contains { $0.isExcluded } }

    private var context: BlockContext {
      var heading: Int?
      var centered = false
      var marker: String?
      for frame in stack.reversed() {
        if heading == nil, let level = frame.heading { heading = level }
        if frame.isCentered { centered = true }
        if marker == nil, case .item(let m)? = frame.listKind { marker = m }
      }
      return BlockContext(heading: heading, isCentered: centered, marker: marker)
    }

    private var current: Run {
      var run = Run(text: "")
      for frame in stack { frame.apply(&run) }
      if let link = stack.last(where: { $0.link != nil })?.link { run.link = link }
      return run
    }

    private var isInsideAnchor: Bool { stack.contains { $0.isAnchor } }

    private mutating func emit(text: String) {
      guard !isSkipping, stack.count <= PropertyLabelDocument.maximumDepth else { return }
      remaining -= 1
      guard remaining >= 0 else { return }
      var run = current
      run.text = text
      pieces.append(.text(text, run, context))
    }

    private mutating func open(_ name: String, attributes: [String: String], selfClosing: Bool) {
      let skipping = isSkipping
      if skipping, !voidTags.contains(name) {
        // Track the nesting of a dropped subtree so its end tag is matched.
        if !selfClosing { stack.append(Frame(name: name, apply: { _ in }, isExcluded: true)) }
        return
      }
      if skipping { return }
      remaining -= 1
      guard remaining >= 0 else { return }
      let tooDeep = stack.count > PropertyLabelDocument.maximumDepth
      if excludedTags.contains(name) {
        if !voidTags.contains(name), !selfClosing {
          stack.append(Frame(name: name, apply: { _ in }, isExcluded: true))
        }
        return
      }
      switch name {
      case "br":
        if !tooDeep { pieces.append(.lineBreak(current, context)) }
        return
      case "hr":
        if !tooDeep {
          pieces.append(.boundary)
          pieces.append(.rule)
          pieces.append(.boundary)
        }
        return
      case "img":
        if !tooDeep { image(attributes) }
        return
      default: break
      }
      if voidTags.contains(name) { return }
      var frame = Frame(name: name, apply: { _ in })
      if tooDeep { frame.isExcluded = true }
      switch name {
      case "b", "strong": frame.apply = { $0.isBold = true }
      case "i", "em": frame.apply = { $0.isItalic = true }
      case "u": frame.apply = { $0.isUnderlined = true }
      case "s": frame.apply = { $0.isStruck = true }
      case "small": frame.apply = { $0.scale *= 0.83 }
      case "big": frame.apply = { $0.scale *= 1.2 }
      case "sub":
        frame.apply = {
          $0.baseline = .subscripted
          $0.scale *= 0.83
        }
      case "sup":
        frame.apply = {
          $0.baseline = .superscripted
          $0.scale *= 0.83
        }
      case "font":
        let color = attributes["color"].flatMap(validColor)
        let scale = attributes["size"].flatMap(fontScale)
        frame.apply = { run in
          if let color { run.color = color }
          if let scale { run.scale *= scale }
        }
      case "a":
        frame.isAnchor = true
        if !isInsideAnchor, let url = PropertyLabelDocument.allowedLink(attributes["href"]) {
          frame.link = url
        } else {
          frame.apply = { $0.isAccented = true }
        }
      case "center":
        frame.isCentered = true
      case "ul":
        frame.listKind = .bullets
      case "ol":
        frame.listKind = .numbers(next: 1)
      case "li":
        frame.listKind = .item(marker: nextMarker())
      case "h1", "h2", "h3", "h4", "h5", "h6":
        let level = Int(name.dropFirst()) ?? 3
        frame.heading = level
        frame.apply = { $0.isBold = true }
      default: break
      }
      if blockTags.contains(name) { pieces.append(.boundary) }
      stack.append(frame)
      if selfClosing, !blockTags.contains(name) { close(name) }
    }

    /// The marker for the next list item, counting in the nearest ordered list.
    private mutating func nextMarker() -> String {
      guard let index = stack.lastIndex(where: { frame in
        switch frame.listKind {
        case .bullets?, .numbers?: true
        default: false
        }
      })
      else { return "•" }
      switch stack[index].listKind {
      case .numbers(let next)?:
        stack[index].listKind = .numbers(next: next + 1)
        return "\(next)."
      default:
        return "•"
      }
    }

    private mutating func close(_ name: String) {
      guard let index = stack.lastIndex(where: { $0.name == name }) else { return }
      let closed = Array(stack[index...])
      stack.removeSubrange(index...)
      if closed.contains(where: { blockTags.contains($0.name) }) { pieces.append(.boundary) }
    }

    private mutating func image(_ attributes: [String: String]) {
      let alt = attributes["alt"] ?? ""
      guard let source = attributes["src"], let url = images[source] else {
        if !alt.isEmpty { emit(text: alt) }
        return
      }
      pieces.append(.boundary)
      pieces.append(
        .image(
          Image(
            url: url, alt: alt, width: width(attributes["width"]),
            height: pixels(attributes["height"]),
            link: stack.last(where: { $0.link != nil })?.link, isCentered: context.isCentered)))
      pieces.append(.boundary)
    }

    // MARK: Attribute values

    private func attributes(of text: String) -> [String: String] {
      var result: [String: String] = [:]
      var index = text.startIndex
      func skipSpaces() {
        while index < text.endIndex, text[index].isWhitespace || text[index] == "/" {
          index = text.index(after: index)
        }
      }
      while index < text.endIndex {
        skipSpaces()
        guard index < text.endIndex else { break }
        let start = index
        while index < text.endIndex, !text[index].isWhitespace, text[index] != "=", text[index] != "/"
        {
          index = text.index(after: index)
        }
        let name = text[start..<index].lowercased()
        skipSpaces()
        var value = ""
        if index < text.endIndex, text[index] == "=" {
          index = text.index(after: index)
          skipSpaces()
          if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
            let quote = text[index]
            index = text.index(after: index)
            let valueStart = index
            while index < text.endIndex, text[index] != quote { index = text.index(after: index) }
            value = String(text[valueStart..<index])
            if index < text.endIndex { index = text.index(after: index) }
          } else {
            let valueStart = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            value = String(text[valueStart..<index])
          }
        }
        if !name.isEmpty, result[name] == nil { result[name] = decodeEntities(value) }
      }
      return result
    }

    private func validColor(_ value: String) -> String? {
      value.range(of: "^(#[0-9a-fA-F]{3,8}|[A-Za-z]{1,24})$", options: .regularExpression) != nil
        ? value : nil
    }

    private func fontScale(_ value: String) -> Double? {
      guard value.count == 1, let size = Int(value), (1...7).contains(size) else { return nil }
      return [0.63, 0.82, 1, 1.13, 1.5, 2, 3][size - 1]
    }

    private func pixels(_ value: String?) -> Int? {
      guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
        text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(text), number > 0
      else { return nil }
      return min(2048, number)
    }

    private func width(_ value: String?) -> Width? {
      guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
      if text.range(of: "^\\d+(\\.\\d+)?%$", options: .regularExpression) != nil,
        let number = Double(text.dropLast())
      {
        return .percent(max(1, min(100, number)))
      }
      return pixels(text).map(Width.pixels)
    }

    // MARK: Building the blocks

    func blocks() -> [Block] {
      var blocks: [Block] = []
      var runs: [Run] = []
      var context: BlockContext?

      func flush() {
        defer {
          runs = []
          context = nil
        }
        guard !runs.isEmpty, let context else { return }
        // Collapse whitespace the way a page does, and trim both ends of the block.
        var collapsed: [Run] = []
        var lastWasSpace = true
        for var run in runs {
          if run.isLineBreak {
            while collapsed.last.map({ !$0.isLineBreak && $0.text.last == " " }) == true {
              collapsed[collapsed.count - 1].text.removeLast()
              if collapsed[collapsed.count - 1].text.isEmpty { collapsed.removeLast() }
            }
            collapsed.append(run)
            lastWasSpace = true
            continue
          }
          var text = ""
          for character in run.text {
            if character == " " || character == "\n" || character == "\t" || character == "\r"
              || character == "\u{000C}"
            {
              if !lastWasSpace { text.append(" ") }
              lastWasSpace = true
            } else {
              text.append(character)
              lastWasSpace = false
            }
          }
          guard !text.isEmpty else { continue }
          run.text = text
          collapsed.append(run)
        }
        while let last = collapsed.last {
          if last.isLineBreak {
            collapsed.removeLast()
          } else if last.text.last == " " {
            collapsed[collapsed.count - 1].text.removeLast()
            if collapsed[collapsed.count - 1].text.isEmpty { collapsed.removeLast() } else { break }
          } else {
            break
          }
        }
        guard collapsed.contains(where: { !$0.isLineBreak && !$0.text.isEmpty }) else { return }
        blocks.append(
          .paragraph(
            Paragraph(
              runs: collapsed, heading: context.heading, isCentered: context.isCentered,
              marker: context.marker)))
      }

      for piece in pieces {
        switch piece {
        case .text(_, let run, let blockContext):
          if context == nil { context = blockContext }
          runs.append(run)
        case .lineBreak(let run, let blockContext):
          if context == nil { context = blockContext }
          var lineBreak = run
          lineBreak.text = "\n"
          runs.append(lineBreak)
        case .boundary:
          flush()
        case .rule:
          flush()
          blocks.append(.rule)
        case .image(let image):
          flush()
          blocks.append(.image(image))
        }
      }
      flush()
      // A list marker belongs to the first block of its item only.
      return blocks
    }
  }

  // MARK: Entities

  private static let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
    "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
    "times": "×", "divide": "÷", "deg": "°", "plusmn": "±", "laquo": "«", "raquo": "»",
    "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "larr": "←", "rarr": "→",
    "uarr": "↑", "darr": "↓", "hearts": "♥", "star": "☆", "check": "✓",
  ]
  /// The entities a browser reads without the closing semicolon.
  private static let legacyEntities: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

  /// Text with its character references decoded once: `&amp;lt;` is the characters `&lt;`.
  static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      guard character == "&" else {
        result.append(character)
        index = text.index(after: index)
        continue
      }
      var cursor = text.index(after: index)
      if cursor < text.endIndex, text[cursor] == "#" {
        cursor = text.index(after: cursor)
        let hex = cursor < text.endIndex && (text[cursor] == "x" || text[cursor] == "X")
        if hex { cursor = text.index(after: cursor) }
        let digitsStart = cursor
        while cursor < text.endIndex, hex ? text[cursor].isHexDigit : (text[cursor].isASCII && text[cursor].isNumber) {
          cursor = text.index(after: cursor)
        }
        if cursor > digitsStart, let code = UInt32(text[digitsStart..<cursor], radix: hex ? 16 : 10),
          let scalar = Unicode.Scalar(code), code != 0
        {
          result.unicodeScalars.append(scalar)
          index = cursor < text.endIndex && text[cursor] == ";" ? text.index(after: cursor) : cursor
          continue
        }
        result.append("&")
        index = text.index(after: index)
        continue
      }
      let nameStart = cursor
      while cursor < text.endIndex, text[cursor].isASCII, text[cursor].isLetter || text[cursor].isNumber {
        cursor = text.index(after: cursor)
      }
      let name = String(text[nameStart..<cursor])
      let hasSemicolon = cursor < text.endIndex && text[cursor] == ";"
      if let value = namedEntities[name], hasSemicolon {
        result.append(value)
        index = text.index(after: cursor)
        continue
      }
      if !hasSemicolon, !name.isEmpty {
        // Without the semicolon only the legacy entities count, and a longer word does not: `&nbsp` is
        // a space, `&nbspx` is not.
        if legacyEntities.contains(name), let value = namedEntities[name] {
          result.append(value)
          index = cursor
          continue
        }
        // The browser reads a legacy entity at the start of a longer run (`&nbspfoo`).
        if let legacy = legacyEntities.sorted(by: { $0.count > $1.count }).first(where: { name.hasPrefix($0) }),
          let value = namedEntities[legacy]
        {
          result.append(value)
          index = text.index(nameStart, offsetBy: legacy.count)
          continue
        }
      }
      result.append("&")
      index = text.index(after: index)
    }
    return result
  }
}
