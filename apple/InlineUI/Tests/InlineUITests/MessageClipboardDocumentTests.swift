#if os(macOS)
import AppKit
import InlineKit
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("Message clipboard document")
@MainActor
struct MessageClipboardDocumentTests {
  typealias Document = MessageClipboardDocument

  private func entity(_ type: MessageEntity.TypeEnum, _ offset: Int, _ length: Int) -> MessageEntity {
    MessageEntity.with {
      $0.type = type
      $0.offset = Int64(offset)
      $0.length = Int64(length)
    }
  }

  /// "Has bold and a link." with bold and a link.
  private var formatted: Document.Text {
    var link = entity(.textURL, 15, 4)
    link.textURL = .with { $0.url = "https://inline.chat" }
    return .init(string: "Has bold and a link.", entities: [entity(.bold, 4, 4), link])
  }

  private var document: Document {
    Document(blocks: [
      .heading(level: 2, .init(string: "Plan")),
      .paragraph(formatted),
      .listItem(depth: 1, marker: .bullet, .init(string: "Top")),
      .listItem(depth: 2, marker: .bullet, .init(string: "Nested")),
      .listItem(depth: 1, marker: .ordered(1), .init(string: "First")),
      .code(language: "swift", "let x = 1"),
      .quote(.init(string: "Quoted")),
      .table(rows: [[.init(string: "Area"), .init(string: "Owner")], [.init(string: "macOS"), .init(string: "Alex")]], hasHeader: true),
    ])
  }

