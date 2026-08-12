import Foundation
import Testing
@testable import InlineKit

@Suite("External Resource References")
struct ExternalResourceReferenceTests {
  @Test("replacement consumes closing brackets and creates a text link")
  func replacementCreatesTextLink() {
    let source = NSAttributedString(string: "See [[road]]today")
    let resource = ExternalResourceReference(
      id: "notion-roadmap",
      provider: .notion,
      kind: .page,
      title: "Roadmap",
      url: URL(string: "https://www.notion.so/notion-roadmap")!,
      subtitle: "Notion page",
      emoji: "🧭"
    )

    let result = ExternalResourceLinkEditing.replaceReference(
      in: source,
      range: NSRange(location: 4, length: 6),
      with: resource
    )

    #expect(result.newAttributedText.string == "See [[🧭 Roadmap]] today")
    #expect(result.newCursorPosition == ("See [[🧭 Roadmap]] " as NSString).length)
    let link = result.newAttributedText.attribute(
      .link,
      at: 8,
      effectiveRange: nil
    ) as? String
    #expect(link == "https://www.notion.so/notion-roadmap")
  }

  @Test("replacement leaves following text intact without closing brackets")
  func replacementWithoutClosingBrackets() {
    let source = NSAttributedString(string: "[[roadnext")
    let resource = ExternalResourceReference(
      id: "notion-roadmap",
      provider: .notion,
      kind: .page,
      title: "Roadmap",
      url: URL(string: "https://www.notion.so/notion-roadmap")!
    )

    let result = ExternalResourceLinkEditing.replaceReference(
      in: source,
      range: NSRange(location: 0, length: 6),
      with: resource
    )

    #expect(result.newAttributedText.string == "[[Roadmap]] next")
  }
}
