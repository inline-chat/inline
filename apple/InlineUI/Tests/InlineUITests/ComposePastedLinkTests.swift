import Foundation
import InlineKit
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("Compose pasted links")
@MainActor
struct ComposePastedLinkTests {
  private let notionURL = "https://app.notion.com/p/example/22222222222242228222222222222222?v=33333333333343338333333333333333&source=copy_link"

  @Test("Mixed text paste finds every URL without a trailing delimiter and keeps UTF-16 offsets")
  func mixedPaste() {
    let source = NSAttributedString(string: "🧭 Delete \(notionURL)\nhttps://example.com")
    let links = ComposeLinkPaste.links(in: source, range: NSRange(location: 0, length: source.length))
    #expect(links.count == 2)
    #expect(links.first?.range.location == ("🧭 Delete " as NSString).length)
    #expect(links.first?.url.absoluteString == notionURL)
    #expect(links.last?.range.upperBound == source.length)
  }

  @Test("Literal and attributed code and explicit labels are not rewritten")
  func protectsCodeAndLabels() {
    let source = NSMutableAttributedString(string: "`https://code.com` https://label.com [Custom](https://markdown.com) https://plain.com")
    source.addAttribute(.link, value: "https://target.com", range: (source.string as NSString).range(of: "https://label.com"))
    let links = ComposeLinkPaste.links(in: source, range: NSRange(location: 0, length: source.length))
    #expect(links.map(\.url.absoluteString) == ["https://plain.com"])
    source.addAttribute(.inlineCode, value: true, range: (source.string as NSString).range(of: "https://plain.com"))
    #expect(ComposeLinkPaste.links(in: source, range: NSRange(location: 0, length: source.length)).isEmpty)
    let math = NSAttributedString(string: "https://example.com", attributes: [NSAttributedString.Key("richTextMath"): true])
    #expect(ComposeLinkPaste.links(in: math, range: NSRange(location: 0, length: math.length)).isEmpty)
  }

  @Test("Send and draft extraction detect raw URLs without duplicating explicit links or code")
  func rawURLExtraction() {
    let source = NSAttributedString(string: "🧭 \(notionURL)")
    for parseMarkdown in [true, false] {
      let result = ProcessEntities.fromAttributedString(source, parseMarkdown: parseMarkdown)
      #expect(result.entities.entities.filter { $0.type == .url }.count == 1)
      #expect(result.entities.entities.first?.offset == 3)
      let code = ProcessEntities.fromAttributedString(NSAttributedString(string: "`\(notionURL)`"), parseMarkdown: parseMarkdown)
      #expect(!code.entities.entities.contains { $0.type == .url || $0.type == .textURL })
    }
    let linked = NSMutableAttributedString(attributedString: source)
    linked.addAttribute(.link, value: notionURL, range: NSRange(location: 3, length: (notionURL as NSString).length))
    #expect(ProcessEntities.fromAttributedString(linked).entities.entities.count == 1)
    let numericURL = "https://example.com/1234567890?email=person@example.com"
    let numericResult = ProcessEntities.fromAttributedString(NSAttributedString(string: numericURL))
    #expect(numericResult.entities.entities.count == 1)
    #expect(numericResult.entities.entities.first?.type == .url)
    #expect(numericResult.entities.entities.first?.length == Int64(numericURL.utf16.count))
  }

  @Test("Separate pastes survive edits before them and deduplicate requests")
  func multiplePastes() async {
    let editor = Editor()
    editor.paste("https://one.com ")
    editor.paste("https://two.com https://one.com")
    await settle()
    #expect(editor.calls.sorted() == ["https://one.com", "https://two.com"])
    editor.edit(NSRange(location: 0, length: 0), "🧭 ")
    editor.finish("https://one.com", label: "One")
    editor.finish("https://two.com", label: "Two")
    await settle()
    #expect(editor.text.string == "🧭 One Two One")
    #expect(editor.selection.location == ("🧭 " as NSString).length)
    editor.selection = NSRange(location: editor.text.length, length: 0)
    #expect(editor.session.revertAtCaret())
    #expect(editor.text.string == "🧭 One Two https://one.com")
    #expect(editor.session.revertLatest())
    #expect(editor.text.string == "🧭 One https://two.com https://one.com")
  }