  @Test("Plain text reads like the screen, with list markers and tab-separated cells")
  func plainText() {
    #expect(document.plainText == """
    Plan

    Has bold and a link.

    • Top
        • Nested
    1. First

    let x = 1

    Quoted

    Area\tOwner
    macOS\tAlex
    """)
  }

  @Test("Markdown keeps headings, inline formatting, nested lists, fences, quotes and tables")
  func markdown() {
    #expect(document.markdown == """
    ## Plan

    Has **bold** and a [link](https://inline.chat).

    - Top
        - Nested
    1. First

    ```swift
    let x = 1
    ```

    > Quoted

    | Area | Owner |
    | --- | --- |
    | macOS | Alex |
    """)
  }

  @Test("HTML is semantic so rich editors rebuild the structure")
  func html() {
    let html = document.html
    #expect(html.contains("<meta charset=\"utf-8\">"))
    #expect(html.contains("<h2>Plan</h2>"))
    #expect(html.contains("<p>Has <strong>bold</strong> and a <a href=\"https://inline.chat\">link</a>.</p>"))
    #expect(html.contains("<ul><li>Top<ul><li>Nested</li></ul></li></ul><ol><li>First</li></ol>"))
    #expect(html.contains("<pre><code class=\"language-swift\">let x = 1</code></pre>"))
    #expect(html.contains("<blockquote><p>Quoted</p></blockquote>"))
    #expect(html.contains("<table><thead><tr><th>Area</th><th>Owner</th></tr></thead><tbody><tr><td>macOS</td><td>Alex</td></tr></tbody></table>"))
  }

  @Test("HTML escapes text and keeps line breaks and code inside plain messages")
  func plainMessageHTML() {
    let text = "a < b\nnext\nprint(1)"
    let document = Document(blocks: [.paragraph(.init(string: text, entities: [entity(.pre, 11, 8)]))])
    #expect(document.html.contains("<p>a &lt; b<br>next</p><pre><code>print(1)</code></pre>"))
  }

  @Test("Sender names sit right above their part")
  func senders() {
    let document = Document(blocks: [
      .sender("Alex"), .paragraph(.init(string: "Hi")),
      .sender("Blair"), .paragraph(.init(string: "Hey")),
    ])
    #expect(document.plainText == "Alex:\nHi\n\nBlair:\nHey")
    #expect(document.markdown == "**Alex:**\nHi\n\n**Blair:**\nHey")
  }

  @Test("Selected parts become blocks; an item selected past its marker has no marker")
  func buildsBlocks() {
    let texts = ["Title", "Top item", "Next", "A", "B"].map { NSAttributedString(string: $0) }
    let roles: [Document.SurfaceRole] = [
      .heading(level: 1), .listItem(depth: 1), .listItem(depth: 1),
      .tableCell(table: 9, row: 0, column: 0, isHeader: true),
      .tableCell(table: 9, row: 0, column: 1, isHeader: true),
    ]
    let parts: [RichTextMultiSurfaceSelection.DocumentPart] = [
      .surface(index: 1, range: NSRange(location: 4, length: 4)),
      .separator("\n"),
      .literal(0),
      .surface(index: 2, range: NSRange(location: 0, length: 4)),
      .surface(index: 3, range: NSRange(location: 0, length: 1)),
      .separator("\t"),
      .surface(index: 4, range: NSRange(location: 0, length: 1)),
    ]
    let blocks = Document.blocks(
      parts: parts,
      surfaceTexts: texts,
      roles: roles,
      literals: [NSAttributedString(string: "2.")],
      literalRoles: [.listMarker(.ordered(2))]
    )
    #expect(blocks == [
      .listItem(depth: 1, marker: nil, .init(string: "item")),
      .listItem(depth: 1, marker: .ordered(2), .init(string: "Next")),
      .table(rows: [[.init(string: "A"), .init(string: "B")]], hasHeader: true),
    ])
  }

  @Test("Rendered fonts and code markers become formatting")
  func renderedText() {
    let rendered = NSMutableAttributedString(string: "bold code", attributes: [.font: NSFont.systemFont(ofSize: 14)])
    rendered.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 4))
    rendered.addAttribute(.inlineCode, value: true, range: NSRange(location: 5, length: 4))
    let types = Set(Document.Text(rendered: rendered).entities.map(\.type))
    #expect(types == [.bold, .code])
  }

  @Test("Copy writes every flavor and composers paste its Markdown with live mentions")
  func clipboardRoundTrip() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    var mention = entity(.mention, 3, 5)
    mention.mention = .with { $0.userID = 41 }
    let document = Document(blocks: [
      .paragraph(.init(string: "cc @Dena now", entities: [mention])),
      .listItem(depth: 1, marker: .bullet, formatted),
    ])
    #expect(MessageClipboard.write(document, to: pasteboard))

    let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
    #expect(types.isSuperset(of: [
      NSPasteboard.PasteboardType.string.rawValue, "net.daringfireball.markdown",
      NSPasteboard.PasteboardType.html.rawValue, NSPasteboard.PasteboardType.rtf.rawValue,
      "chat.inline.message-text",
    ]))
    #expect(pasteboard.string(forType: .string) == document.plainText)
    #expect(pasteboard.string(forType: .init("net.daringfireball.markdown")) == document.markdown)

    let pasted = try #require(MessageClipboard.composerText(
      from: pasteboard,
      configuration: .init(
        font: .systemFont(ofSize: 15), primaryColor: .labelColor, linkColor: .linkColor, convertMentionsToLink: false
      ),
      isKnown: { _ in true }
    ))
    #expect(pasted.string == "cc @Dena now\n\n- Has **bold** and a [link](https://inline.chat).")
    #expect(pasted.attribute(.mentionUserId, at: 3, effectiveRange: nil) as? Int64 == 41)
  }

  @Test("Composers ignore our flavor once another app replaced the Markdown")
  func staleFlavor() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(MessageClipboard.write(Document(blocks: [.paragraph(.init(string: "hi"))]), to: pasteboard))
    pasteboard.setString("changed", forType: .init("net.daringfireball.markdown"))
    #expect(MessageClipboard.composerText(
      from: pasteboard,
      configuration: .init(font: .systemFont(ofSize: 15), primaryColor: .labelColor, linkColor: .linkColor),
      isKnown: { _ in true }
    ) == nil)
  }
}
#endif
