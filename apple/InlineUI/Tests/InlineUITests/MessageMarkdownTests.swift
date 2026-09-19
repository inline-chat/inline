import Foundation
import InlineKit
import InlineProtocol
import Testing
@testable import TextProcessing

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Suite("Message Markdown copy")
struct MessageMarkdownTests {
  private var editConfiguration: ProcessEntities.Configuration {
    .init(
      font: PlatformFont.systemFont(ofSize: 16),
      primaryColor: .black,
      linkColor: .blue,
      convertMentionsToLink: false
    )
  }

  private func entity(_ type: MessageEntity.TypeEnum, _ offset: Int, _ length: Int) -> MessageEntity {
    .with {
      $0.type = type
      $0.offset = Int64(offset)
      $0.length = Int64(length)
    }
  }

  private func serialize(_ text: String, _ entities: [MessageEntity]) -> String {
    MessageMarkdown.string(text: text, entities: .with { $0.entities = entities })
  }

  private func parse(_ source: String) -> (text: String, entities: MessageEntities) {
    ProcessEntities.fromAttributedString(NSAttributedString(string: source))
  }

  private func styledOffsets(_ entities: MessageEntities, _ type: MessageEntity.TypeEnum) -> Set<Int> {
    Set(entities.entities.filter { $0.type == type }.flatMap {
      Int($0.offset) ..< Int($0.offset + $0.length)
    })
  }

  @Test("Plain text is not interpreted during copy")
  func plainText() {
    let text = "literal **stars**, _names_, and 👨‍👩‍👧‍👦"
    #expect(MessageMarkdown.string(text: text, entities: nil) == text)
    #expect(MessageMarkdown.string(from: NSAttributedString(string: text)) == text)
  }

  @Test("Supported styles become editable Markdown")
  func styles() {
    let source = serialize("bold italic under strike mark", [
      entity(.bold, 0, 4), entity(.italic, 5, 6), entity(.underline, 12, 5),
      entity(.strikethrough, 18, 6), entity(.highlight, 25, 4),
    ])
    #expect(source == "**bold** _italic_ <u>under</u> ~~strike~~ ==mark==")
    let parsed = parse(source)
    #expect(parsed.text == "bold italic under strike mark")
    #expect(parsed.entities.entities.count == 5)
  }

  @Test("Overlapping styles preserve every styled character")
  func crossingStyles() {
    let text = "abcdef"
    let source = serialize(text, [entity(.bold, 0, 4), entity(.italic, 2, 4), entity(.underline, 1, 4)])
    let parsed = parse(source)
    #expect(parsed.text == text)
    #expect(styledOffsets(parsed.entities, .bold) == Set(0 ..< 4))
    #expect(styledOffsets(parsed.entities, .italic) == Set(2 ..< 6))
    #expect(styledOffsets(parsed.entities, .underline) == Set(1 ..< 5))
  }

  @Test("Blank lines remain unchanged when formatting spans paragraphs")
  func multilineStyles() {
    let text = "one\n\ntwo"
    let parsed = parse(serialize(text, [entity(.bold, 0, text.utf16.count), entity(.highlight, 0, text.utf16.count)]))
    #expect(parsed.text == text)
    #expect(styledOffsets(parsed.entities, .bold) == Set([0, 1, 2, 5, 6, 7]))
    #expect(styledOffsets(parsed.entities, .highlight) == Set([0, 1, 2, 5, 6, 7]))
  }

  @Test("Emoji offsets use UTF16 and malformed entity boundaries are ignored")
  func unicodeRanges() {
    let text = "🙂 bold"
    #expect(serialize(text, [entity(.bold, 3, 4), entity(.italic, 1, 1), entity(.bold, 0, Int.max)]) == "🙂 **bold**")
    let parsed = parse(serialize(text, [entity(.italic, 0, 2), entity(.bold, 3, 4)]))
    #expect(parsed.text == text)
    #expect(styledOffsets(parsed.entities, .italic) == Set(0 ..< 2))
    #expect(styledOffsets(parsed.entities, .bold) == Set(3 ..< 7))
  }