  @Test("The reported Notion URL keeps its selected view through title conversion and send/draft serialization")
  func notionTitleRoundTrip() async {
    let editor = Editor()
    editor.paste("Delete \(notionURL)")
    await settle()
    editor.finish(notionURL, label: "⏰ Reminders")
    await settle()

    #expect(editor.text.string == "Delete ⏰ Reminders")
    for parseMarkdown in [true, false] {
      let result = ProcessEntities.fromAttributedString(editor.text, parseMarkdown: parseMarkdown)
      let link = result.entities.entities.first
      #expect(result.text == editor.text.string)
      #expect(result.entities.entities.count == 1)
      #expect(link?.type == .textURL)
      #expect(link?.textURL.url == notionURL)
      #expect(link?.offset == 7)
      #expect(link?.length == Int64("⏰ Reminders".utf16.count))
    }
    #expect(editor.session.revertAtCaret())
    #expect(editor.text.string == "Delete \(notionURL)")
  }

  @Test("Send or draft reset rejects late results even when the next draft contains the same URL")
  func resetRejectsLateReply() async {
    let editor = Editor()
    editor.paste(notionURL)
    await settle()
    editor.session.reset()
    editor.text = NSMutableAttributedString(string: notionURL)
    editor.finish(notionURL, label: "Wrong draft")
    await settle()
    #expect(editor.text.string == notionURL)
    #expect(!editor.session.canRevert)
  }

  @Test("Editing a pending URL cancels it without affecting other pasted URLs")
  func editingPendingURL() async {
    let editor = Editor()
    editor.paste("https://one.com https://two.com")
    await settle()
    editor.edit(NSRange(location: ("https://one.com" as NSString).length, length: 0), "/changed")
    editor.finish("https://one.com", label: "Stale")
    editor.finish("https://two.com", label: "Two")
    await settle()
    #expect(editor.text.string == "https://one.com/changed Two")
  }

  @Test("Provider failure leaves an ordinary URL and requests are bounded")
  func boundedAndFailure() async {
    let editor = Editor()
    editor.paste((1...10).map { "https://example.com/\($0)" }.joined(separator: " "))
    await settle()
    #expect(editor.calls.count == 3)
    #expect(!editor.calls.contains("https://example.com/1"))
    editor.finish(editor.calls[0], label: nil)
    await settle()
    #expect(editor.calls.count == 4)
    #expect(editor.text.string.contains("https://example.com/3"))
    editor.session.reset()
    for url in Array(editor.pending.keys) { editor.finish(url, label: nil) }
    await settle()
  }

  @Test("A formatting or link change during resolution cannot turn code or a custom link into a title")
  func protectsEditsDuringLookup() async {
    let editor = Editor()
    editor.paste("https://one.com https://two.com")
    await settle()
    editor.text.addAttribute(.inlineCode, value: true, range: (editor.text.string as NSString).range(of: "https://one.com"))
    editor.text.addAttribute(.link, value: "https://custom.com", range: (editor.text.string as NSString).range(of: "https://two.com"))
    editor.finish("https://one.com", label: "One")
    editor.finish("https://two.com", label: "Two")
    await settle()
    #expect(editor.text.string == "https://one.com https://two.com")
  }

  private func settle() async {
    for _ in 0..<50 { await Task.yield() }
  }

  @MainActor
  private final class Editor {
    var text = NSMutableAttributedString(string: "")
    var selection = NSRange(location: 0, length: 0)
    var calls: [String] = []
    var pending: [String: CheckedContinuation<String?, any Error>] = [:]
    lazy var session = ComposePastedLinkSession(
      snapshot: { [unowned self] in (NSAttributedString(attributedString: text), selection) },
      replace: { [unowned self] range, replacement, selected, _ in
        text.replaceCharacters(in: range, with: replacement)
        selection = selected
        return true
      }
    )

    func paste(_ value: String) {
      let range = NSRange(location: text.length, length: 0)
      edit(range, value)
      let links = ComposeLinkPaste.links(in: text, range: NSRange(location: range.location, length: (value as NSString).length))
      session.pasted(links: links) { [unowned self] url in
        calls.append(url)
        return try await withCheckedThrowingContinuation { pending[url] = $0 }
      }
    }

    func edit(_ range: NSRange, _ value: String) {
      session.willChange(range: range, replacement: value)
      text.replaceCharacters(in: range, with: value)
      selection = NSRange(location: range.location + (value as NSString).length, length: 0)
      session.validate()
    }

    func finish(_ url: String, label: String?) {
      pending.removeValue(forKey: url)?.resume(returning: label)
    }
  }
}
