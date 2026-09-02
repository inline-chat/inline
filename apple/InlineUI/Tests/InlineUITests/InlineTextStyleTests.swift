import Foundation
import InlineKit
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("Rich text v2 inline styles")
@MainActor
struct InlineTextStyleTests {
  private let configuration = ProcessEntities.Configuration(
    font: PlatformFont.systemFont(ofSize: 16),
    primaryColor: PlatformColor.black,
    linkColor: PlatformColor.blue,
    convertMentionsToLink: false
  )

  private func entity(_ type: MessageEntity.TypeEnum, _ offset: Int64, _ length: Int64) -> MessageEntity {
    MessageEntity.with { $0.type = type; $0.offset = offset; $0.length = length }
  }

  @Test("All styles render and round-trip UTF-16 ranges without changing text")
  func renderRoundTrip() {
    let text = "😀 hello"
    let entities = MessageEntities.with {
      $0.entities = InlineTextStyle.allCases.map { entity($0.entityType, 3, 5) }
    }
    let rendered = ProcessEntities.toAttributedString(text: text, entities: entities, configuration: configuration)
    #expect(rendered.attribute(.underlineStyle, at: 3, effectiveRange: nil) as? Int == 1)
    #expect(rendered.attribute(.strikethroughStyle, at: 3, effectiveRange: nil) as? Int == 1)
    #expect(rendered.attribute(.backgroundColor, at: 3, effectiveRange: nil) != nil)
    #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    let extracted = ProcessEntities.fromAttributedString(rendered, parseMarkdown: false)
    #expect(extracted.text == text)
    #expect(Set(extracted.entities.entities) == Set(entities.entities))
  }

  @Test("Link processing does not clear an intentional underline in either entity order")
  func underlinedLink() {
    let underline = entity(.underline, 0, 4)
    var link = entity(.textURL, 0, 4)
    link.textURL.url = "https://example.com"
    for values in [[underline, link], [link, underline]] {
      let rendered = ProcessEntities.toAttributedString(
        text: "docs", entities: MessageEntities.with { $0.entities = values }, configuration: configuration
      )
      #expect(rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == 1)
      #expect(rendered.attribute(.link, at: 0, effectiveRange: nil) != nil)
      let extracted = ProcessEntities.fromAttributedString(rendered, parseMarkdown: false)
      #expect(extracted.entities.entities.contains(underline))
      #expect(extracted.entities.entities.contains(link))
    }
  }

  @Test("Intentional underline survives removal of incidental link decoration")
  func reapplyUnderlinedLink() {
    var link = entity(.textURL, 0, 4)
    link.textURL.url = "https://example.com"
    let rendered = ProcessEntities.toAttributedString(
      text: "docs",
      entities: MessageEntities.with { $0.entities = [entity(.underline, 0, 4), link] },
      configuration: configuration
    )
    let range = NSRange(location: 0, length: rendered.length)
    rendered.removeAttribute(.underlineStyle, range: range)
    rendered.removeAttribute(.underlineColor, range: range)
    InlineTextStyle.reapply(to: rendered)
    #expect(rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == 1)

    let incidental = NSMutableAttributedString(string: "docs", attributes: [.underlineStyle: 1])
    incidental.removeAttribute(.underlineStyle, range: range)
    InlineTextStyle.reapply(to: incidental)
    #expect(incidental.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
  }

  @Test("Incidental decorations are not serialized as message styles")
  func incidentalAttributes() {
    let text = NSAttributedString(string: "plain", attributes: [
      .underlineStyle: 1, .strikethroughStyle: 1, .backgroundColor: PlatformColor.yellow,
    ])
    #expect(ProcessEntities.fromAttributedString(text, parseMarkdown: false).entities.entities.isEmpty)
  }