  @Test("Italic next to punctuation uses supported syntax")
  func italicBoundaries() {
    let source = serialize("(italic)", [entity(.italic, 1, 6)])
    #expect(source == "(<i>italic</i>)")
    #expect(parse(source).text == "(italic)")
    #expect(styledOffsets(parse(source).entities, .italic) == Set(1 ..< 7))
  }

  @Test("Inline code preserves literal Markdown and backticks", arguments: [
    "x ** y _z_", "`value`", "x `` y", "x ` y `` z", "`tick` + $x$", " padded ", "  ",
  ])
  func inlineCode(_ text: String) {
    let source = serialize(text, [entity(.code, 0, text.utf16.count)])
    let parsed = parse(source)
    #expect(parsed.text == text)
    #expect(styledOffsets(parsed.entities, .code) == Set(0 ..< text.utf16.count))
  }

  @Test("Fenced code preserves internal fences and original edge newlines", arguments: [
    "let x = 1\nprint(x)", "```swift\nx\n```", "\nhello\n", "`tick` and **bold**", "```\n$x$\n```",
  ])
  func blockCode(_ text: String) {
    let source = serialize(text, [entity(.pre, 0, text.utf16.count)])
    let parsed = parse(source)
    #expect(parsed.text == text)
    #expect(styledOffsets(parsed.entities, .pre) == Set(0 ..< text.utf16.count))
  }

  @Test("Single and triple backtick compose syntax remains supported")
  func existingCodeSyntax() {
    #expect(parse("Use `code`").text == "Use code")
    #expect(parse("```inline block```").entities.entities.first?.type == .pre)
    #expect(parse("```swift\nlet x = 1\n```").text == "let x = 1")
  }

  @Test("Math uses recognized composer delimiters", arguments: [false, true])
  func math(_ display: Bool) {
    let text = "x^2 + y^2"
    var math = entity(.math, 0, text.utf16.count)
    math.math.display = display
    let parsed = parse(serialize(text, [math]))
    #expect(parsed.text == text)
    #expect(parsed.entities.entities.first?.type == .math)
    #expect(parsed.entities.entities.first?.math.display == display)
  }

  @Test("Links retain nested formatting and destinations")
  func links() {
    var link = entity(.textURL, 0, 4)
    link.textURL.url = "https://example.com/docs"
    let source = serialize("docs", [link, entity(.bold, 0, 4)])
    #expect(source == "[**docs**](https://example.com/docs)")
    let parsed = parse(source)
    #expect(parsed.text == "docs")
    #expect(parsed.entities.entities.contains { $0.type == .textURL && $0.textURL.url == link.textURL.url })
    #expect(styledOffsets(parsed.entities, .bold) == Set(0 ..< 4))
  }

  @Test("Imported native decorations become Markdown without incidental link underline")
  func importedDecorations() {
    let text = NSMutableAttributedString(string: "under strike docs")
    text.addAttribute(.underlineStyle, value: 1, range: NSRange(location: 0, length: 5))
    text.addAttribute(.strikethroughStyle, value: 1, range: NSRange(location: 6, length: 6))
    text.addAttributes([.link: "https://example.com", .underlineStyle: 1], range: NSRange(location: 13, length: 4))
    #expect(MessageMarkdown.string(from: text) == "<u>under</u> ~~strike~~ [docs](https://example.com)")
  }

  @Test("Adjacent native font runs merge into one bold span")
  func importedFontRuns() {
    let text = NSMutableAttributedString(string: "bold text", attributes: [.font: PlatformFont.boldSystemFont(ofSize: 16)])
    text.addAttribute(.foregroundColor, value: PlatformColor.red, range: NSRange(location: 0, length: 4))
    #expect(MessageMarkdown.string(from: text) == "**bold text**")
  }

