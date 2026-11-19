#if os(macOS)
import AppKit
import Foundation
import InlineKit
import InlineProtocol
import UniformTypeIdentifiers

/// Writes copied message content in every standard flavor, so each app takes the richest one
/// it understands: plain text, Markdown, HTML (Notion, Notes, Docs), RTF (TextEdit, Pages), plus
/// Inline's own flavor that composers paste as Markdown with live mentions.
@MainActor
public enum MessageClipboard {
  static let messageTextType = NSPasteboard.PasteboardType("chat.inline.message-text")

  static var markdownType: NSPasteboard.PasteboardType {
    if #available(macOS 27.0, *) { return NSPasteboard.PasteboardType(UTType.markdown.identifier) }
    return NSPasteboard.PasteboardType(MessageTextPasteboard.markdownType)
  }

  @discardableResult
  public static func write(_ document: MessageClipboardDocument, to pasteboard: NSPasteboard = .general) -> Bool {
    guard !document.isEmpty else { return false }
    let portable = document.portable
    let source = document.markdownSource
    let item = NSPasteboardItem()
    item.setString(portable.text, forType: .string)
    item.setString(MessageMarkdown.string(text: source.text, entities: source.entities), forType: markdownType)
    if let html = document.html.data(using: .utf8) { item.setData(html, forType: .html) }
    if let rtf = MessageTextPasteboard.content(text: portable.text, entities: portable.entities).rtf {
      item.setData(rtf, forType: .rtf)
    }
    if let payload = ComposeTextPayload(text: source.text, entities: source.entities).encoded() {
      item.setData(payload, forType: messageTextType)
    }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }

  /// A copied message as composer text: its Markdown, with mentions and thread links kept live.
  public static func composerText(
    from pasteboard: NSPasteboard = .general,
    configuration: ProcessEntities.Configuration,
    isKnown: (MessageEntity) -> Bool = AppDatabase.shared.containsMentionTarget
  ) -> NSAttributedString? {
    guard let data = pasteboard.data(forType: messageTextType),
          let payload = ComposeTextPayload(data: data),
          // Another app may have replaced the Markdown while leaving our flavor behind.
          pasteboard.string(forType: markdownType) == MessageMarkdown.string(text: payload.text, entities: payload.entities)
    else { return nil }
    let entities = MessageEntities.with { $0.entities = payload.entities.entities.filter(isKnown) }
    return MessageMarkdown.editableText(text: payload.text, entities: entities, configuration: configuration)
  }
}
#else
import Foundation
import InlineKit
import InlineProtocol
import UIKit
import UniformTypeIdentifiers

/// Writes copied message content in every standard flavor, as on macOS: plain text, Markdown,
/// HTML and RTF for other apps, plus Inline's own flavor, which a Mac composer pastes through
/// Universal Clipboard with mentions kept live.
@MainActor
public enum MessageClipboard {
  static let messageTextType = "chat.inline.message-text"

  @discardableResult
  public static func write(_ document: MessageClipboardDocument, to pasteboard: UIPasteboard = .general) -> Bool {
    guard !document.isEmpty else { return false }
    let portable = document.portable
    let source = document.markdownSource
    var item: [String: Any] = [
      UTType.utf8PlainText.identifier: portable.text,
      MessageTextPasteboard.markdownType: MessageMarkdown.string(text: source.text, entities: source.entities),
    ]
    if let html = document.html.data(using: .utf8) { item[UTType.html.identifier] = html }
    if let rtf = MessageTextPasteboard.content(text: portable.text, entities: portable.entities).rtf {
      item[UTType.rtf.identifier] = rtf
    }
    if let payload = ComposeTextPayload(text: source.text, entities: source.entities).encoded() {
      item[messageTextType] = payload
    }
    pasteboard.setItems([item])
    return true
  }
}
#endif
