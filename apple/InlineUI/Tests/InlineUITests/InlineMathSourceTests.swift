import Foundation
import InlineKit
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("Canonical math source")
@MainActor
struct InlineMathSourceTests {
  private let configuration = ProcessEntities.Configuration(
    font: PlatformFont.systemFont(ofSize: 16), primaryColor: PlatformColor.black,
    linkColor: PlatformColor.blue, convertMentionsToLink: false
  )

  private func math(_ range: NSRange, display: Bool = false) -> MessageEntity {
    MessageEntity.with {
      $0.type = .math; $0.offset = Int64(range.location); $0.length = Int64(range.length)
      if display { $0.math = .with { $0.display = true } }
    }
  }

  @Test("Restored formulas retain exact source and UTF-16 ranges with Markdown enabled or disabled")
  func restoredSource() {
    let source = #"\frac{a_b}{c} + \text{😀 **bold** <u>u</u> ==h== ~~s~~ `code` [q](https://e.co) x@y.co}"#
    let text = "😀 " + source + " tail"
    let entity = math(NSRange(location: 3, length: (source as NSString).length))
    let rendered = ProcessEntities.toAttributedString(
      text: text, entities: MessageEntities.with { $0.entities = [entity] }, configuration: configuration
    )
    #expect(rendered.string == text)
    #expect(!rendered.string.contains("\u{FFFC}"))
    #expect((rendered.attribute(.richTextMath, at: 3, effectiveRange: nil) as? NSValue)?.rangeValue == NSRange(location: 3, length: (source as NSString).length))
    for parse in [false, true] {
      let extracted = ProcessEntities.fromAttributedString(rendered, parseMarkdown: parse)
      #expect(extracted.text == text)
      #expect(extracted.entities.entities == [entity])
    }
  }