  @Test("Editing shows Markdown markers in the regular composer font")
  func editingUsesSource() {
    let entities = MessageEntities.with {
      $0.entities = [entity(.bold, 0, 4), entity(.italic, 5, 6)]
    }
    let editable = MessageMarkdown.editableText(text: "bold italic", entities: entities, configuration: editConfiguration)
    #expect(editable.string == "**bold** _italic_")
    editable.enumerateAttributes(in: NSRange(location: 0, length: editable.length)) { attributes, _, _ in
      #expect(attributes[.font] as? PlatformFont == editConfiguration.font)
      #expect(attributes[.italic] == nil)
      #expect(attributes[.richTextUnderline] == nil)
      #expect(attributes[.richTextStrikethrough] == nil)
      #expect(attributes[.richTextHighlight] == nil)
    }
    let parsed = ProcessEntities.fromAttributedString(editable)
    #expect(parsed.text == "bold italic")
    #expect(styledOffsets(parsed.entities, .bold) == Set(0 ..< 4))
    #expect(styledOffsets(parsed.entities, .italic) == Set(5 ..< 11))
  }

  @Test("Editing retains mention, group, and thread identity beside emoji and formatting")
  func editingPreservesIdentities() {
    let text = "🙂 @Dena @team roadmap bold"
    let nsText = text as NSString
    func namedEntity(_ type: MessageEntity.TypeEnum, _ label: String) -> MessageEntity {
      let range = nsText.range(of: label)
      return entity(type, range.location, range.length)
    }
    var mention = namedEntity(.mention, "@Dena")
    mention.mention.userID = 41
    mention.mention.agentID = 42
    var group = namedEntity(.groupMention, "@team")
    group.groupMention.groupID = 51
    var thread = namedEntity(.thread, "roadmap")
    thread.thread.chatID = 61
    let bold = namedEntity(.bold, "bold")
    let entities = MessageEntities.with { $0.entities = [mention, group, thread, bold] }

    let editable = MessageMarkdown.editableText(text: text, entities: entities, configuration: editConfiguration)
    #expect(editable.string == "🙂 @Dena @team roadmap **bold**")
    #expect(editable.attribute(.mentionUserId, at: Int(mention.offset), effectiveRange: nil) as? Int64 == 41)
    #expect(editable.attribute(.mentionAgentId, at: Int(mention.offset), effectiveRange: nil) as? Int64 == 42)
    #expect(editable.attribute(.mentionGroupId, at: Int(group.offset), effectiveRange: nil) as? Int64 == 51)
    #expect(editable.attribute(.threadLink, at: Int(thread.offset), effectiveRange: nil) != nil)
    let parsed = ProcessEntities.fromAttributedString(editable)
    #expect(parsed.text == text)
    #expect(parsed.entities.entities.contains(mention))
    #expect(parsed.entities.entities.contains(group))
    #expect(parsed.entities.entities.contains(thread))
    #expect(parsed.entities.entities.contains(bold))
  }

  @Test("Partial formatting inside a group mention retains a single semantic entity")
  func editingPartiallyStyledGroup() {
    let text = "🙂 @team"
    var group = entity(.groupMention, 3, 5)
    group.groupMention.groupID = 51
    let bold = entity(.bold, 5, 2)
    let entities = MessageEntities.with { $0.entities = [group, bold] }
    let editable = MessageMarkdown.editableText(text: text, entities: entities, configuration: editConfiguration)
    #expect(editable.string == "🙂 @t**ea**m")
    let parsed = ProcessEntities.fromAttributedString(editable)
    #expect(parsed.text == text)
    #expect(parsed.entities.entities.filter { $0.type == .groupMention } == [group])
    #expect(parsed.entities.entities.contains(bold))
  }

  @Test("Partial formatting retains a URL target or bot command routing", arguments: [false, true])
  func editingPartiallyStyledAction(_ isBotCommand: Bool) {
    let label = isBotCommand ? "/start" : "https://example.com/docs"
    let text = "🙂 \(label) done"
    var action = entity(isBotCommand ? .botCommand : .url, 3, label.utf16.count)
    if isBotCommand { action.botCommand.botUserID = 73 }
    let bold = entity(.bold, 5, 2)
    let editable = MessageMarkdown.editableText(
      text: text,
      entities: .with { $0.entities = [action, bold] },
      configuration: editConfiguration
    )
    let parsed = ProcessEntities.fromAttributedString(editable)
    #expect(parsed.text == text)
    #expect(parsed.entities.entities.contains(bold))
    let actions = parsed.entities.entities.filter { [.url, .textURL, .botCommand].contains($0.type) }
    #expect(actions.count == 1)
    #expect(actions.first?.offset == action.offset)
    #expect(actions.first?.length == action.length)
    if isBotCommand {
      #expect(actions.first?.type == .botCommand)
      #expect(actions.first?.botCommand.botUserID == 73)
    } else {
      #expect(actions.first?.type == .textURL)
      #expect(actions.first?.textURL.url == label)
    }
  }

