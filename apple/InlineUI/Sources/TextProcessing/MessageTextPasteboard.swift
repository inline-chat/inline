import Foundation
import InlineProtocol

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One clipboard item with native rich text for other apps and editable Markdown for Inline.
@MainActor
public enum MessageTextPasteboard {
  static let markdownType = "net.daringfireball.markdown"
  private static let maximumImportBytes = 4 * 1_024 * 1_024

  struct Content {
    let plainText: String
    let markdown: String
    let rtf: Data?
    let html: Data?
  }

  @discardableResult
  public static func copy(text: String, entities: MessageEntities?) -> Bool {
    write(content(text: text, entities: entities), to: .general)
  }

  static func content(from text: NSAttributedString) -> Content {
    let range = NSRange(location: 0, length: text.length)
    let source = RichTextMath.sourceAttributedText(text, range: range) ?? text
    let extracted = ProcessEntities.fromAttributedString(MessageMarkdown.normalizedText(source), parseMarkdown: false)
    return content(text: extracted.text, entities: extracted.entities)
  }

  static func content(text: String, entities: MessageEntities?) -> Content {
    // Rebuild from semantic entities, excluding chat-specific layout, theme colors and attachments.
    let portable = attributedText(text: text, entities: entities)
    let portableRange = NSRange(location: 0, length: portable.length)
    return Content(
      plainText: text,
      markdown: MessageMarkdown.string(text: text, entities: entities),
      rtf: try? portable.data(from: portableRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
      html: try? portable.data(from: portableRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
    )
  }

  private static func attributedText(text: String, entities: MessageEntities?) -> NSAttributedString {
    ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: PlatformFont.systemFont(ofSize: 16),
        primaryColor: .black,
        linkColor: .blue
      )
    )
  }

  #if os(macOS)
  @discardableResult
  public static func copy(_ text: NSAttributedString, to pasteboard: NSPasteboard = .general) -> Bool {
    write(content(from: text), to: pasteboard)
  }

  private static func write(_ content: Content, to pasteboard: NSPasteboard) -> Bool {
    let item = NSPasteboardItem()
    item.setString(content.plainText, forType: .string)
    item.setString(content.markdown, forType: .init(markdownType))
    if let rtf = content.rtf { item.setData(rtf, forType: .rtf) }
    if let html = content.html { item.setData(html, forType: .html) }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }

  /// Returns nil for ordinary plain text so attachment and URL paste keep their existing behavior.
  public static func markdown(from pasteboard: NSPasteboard = .general) -> String? {
    guard let items = pasteboard.pasteboardItems, items.count == 1, let item = items.first else { return nil }
    if let data = item.data(forType: .init(markdownType)), data.count <= maximumImportBytes,
       let markdown = String(data: data, encoding: .utf8) { return markdown }
    if let data = item.data(forType: .rtf), let markdown = importedMarkdown(data, type: .rtf) { return markdown }
    if let data = item.data(forType: .html), let markdown = importedMarkdown(data, type: .html) { return markdown }
    return nil
  }
  #else
  @discardableResult
  public static func copy(_ text: NSAttributedString, to pasteboard: UIPasteboard = .general) -> Bool {
    write(content(from: text), to: pasteboard)
  }

  private static func write(_ content: Content, to pasteboard: UIPasteboard) -> Bool {
    var item: [String: Any] = [
      "public.utf8-plain-text": content.plainText,
      markdownType: content.markdown,
    ]
    if let rtf = content.rtf { item["public.rtf"] = rtf }
    if let html = content.html { item["public.html"] = html }
    pasteboard.setItems([item])
    return true
  }

  /// Type availability is enough to enable Paste; read content only after the user invokes it.
  public static func containsFormattedText(in pasteboard: UIPasteboard = .general) -> Bool {
    pasteboard.contains(pasteboardTypes: [markdownType, "public.rtf", "public.html"])
  }

  public static func markdown(from pasteboard: UIPasteboard = .general) -> String? {
    guard pasteboard.numberOfItems == 1 else { return nil }
    if let value = pasteboard.value(forPasteboardType: markdownType) {
      if let string = value as? String, string.utf8.count <= maximumImportBytes { return string }
      if let data = value as? Data, data.count <= maximumImportBytes,
         let string = String(data: data, encoding: .utf8) { return string }
    }
    if let data = pasteboard.data(forPasteboardType: "public.rtf"),
       let markdown = importedMarkdown(data, type: .rtf) { return markdown }
    if let value = pasteboard.value(forPasteboardType: "public.html") {
      let data = (value as? Data) ?? (value as? String)?.data(using: .utf8)
      if let data, let markdown = importedMarkdown(data, type: .html) { return markdown }
    }
    return nil
  }
  #endif

  private static func importedMarkdown(_ data: Data, type: NSAttributedString.DocumentType) -> String? {
    guard !data.isEmpty, data.count <= maximumImportBytes,
          let text = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil),
          !text.string.contains("\u{fffc}")
    else { return nil }
    return MessageMarkdown.string(from: text)
  }
}