  @Test("Outer Markdown can wrap restored math without closing on TeX markers")
  func surroundingMarkdown() {
    let source = #"\text{**x** _y_ ==z== </u>}"#
    for (open, close, type) in [("**", "**", MessageEntity.TypeEnum.bold), ("<u>", "</u>", .underline)] {
      let text = open + "a " + source + " z" + close
      let range = NSRange(location: (open as NSString).length + 2, length: (source as NSString).length)
      let restored = ProcessEntities.toAttributedString(
        text: text, entities: MessageEntities.with { $0.entities = [math(range)] }, configuration: configuration
      )
      let extracted = ProcessEntities.fromAttributedString(restored)
      let expectedText = "a " + source + " z"
      #expect(extracted.text == expectedText)
      #expect(extracted.entities.entities.contains(math(NSRange(location: 2, length: range.length))))
      #expect(extracted.entities.entities.contains(MessageEntity.with {
        $0.type = type; $0.offset = 0; $0.length = Int64((expectedText as NSString).length)
      }))
    }
  }

  @Test("Display source with fence-like text remains source during draft extraction")
  func multilineSource() {
    let text = "\n```tex\n**x**\n```\n"
    let entity = math(NSRange(location: 0, length: (text as NSString).length), display: true)
    let restored = ProcessEntities.toAttributedString(
      text: text, entities: MessageEntities.with { $0.entities = [entity] }, configuration: configuration
    )
    #expect(restored.attribute(.richTextMathDisplay, at: 0, effectiveRange: nil) as? Bool == true)
    let extracted = ProcessEntities.fromAttributedString(restored)
    #expect(extracted.text == text)
    #expect(extracted.entities.entities == [entity])
  }

  @Test("Adjacent formulas remain separate semantic source ranges")
  func adjacentSources() {
    let entities = [math(NSRange(location: 0, length: 1)), math(NSRange(location: 1, length: 1))]
    let restored = ProcessEntities.toAttributedString(
      text: "xx", entities: MessageEntities.with { $0.entities = entities }, configuration: configuration
    )
    #expect(ProcessEntities.fromAttributedString(restored, parseMarkdown: false).entities.entities == entities)
  }

  @Test("Typed math preserves TeX and remaps Unicode mentions and outer styles")
  func typedSource() {
    let source = #"\text{😀 **b** _x_ <u>u</u> ==h== ~~s~~ `c` [x](https://e.co) a@b.co /help}"#
    let text = "😀 **$" + source + "$** @bob"
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.mentionUserId, value: Int64(42), range: (text as NSString).range(of: "@bob"))
    let result = ProcessEntities.fromAttributedString(attributed)
    #expect(result.text == "😀 " + source + " @bob")
    #expect(result.entities.entities.count == 3)
    #expect(result.entities.entities.contains(math(NSRange(location: 3, length: source.utf16.count))))
    #expect(result.entities.entities.contains { $0.type == .bold && $0.offset == 3 && $0.length == source.utf16.count })
    #expect(result.entities.entities.contains { $0.type == .mention && $0.offset == source.utf16.count + 4 })
  }

  @Test("Code and Markdown URL destinations shield typed math; labels allow formulas")
  func typedPrecedence() {
    let text = #"`$a$` [v $x$](https://e.co/$y$) $\text{`z`}$"#
    let result = ProcessEntities.fromAttributedString(NSAttributedString(string: text))
    #expect(result.text == #"$a$ v x \text{`z`}"#)
    let formulas = result.entities.entities.filter { $0.type == .math }
    #expect(formulas.map { (result.text as NSString).substring(with: NSRange(location: Int($0.offset), length: Int($0.length))) } == ["x", #"\text{`z`}"#])
    #expect(result.entities.entities.contains { $0.type == .textURL && $0.textURL.url == "https://e.co/$y$" })
  }

  @Test("Complete oversized math stays literal and opaque after preceding Markdown edits")
  func oversizedSource() {
    let source = "$" + String(repeating: "x", count: 2_048) + #" **b** [x](https://e.co) a@b.co /help [[thread]]"# + "$"
    let text = "```hi``` **before** " + source + " **after**"
    let result = ProcessEntities.fromAttributedString(NSAttributedString(string: text), threadLinkSpaceId: 7)
    #expect(result.text == "hi\nbefore " + source + " after")
    #expect(result.entities.entities.map(\.type) == [.pre, .bold, .bold])
    #expect(result.entities.entities.last?.offset == Int64(result.text.utf16.count - 5))
  }

  @Test("Display TeX cannot fabricate code or Markdown across lines")
  func typedDisplay() {
    let source = "\n```tex\n**x**\n```\n"
    let result = ProcessEntities.fromAttributedString(NSAttributedString(string: "$$" + source + "$$\n**tail**"))
    #expect(result.text == source + "\ntail")
    #expect(result.entities.entities.map(\.type) == [.math, .bold])
    let formula = result.entities.entities[0]
    #expect(formula.offset == 0 && formula.length == source.utf16.count)
    guard case let .math(metadata)? = formula.entity else {
      Issue.record("display formula lost its structural marker")
      return
    }
    #expect(metadata.display)
  }

  @Test("Double dollars remain inline when they do not own the source line")
  func mixedDoubleDollar() {
    for text in ["prefix $$x$$ suffix", "$$x$$2"] {
      let result = ProcessEntities.fromAttributedString(NSAttributedString(string: text))
      let formula = result.entities.entities.first { $0.type == .math }
      #expect(formula != nil)
      #expect(formula?.entity == nil)
    }
  }

  @Test("Incomplete, escaped and currency dollars keep their existing literal behavior")
  func literalDollars() {
    for text in ["cost $5 and $10", #"\$x$"#, "$$", "$ x$", "$x $", "$x$2", "$$$x$$$", "$unclosed"] {
      let result = ProcessEntities.fromAttributedString(NSAttributedString(string: text))
      #expect(result.text == text)
      #expect(!result.entities.entities.contains { $0.type == .math })
    }
    let literal = "$x$ **b**"
    let result = ProcessEntities.fromAttributedString(NSAttributedString(string: literal), parseMarkdown: false)
    #expect(result.text == literal)
    #expect(result.entities.entities.isEmpty)
  }

  @Test("Restored math in a link destination cannot become a masked URL or disappear")
  func protectedDestination() {
    let text = "[x](https://e.co/formula)"
    let entity = math((text as NSString).range(of: "formula"))
    let restored = ProcessEntities.toAttributedString(
      text: text, entities: MessageEntities.with { $0.entities = [entity] }, configuration: configuration
    )
    let result = ProcessEntities.fromAttributedString(restored)
    #expect(result.text == text)
    #expect(result.entities.entities == [entity])
  }

  @Test("Platform-detected interactive attributes inside typed TeX do not escape math")
  func detectedSource() {
    let text = #"$\text{a@b.co /help}$"#
    let attributed = NSMutableAttributedString(string: text)
    attributed.addAttribute(.emailAddress, value: "a@b.co", range: (text as NSString).range(of: "a@b.co"))
    let result = ProcessEntities.fromAttributedString(attributed)
    #expect(result.entities.entities.map(\.type) == [.math])
    #expect(result.text == #"\text{a@b.co /help}"#)
  }

  @Test("Raw URL dollar bytes survive both plain and detected-link compose text")
  func literalURLDollars() {
    for text in ["https://e.co/$x$", "https://e.co/(path)/$x$?q=2"] {
      for detected in [false, true] {
        let attributed = NSMutableAttributedString(string: text)
        if detected { attributed.addAttribute(.link, value: text, range: NSRange(location: 0, length: attributed.length)) }
        let result = ProcessEntities.fromAttributedString(attributed)
        #expect(result.text == text)
        #expect(result.entities.entities.map(\.type) == [.url])
        #expect(result.entities.entities.first?.length == Int64(text.utf16.count))
      }
    }
    let source = #"\text{https://e.co/$x$}"#
    let result = ProcessEntities.fromAttributedString(NSAttributedString(string: "$$" + source + "$$"))
    #expect(result.text == source)
    #expect(result.entities.entities.map(\.type) == [.math])
  }

  @Test("Interior style attributes do not escape TeX; outer styles remain intact")
  func interiorStyles() {
    for range in [NSRange(location: 1, length: 1), NSRange(location: 0, length: 5)] {
      let attributed = NSMutableAttributedString(string: "$x_y$")
      attributed.addAttribute(.richTextUnderline, value: true, range: range)
      let result = ProcessEntities.fromAttributedString(attributed)
      #expect(result.text == "x_y")
      #expect(result.entities.entities.contains { $0.type == .underline } == (range.location == 0))
      #expect(result.entities.entities.contains(math(NSRange(location: 0, length: 3))))
    }
  }

  @Test("A retained Markdown destination stays opaque after a math overlap")
  func retainedDestination() {
    let text = "[x](https://e.co/**bar**)"
    let entity = math((text as NSString).range(of: "bar"))
    let restored = ProcessEntities.toAttributedString(
      text: text, entities: MessageEntities.with { $0.entities = [entity] }, configuration: configuration
    )
    let result = ProcessEntities.fromAttributedString(restored)
    #expect(result.text == text)
    #expect(result.entities.entities == [entity])
  }

  @Test("Only backticks and fenced tildes shield math; single/double tildes do not")
  func tildePrecedence() {
    for text in ["~$x$~", "~~$x$~~"] {
      let result = ProcessEntities.fromAttributedString(NSAttributedString(string: text))
      #expect(result.entities.entities.filter { $0.type == .math }.count == 1)
      #expect(result.text == (text.hasPrefix("~~") ? "x" : "~x~"))
    }
  }
}