  @Test("Malformed command labels never retain bot routing metadata", arguments: [false, true])
  func invalidEditedCommand(_ parseMarkdown: Bool) {
    let source = NSAttributedString(string: "not a **command**", attributes: [
      .botCommand: "not a command",
      .botCommandTargetUserId: NSNumber(value: 73),
    ])
    let parsed = ProcessEntities.fromAttributedString(source, parseMarkdown: parseMarkdown)
    #expect(parsed.text == (parseMarkdown ? "not a command" : "not a **command**"))
    #expect(!parsed.entities.entities.contains { $0.type == .botCommand })
  }

  @Test("Partial formatting inside a phone number preserves its full entity")
  func editingPartiallyStyledPhone() {
    let text = "+14155550123"
    let phone = entity(.phoneNumber, 0, text.utf16.count)
    let bold = entity(.bold, 2, 3)
    let editable = MessageMarkdown.editableText(
      text: text,
      entities: .with { $0.entities = [phone, bold] },
      configuration: editConfiguration
    )
    #expect(editable.string == "+1**415**5550123")
    let parsed = ProcessEntities.fromAttributedString(editable)
    #expect(parsed.text == text)
    #expect(parsed.entities.entities.filter { $0.type == .phoneNumber } == [phone])
    #expect(parsed.entities.entities.contains(bold))
  }

  @Test("Malformed phone labels do not become phone entities", arguments: [false, true])
  func invalidEditedPhone(_ parseMarkdown: Bool) {
    let source = NSAttributedString(string: "not **a phone**", attributes: [.phoneNumber: "+14155550123"])
    let parsed = ProcessEntities.fromAttributedString(source, parseMarkdown: parseMarkdown)
    #expect(parsed.text == (parseMarkdown ? "not a phone" : "not **a phone**"))
    #expect(!parsed.entities.entities.contains { $0.type == .phoneNumber })
  }

  @Test("Editing code, links, and math exposes syntax and restores entities on send")
  func editingStructuredSyntax() {
    let text = "code docs x^2"
    var link = entity(.textURL, 5, 4)
    link.textURL.url = "https://example.com/docs"
    let code = entity(.code, 0, 4)
    let math = entity(.math, 10, 3)
    let entities = MessageEntities.with { $0.entities = [code, link, math] }
    let editable = MessageMarkdown.editableText(text: text, entities: entities, configuration: editConfiguration)
    #expect(editable.string == "`code` [docs](https://example.com/docs) $x^2$")
    let unparsed = ProcessEntities.fromAttributedString(editable, parseMarkdown: false)
    #expect(!unparsed.entities.entities.contains { [.code, .math, .textURL].contains($0.type) })
    let parsed = ProcessEntities.fromAttributedString(editable)
    #expect(parsed.text == text)
    #expect(parsed.entities.entities.contains(code))
    #expect(parsed.entities.entities.contains(link))
    #expect(parsed.entities.entities.contains(math))
  }

  @Test("Editing a formatted link label with nested brackets preserves its text and target")
  func editingBracketedLinkLabel() {
    let text = "API [v1]"
    var link = entity(.textURL, 0, text.utf16.count)
    link.textURL.url = "https://example.com/docs"
    let bold = entity(.bold, 0, 3)
    let editable = MessageMarkdown.editableText(
      text: text,
      entities: .with { $0.entities = [link, bold] },
      configuration: editConfiguration
    )
    #expect(editable.string == "[**API** [v1]](https://example.com/docs)")
    let parsed = ProcessEntities.fromAttributedString(editable)
    #expect(parsed.text == text)
    #expect(parsed.entities.entities.contains(link))
    #expect(parsed.entities.entities.contains(bold))
  }
}