  @Test("Toggling one style preserves other styles and semantic attributes")
  func independentToggles() {
    let text = NSMutableAttributedString(string: "hello", attributes: [.mentionUserId: Int64(42)])
    let full = NSRange(location: 0, length: text.length)
    for style in InlineTextStyle.allCases { style.setEnabled(true, in: text, range: full) }
    InlineTextStyle.underline.setEnabled(false, in: text, range: NSRange(location: 1, length: 2))
    #expect(!InlineTextStyle.underline.isEnabled(in: text, range: full))
    #expect(InlineTextStyle.highlight.isEnabled(in: text, range: full))
    #expect(InlineTextStyle.strikethrough.isEnabled(in: text, range: full))
    #expect(text.attribute(.mentionUserId, at: 2, effectiveRange: nil) as? Int64 == 42)
    let typing = InlineTextStyle.highlight.settingEnabled(true, in: InlineTextStyle.underline.attributes)
    let disabled = InlineTextStyle.underline.settingEnabled(false, in: typing)
    #expect(disabled[.richTextUnderline] == nil)
    #expect(disabled[.underlineStyle] == nil)
    #expect(disabled[.richTextHighlight] as? Bool == true)
  }

  @Test("Invalid and split-surrogate entity ranges are ignored without trapping")
  func invalidRanges() {
    let invalid = [(Int64.max, 1), (0, Int64.max), (-1, 1), (0, 0), (1, 1), (0, 1), (3, 1)]
    let entities = MessageEntities.with { value in
      value.entities = invalid.flatMap { offset, length in
        [entity(.bold, offset, Int64(length)), entity(.highlight, offset, Int64(length))]
      }
    }
    let rendered = ProcessEntities.toAttributedString(text: "😀x", entities: entities, configuration: configuration)
    #expect(rendered.string == "😀x")
    #expect(ProcessEntities.fromAttributedString(rendered, parseMarkdown: false).entities.entities.isEmpty)
  }

  @Test("Native Markdown retains nested styles, links, code shielding, and Unicode offsets")
  func nativeMarkdown() {
    let input = "😀 [<u>==go==</u>](https://example.com/a==b) ~~a `~~` z~~"
    let result = ProcessEntities.fromAttributedString(NSAttributedString(string: input))
    #expect(result.text == "😀 go a ~~ z")
    #expect(result.entities.entities.contains(entity(.underline, 3, 2)))
    #expect(result.entities.entities.contains(entity(.highlight, 3, 2)))
    #expect(result.entities.entities.contains(entity(.strikethrough, 6, 6)))
    #expect(result.entities.entities.contains(entity(.code, 8, 2)))
    #expect(result.entities.entities.first { $0.type == .textURL }?.textURL.url == "https://example.com/a==b")
  }

  @Test("Unfinished or escaped style markers stay literal")
  func literalPrefixes() {
    for markdown in ["<b>x</b>", "<i>x</i>", "<u>x</u>", "<s>x</s>", "<mark>x</mark>", "~~x~~", "==x=="] {
      for length in 1 ..< markdown.count {
        let prefix = String(markdown.prefix(length))
        let result = ProcessEntities.fromAttributedString(NSAttributedString(string: prefix))
        #expect(result.text == prefix)
        #expect(result.entities.entities.isEmpty)
      }
    }
    let escaped = #"\~~x\~~ \==x\== \<u>x\</u>"#
    let result = ProcessEntities.fromAttributedString(NSAttributedString(string: escaped))
    #expect(result.text == escaped)
    #expect(result.entities.entities.isEmpty)
  }

  @Test("The conservative dialect keeps underline, bold and single tilde distinct")
  func conservativeSyntax() {
    for (source, text, entityType) in [
      ("<u>under</u>", "under", MessageEntity.TypeEnum.underline),
      ("**bold**", "bold", .bold),
    ] {
      let result = ProcessEntities.fromAttributedString(NSAttributedString(string: source))
      #expect(result.text == text)
      #expect(result.entities.entities == [entity(entityType, 0, Int64(text.utf16.count))])
    }
    let singleTilde = ProcessEntities.fromAttributedString(NSAttributedString(string: "~single~"))
    #expect(singleTilde.text == "~single~")
    #expect(singleTilde.entities.entities.isEmpty)
  }

