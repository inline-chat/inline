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

@Suite("Blockquote composer syntax")
struct BlockquoteMarkdownTests {
  private var editConfiguration: ProcessEntities.Configuration {
    .init(
      font: PlatformFont.systemFont(ofSize: 16),
      primaryColor: .black,
      linkColor: .blue,
      convertMentionsToLink: false
    )
  }

  private func parse(_ source: String) -> (text: String, entities: MessageEntities) {
    ProcessEntities.fromAttributedString(NSAttributedString(string: source))
  }

  private func ranges(_ entities: MessageEntities, _ type: MessageEntity.TypeEnum) -> [NSRange] {
    entities.entities.filter { $0.type == type }.map {
      NSRange(location: Int($0.offset), length: Int($0.length))
    }
  }

  private func edit(_ text: String, _ entities: MessageEntities) -> String {
    MessageMarkdown.editableText(text: text, entities: entities, configuration: editConfiguration).string
  }

  @Test("Quote lines become one blockquote without their prefixes")
  func quoteRun() {
    let parsed = parse("> ship it\n> on Friday\nYes, let's do it")
    #expect(parsed.text == "ship it\non Friday\nYes, let's do it")
    #expect(ranges(parsed.entities, .blockquote) == [NSRange(location: 0, length: 17)])
  }

  @Test("Separate runs make separate quotes")
  func separateRuns() {
    let parsed = parse("> one\nmiddle\n> two")
    #expect(parsed.text == "one\nmiddle\ntwo")
    #expect(ranges(parsed.entities, .blockquote) == [
      NSRange(location: 0, length: 3),
      NSRange(location: 11, length: 3),
    ])
  }

  @Test("A bare > line stays inside the run")
  func bareLine() {
    let parsed = parse("> first\n>\n> second")
    #expect(parsed.text == "first\n\nsecond")
    #expect(ranges(parsed.entities, .blockquote) == [NSRange(location: 0, length: 13)])
  }

  @Test("Text that only looks like a quote stays literal")
  func literals() {
    for source in [">.<", ">_< ok", "a > b", ">\n>", ">>nested"] {
      let parsed = parse(source)
      #expect(parsed.text == source)
      #expect(ranges(parsed.entities, .blockquote).isEmpty)
    }
  }

  @Test("Quote lines inside a code block are code")
  func codeFence() {
    let parsed = parse("```\n> not a quote\n```")
    #expect(parsed.text.contains("> not a quote"))
    #expect(ranges(parsed.entities, .blockquote).isEmpty)
  }

  @Test("Inline styles inside a quote land on the stripped text")
  func stylesInsideQuote() {
    let parsed = parse("> say **hi** to @nobody\nok")
    #expect(parsed.text == "say hi to @nobody\nok")
    #expect(ranges(parsed.entities, .blockquote) == [NSRange(location: 0, length: 17)])
    #expect(ranges(parsed.entities, .bold) == [NSRange(location: 4, length: 2)])
  }

  @Test("Editing restores the quote prefixes")
  func editRoundTrip() {
    for source in [
      "> ship it\n> on Friday\nYes, let's do it",
      "before\n> quoted **bold**\nafter",
      "> first\n>\n> second\nreply",
    ] {
      let parsed = parse(source)
      #expect(edit(parsed.text, parsed.entities) == source)
    }
  }

  @Test("Rich-text editing keeps quotes as prefixes")
  func richTextEdit() {
    let parsed = parse("> quoted\nreply")
    let rich = ProcessEntities.toAttributedString(text: parsed.text, entities: parsed.entities, configuration: editConfiguration)
    let restored = MessageMarkdown.withQuoteSyntax(rich, entities: parsed.entities, attributes: [:])
    #expect(restored.string == "> quoted\nreply")
    #expect(parse(restored.string).entities == parsed.entities)
  }

  @Test("Quote lines for a reply prefix every line")
  func quoteLines() {
    #expect(MessageMarkdown.quoteLines("one\n\ntwo") == "> one\n>\n> two\n")
    let parsed = parse(MessageMarkdown.quoteLines("one\n\ntwo") + "reply")
    #expect(parsed.text == "one\n\ntwo\nreply")
    #expect(ranges(parsed.entities, .blockquote) == [NSRange(location: 0, length: 8)])
  }
}
