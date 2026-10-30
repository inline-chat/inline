import Foundation
import InlineKit
import InlineProtocol

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Keeps mention and thread identity when text moves between Inline composers.
/// Selections without identity keep the native copy path.
@MainActor
public enum ComposeTextPasteboard {
  static let type = "chat.inline.compose-text"

  static func content(
    of text: NSAttributedString,
    selection: NSRange
  ) -> (payload: Data, portable: MessageTextPasteboard.Content)? {
    guard selection.location != NSNotFound, selection.length > 0, NSMaxRange(selection) <= text.length else { return nil }
    let selected = NSMutableAttributedString(attributedString: text.attributedSubstring(from: selection))
    guard !selected.string.contains("\u{fffc}") else { return nil }

    // A partially selected label is no longer the name it pointed at, so it copies as plain text.
    let fullRange = NSRange(location: 0, length: text.length)
    for key in [NSAttributedString.Key.mentionUserId, .mentionGroupId, .threadLink] {
      text.enumerateAttribute(key, in: selection, options: []) { value, range, _ in
        guard value != nil else { return }
        var whole = NSRange()
        _ = text.attribute(key, at: range.location, longestEffectiveRange: &whole, in: fullRange)
        guard NSIntersectionRange(whole, selection) != whole else { return }
        let local = NSRange(location: range.location - selection.location, length: range.length)
        for identity in [key, .mentionAgentId, .link] {
          selected.removeAttribute(identity, range: local)
        }
      }
    }

    let extracted = ProcessEntities.fromAttributedString(selected, parseMarkdown: false)
    guard extracted.text == selected.string, extracted.entities.entities.contains(where: carriesIdentity),
          let payload = ComposeTextPayload(text: extracted.text, entities: extracted.entities).encoded()
    else { return nil }
    return (payload, MessageTextPasteboard.content(text: extracted.text, entities: extracted.entities))
  }

  private static func carriesIdentity(_ entity: MessageEntity) -> Bool {
    switch entity.type {
    case .mention, .groupMention, .thread, .threadTitle: true
    default: false
    }
  }

  static func attributedText(
    payload data: Data,
    plainText: String?,
    configuration: ProcessEntities.Configuration,
    isKnown: (MessageEntity) -> Bool
  ) -> NSAttributedString? {
    // The plain flavor is what every other app sees, so a mismatch means the payload is stale or foreign.
    guard let payload = ComposeTextPayload(data: data), payload.text == plainText else { return nil }
    let entities = MessageEntities.with { $0.entities = payload.entities.entities.filter(isKnown) }
    return ProcessEntities.toAttributedString(text: payload.text, entities: entities, configuration: configuration)
  }

  #if os(macOS)
  /// Returns false when the selection should use the native copy path.
  public static func copy(
    _ text: NSAttributedString,
    selection: NSRange,
    to pasteboard: NSPasteboard = .general
  ) -> Bool {
    guard let content = content(of: text, selection: selection) else { return false }
    let item = NSPasteboardItem()
    item.setString(content.portable.plainText, forType: .string)
    item.setData(content.payload, forType: .init(type))
    if let rtf = content.portable.rtf { item.setData(rtf, forType: .rtf) }
    if let html = content.portable.html { item.setData(html, forType: .html) }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }

  public static func attributedText(
    from pasteboard: NSPasteboard = .general,
    configuration: ProcessEntities.Configuration,
    isKnown: (MessageEntity) -> Bool = AppDatabase.shared.containsMentionTarget
  ) -> NSAttributedString? {
    guard let data = pasteboard.data(forType: .init(type)) else { return nil }
    return attributedText(
      payload: data,
      plainText: pasteboard.string(forType: .string),
      configuration: configuration,
      isKnown: isKnown
    )
  }
  #else
  /// Returns false when the selection should use the native copy path.
  public static func copy(
    _ text: NSAttributedString,
    selection: NSRange,
    to pasteboard: UIPasteboard = .general
  ) -> Bool {
    guard let content = content(of: text, selection: selection) else { return false }
    var item: [String: Any] = [
      "public.utf8-plain-text": content.portable.plainText,
      type: content.payload,
    ]
    if let rtf = content.portable.rtf { item["public.rtf"] = rtf }
    if let html = content.portable.html { item["public.html"] = html }
    pasteboard.setItems([item])
    return true
  }

  public static func attributedText(
    from pasteboard: UIPasteboard = .general,
    configuration: ProcessEntities.Configuration,
    isKnown: (MessageEntity) -> Bool = AppDatabase.shared.containsMentionTarget
  ) -> NSAttributedString? {
    guard let data = pasteboard.data(forPasteboardType: type) else { return nil }
    return attributedText(
      payload: data,
      plainText: pasteboard.value(forPasteboardType: "public.utf8-plain-text") as? String,
      configuration: configuration,
      isKnown: isKnown
    )
  }
  #endif
}