  @Test("Exact formatting tags preserve punctuation and whitespace ranges")
  func formattingTagBoundaries() {
    let cases: [(String, MessageEntity.TypeEnum)] = [
      ("b", .bold), ("i", .italic), ("u", .underline), ("s", .strikethrough), ("mark", .highlight),
    ]
    for (tag, type) in cases {
      for body in ["&", " ", "\t  ", "😀", "é"] {
        let source = "a<\(tag)>\(body)</\(tag)>z"
        let result = ProcessEntities.fromAttributedString(NSAttributedString(string: source))
        #expect(result.text == "a\(body)z")
        #expect(result.entities.entities.contains(entity(type, 1, Int64(body.utf16.count))))
        let literal = ProcessEntities.fromAttributedString(NSAttributedString(string: source), parseMarkdown: false)
        #expect(literal.text == source)
        #expect(literal.entities.entities.isEmpty)
      }
    }
  }

  @Test("Formatting tags in unsupported HTML attributes and comments remain literal")
  func literalHTMLAttributes() {
    for text in [#"<span title="<b>x</b>">text</span>"#, #"<span title='<u>x</u>'>text</span>"#,
                 #"<span title="<b>**x** _y_ `z` $q$</b>">text</span>"#,
                 "<!--<mark>**x** _y_ `z` $q$</mark>-->",
                 "<b class='x'>text</b>", "<B>text</B>", "<b></b>"] {
      let result = ProcessEntities.fromAttributedString(NSAttributedString(string: text))
      #expect(result.text == text)
      #expect(result.entities.entities.isEmpty)
    }
    let nested = ProcessEntities.fromAttributedString(NSAttributedString(string: "<b>A <i>!</i> Z</b>"))
    #expect(nested.text == "A ! Z")
    #expect(nested.entities.entities.contains(entity(.bold, 0, 5)))
    #expect(nested.entities.entities.contains(entity(.italic, 2, 1)))
  }

  @Test("HTML shielding keeps code, math and outer formatting precedence")
  func literalHTMLPrecedence() {
    let token = #"<span title="**x** `y` $z$">"#
    let outer = ProcessEntities.fromAttributedString(NSAttributedString(string: "**before " + token + " after**"))
    #expect(outer.text == "before " + token + " after")
    #expect(outer.entities.entities == [entity(.bold, 0, Int64(outer.text.utf16.count))])

    for (source, body, type) in [
      ("`<span title='literal'>`", "<span title='literal'>", MessageEntity.TypeEnum.code),
      ("$x+<span title='literal'>$", "x+<span title='literal'>", MessageEntity.TypeEnum.math),
    ] {
      let result = ProcessEntities.fromAttributedString(NSAttributedString(string: source))
      #expect(result.text == body)
      #expect(result.entities.entities == [entity(type, 0, Int64(body.utf16.count))])
    }

    // A token that starts inside canonical code cannot swallow following prose
    // when later extraction passes see the already-removed code delimiters.
    let crossing = ProcessEntities.fromAttributedString(NSAttributedString(string: "`<span title='`**outside**'>"))
    #expect(crossing.text == "<span title='outside'>")
    #expect(crossing.entities.entities.contains(entity(.code, 0, 13)))
    #expect(crossing.entities.entities.contains(entity(.bold, 13, 7)))
  }

