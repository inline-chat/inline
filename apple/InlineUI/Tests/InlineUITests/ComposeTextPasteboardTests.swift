#if os(macOS)
import AppKit
import InlineKit
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("Compose text pasteboard")
@MainActor
struct ComposeTextPasteboardTests {
  private let configuration = ProcessEntities.Configuration(
    font: .systemFont(ofSize: 15),
    primaryColor: .labelColor,
    linkColor: .linkColor,
    convertMentionsToLink: false
  )

  private func draft() -> NSAttributedString {
    let text = NSMutableAttributedString(string: "cc @Dena and @team ok")
    text.addAttributes([.mentionUserId: Int64(41), .mentionAgentId: Int64(42)], range: NSRange(location: 3, length: 5))
    text.addAttribute(.mentionGroupId, value: Int64(51), range: NSRange(location: 13, length: 5))
    return text
  }

  @Test("Mentions round trip with their identities and ranges")
  func roundTrip() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let source = draft()
    #expect(ComposeTextPasteboard.copy(source, selection: NSRange(location: 3, length: 15), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "@Dena and @team")

    let pasted = try #require(ComposeTextPasteboard.attributedText(
      from: pasteboard, configuration: configuration, isKnown: { _ in true }
    ))
    #expect(pasted.string == "@Dena and @team")
    #expect(pasted.attribute(.mentionUserId, at: 0, effectiveRange: nil) as? Int64 == 41)
    #expect(pasted.attribute(.mentionAgentId, at: 0, effectiveRange: nil) as? Int64 == 42)
    #expect(pasted.attribute(.mentionGroupId, at: 10, effectiveRange: nil) as? Int64 == 51)

    let sent = ProcessEntities.fromAttributedString(pasted, parseMarkdown: false)
    #expect(sent.entities.entities.contains { $0.type == .mention && $0.offset == 0 && $0.length == 5 })
    #expect(sent.entities.entities.contains { $0.type == .groupMention && $0.offset == 10 && $0.length == 5 })
  }

  @Test("Selections without whole identities use the native copy path")
  func nativeCopyFallback() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let source = draft()
    // Plain words, then a partial mention.
    #expect(!ComposeTextPasteboard.copy(source, selection: NSRange(location: 0, length: 3), to: pasteboard))
    #expect(!ComposeTextPasteboard.copy(source, selection: NSRange(location: 3, length: 3), to: pasteboard))
    #expect(pasteboard.data(forType: .init(ComposeTextPasteboard.type)) == nil)
  }

  @Test("A partial mention beside a whole one loses only its own identity")
  func partialBesideWhole() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(ComposeTextPasteboard.copy(draft(), selection: NSRange(location: 5, length: 13), to: pasteboard))
    let pasted = try #require(ComposeTextPasteboard.attributedText(
      from: pasteboard, configuration: configuration, isKnown: { _ in true }
    ))
    #expect(pasted.string == "ena and @team")
    #expect(pasted.attribute(.mentionUserId, at: 0, effectiveRange: nil) == nil)
    #expect(pasted.attribute(.mentionGroupId, at: 8, effectiveRange: nil) as? Int64 == 51)
  }

  @Test("Unknown targets paste as plain text")
  func unknownTargets() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(ComposeTextPasteboard.copy(draft(), selection: NSRange(location: 3, length: 15), to: pasteboard))
    let pasted = try #require(ComposeTextPasteboard.attributedText(
      from: pasteboard, configuration: configuration, isKnown: { $0.type != .mention }
    ))
    #expect(pasted.string == "@Dena and @team")
    #expect(pasted.attribute(.mentionUserId, at: 0, effectiveRange: nil) == nil)
    #expect(pasted.attribute(.mentionGroupId, at: 10, effectiveRange: nil) as? Int64 == 51)
  }

  @Test("A payload that disagrees with the plain text is ignored")
  func mismatchedPayload() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let payload = try #require(ComposeTextPayload(text: "@Dena", entities: MessageEntities()).encoded())
    let item = NSPasteboardItem()
    item.setString("@Someone", forType: .string)
    item.setData(payload, forType: .init(ComposeTextPasteboard.type))
    #expect(pasteboard.writeObjects([item]))
    #expect(ComposeTextPasteboard.attributedText(
      from: pasteboard, configuration: configuration, isKnown: { _ in true }
    ) == nil)
  }
}
#endif
