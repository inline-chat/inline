@testable import InlineIOS
import InlineMessageLayout
import Testing
import TextProcessing
import UIKit

@Suite("Whole rich message copy")
@MainActor
struct MessageWholeCopyTests {
  private func text(_ string: String) -> MessageText {
    MessageText(
      NSAttributedString(string: string, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        .coreTextReady(for: UITraitCollection.current)
    )
  }

  private func paragraph(_ string: String) -> RichBlock { .text(text(string), role: .paragraph) }

  private func wholeCopy(_ blocks: [RichBlock]) throws -> MessageClipboardDocument {
    let layout = try #require(RichLayoutPlanner.layout(blocks, maximumWidth: 320, grid: PixelGrid(scale: 3)))
    let text = try #require(MessageSelectableText.rich(layout, origin: .zero, scrollOffsets: [:], wholeMessage: true))
    return text.clipboardDocument(for: NSRange(location: 0, length: text.length))
  }

  @Test("Headings, list markers, code and tables keep their structure")
  func structure() throws {
    let document = try wholeCopy([
      .text(text("Plan"), role: .heading(level: 2)),
      .list(RichList(items: [
        .init(marker: text("•"), children: [paragraph("First")]),
        .init(marker: text("•"), children: [paragraph("Second")]),
      ])),
      .code(RichCode(text: text("let x = 1"), language: "swift")),
      .table(RichTable(rows: [[text("Name"), text("Count")], [text("Apples"), text("3")]])),
    ])
    #expect(document.markdown.hasPrefix("## Plan\n\n- First\n- Second\n\n```swift\nlet x = 1\n```\n\n| Name | Count |"))
    #expect(document.plainText.contains("• First\n• Second"))
    #expect(document.plainText.hasSuffix("Name\tCount\nApples\t3"))
  }

  @Test("A closed disclosure copies its full summary, and a diff its path and lines")
  func disclosureAndDiff() throws {
    let summary = "Read the three files the test touches and ran the whole suite twice"
    let document = try wholeCopy([
      .disclosure(RichDisclosure(summary: text(summary), children: [paragraph("Hidden detail")], isExpanded: false)),
      .diff(RichDiff(
        symbol: "doc.text",
        path: text("Sources/App.swift"),
        counts: text("+1 −1"),
        body: text("+let a = 1\n-let b = 2"),
        footer: nil
      )),
      paragraph("Done."),
    ])
    let plain = document.plainText
    // Written out in full, though the row cuts it to one line.
    #expect(plain.hasPrefix(summary + "\n\nSources/App.swift"))
    #expect(!plain.contains("Hidden detail"))
    #expect(document.markdown.contains("```diff\n+let a = 1\n-let b = 2\n```"))
    #expect(plain.hasSuffix("Done."))
  }

  @Test("Selection leaves disclosure summaries and diffs out")
  func selectionSkipsThem() throws {
    let layout = try #require(RichLayoutPlanner.layout([
      .disclosure(RichDisclosure(summary: text("Thought for 12s"), children: [], isExpanded: false)),
      paragraph("Answer"),
    ], maximumWidth: 320, grid: PixelGrid(scale: 3)))
    let text = try #require(MessageSelectableText.rich(layout, origin: .zero, scrollOffsets: [:]))
    #expect(text.clipboardDocument(for: NSRange(location: 0, length: text.length)).plainText == "Answer")
  }
}