  @Test("Unfinished HTML comments preserve inner source during streaming")
  func unfinishedHTMLComments() {
    for (open, close) in [("<!--", "-->"), ("<?", "?>"), ("<![CDATA[", "]]>"), ("<!DOCTYPE ", ">")] {
      let body = open == "<!DOCTYPE " ? "**bold** `code` $math$ &copy; " : "<b>**bold**</b> `code` $math$ &copy; "
      let source = open + body
      let partial = ProcessEntities.fromAttributedString(NSAttributedString(string: source))
      #expect(partial.text == source)
      #expect(partial.entities.entities.isEmpty)
      let complete = ProcessEntities.fromAttributedString(NSAttributedString(string: source + close + "\n\n**after**"))
      #expect(complete.text == source + close + "\n\nafter")
      #expect(complete.entities.entities == [entity(.bold, Int64(source.utf16.count + close.utf16.count + 2), 5)])
    }
  }

  @Test("Explicit semantic styles shrink and move when Markdown markers are removed")
  func remapsExplicitStyle() {
    let text = NSMutableAttributedString(string: "😀 **bold** tail")
    text.addAttributes(InlineTextStyle.underline.attributes, range: NSRange(location: 3, length: 8))
    text.addAttributes(InlineTextStyle.highlight.attributes, range: NSRange(location: 12, length: 4))
    let result = ProcessEntities.fromAttributedString(text)
    #expect(result.text == "😀 bold tail")
    #expect(result.entities.entities.contains(entity(.underline, 3, 4)))
    #expect(result.entities.entities.contains(entity(.highlight, 8, 4)))
  }

  @Test("Typed Markdown does not duplicate an explicit style after range remapping")
  func duplicateStyle() {
    let text = NSMutableAttributedString(string: "<u>x</u>", attributes: InlineTextStyle.underline.attributes)
    let result = ProcessEntities.fromAttributedString(text)
    #expect(result.text == "x")
    #expect(result.entities.entities == [entity(.underline, 0, 1)])
  }

  @Test("Typed fallback tags do not duplicate an explicit native style")
  func duplicateFormattingTag() {
    let cases: [(String, MessageEntity.TypeEnum)] = [
      ("b", .bold), ("i", .italic), ("u", .underline), ("s", .strikethrough), ("mark", .highlight),
    ]
    for (tag, type) in cases {
      let source = "<\(tag)>!</\(tag)>"
      let styled = ProcessEntities.toAttributedString(text: source, entities: MessageEntities.with {
        $0.entities = [entity(type, 0, Int64(source.utf16.count))]
      }, configuration: configuration)
      let result = ProcessEntities.fromAttributedString(styled)
      #expect(result.text == "!")
      #expect(result.entities.entities == [entity(type, 0, 1)])
    }
  }

  @Test("Split formatting tags preserve crossing style coverage and a whole Agent link")
  func crossingFormattingTransport() {
    let source = "<b>ab<i>cd</i></b><i>ef</i>"
    let result = ProcessEntities.fromAttributedString(NSAttributedString(string: source))
    #expect(result.text == "abcdef")
    for (type, start, end) in [(MessageEntity.TypeEnum.bold, 0, 4), (.italic, 2, 6)] {
      for offset in 0 ..< 6 {
        let covered = result.entities.entities.contains {
          $0.type == type && $0.offset <= Int64(offset) && Int64(offset) < $0.offset + $0.length
        }
        #expect(covered == (start <= offset && offset < end))
      }
    }

    let link = ProcessEntities.fromAttributedString(NSAttributedString(
      string: "<b>ab</b>[<b>Ma</b>ya](inline://user?id=42&agent_id=7)XY"
    ))
    #expect(link.text == "abMayaXY")
    // Typed user links remain text URLs until the server validates the target.
    let targets = link.entities.entities.filter { $0.type == .textURL }
    #expect(targets.count == 1)
    #expect(targets.first?.offset == 2)
    #expect(targets.first?.length == 4)
    #expect(targets.first?.textURL.url == "inline://user?id=42&agent_id=7")
    #expect(link.entities.entities.allSatisfy { $0.type != .mention })
    for offset in 0 ..< 8 {
      let covered = link.entities.entities.contains {
        $0.type == .bold && $0.offset <= Int64(offset) && Int64(offset) < $0.offset + $0.length
      }
      #expect(covered == (offset < 4))
    }
  }
}
