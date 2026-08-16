#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

import Foundation

public enum ThreadReferencePasteboard {
  // Preserve the shipped identifier so existing copied space references remain readable.
  private static let type = "chat.inline.space-thread-reference"
  private static let markdownType = "net.daringfireball.markdown"

  struct Content: Equatable {
    let plainText: String
    let inlineData: Data
    let url: URL
    let html: String
    let markdown: String
  }

  @discardableResult
  public static func copy(_ reference: ThreadReference) -> Bool {
    guard let content = content(for: reference) else { return false }

    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(content.plainText, forType: .string)
    item.setData(content.inlineData, forType: NSPasteboard.PasteboardType(type))
    item.setString(content.url.absoluteString, forType: .URL)
    item.setString(content.html, forType: .html)
    item.setString(content.markdown, forType: NSPasteboard.PasteboardType(markdownType))
    return pasteboard.writeObjects([item])
    #elseif os(iOS)
    UIPasteboard.general.setItems([[
      "public.utf8-plain-text": content.plainText,
      type: content.inlineData,
      "public.url": content.url,
      "public.html": content.html,
      markdownType: content.markdown,
    ]])
    return true
    #endif
  }

  #if os(macOS)
  public static func reference(
    from pasteboard: NSPasteboard = .general,
    database: AppDatabase = .shared
  ) -> ThreadReference? {
    guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)),
          let reference = decode(data),
          pasteboard.string(forType: .string) == reference.label,
          isCurrent(reference, database: database)
    else {
      return nil
    }
    return reference
  }
  #elseif os(iOS)
  public static func reference(
    from pasteboard: UIPasteboard = .general,
    database: AppDatabase = .shared
  ) -> ThreadReference? {
    guard let data = pasteboard.data(forPasteboardType: type),
          let reference = decode(data),
          pasteboard.value(forPasteboardType: "public.utf8-plain-text") as? String == reference.label,
          isCurrent(reference, database: database)
    else {
      return nil
    }
    return reference
  }
  #endif

  private static func decode(_ data: Data) -> ThreadReference? {
    guard let reference = try? JSONDecoder().decode(ThreadReference.self, from: data),
          reference.chatId > 0,
          reference.number > 0
    else {
      return nil
    }
    return reference
  }

  static func content(for reference: ThreadReference) -> Content? {
    guard reference.chatId > 0,
          reference.number > 0,
          let inlineData = try? JSONEncoder().encode(reference),
          let url = InlineDeepLink.chat(id: reference.chatId).webURL
    else {
      return nil
    }

    // Rich formats are additive: the exact label remains the plain-text fallback
    // and is also used to validate Inline's app-owned semantic payload on paste.
    let plainText = reference.label
    let absoluteURL = url.absoluteString
    return Content(
      plainText: plainText,
      inlineData: inlineData,
      url: url,
      html: #"<a href="\#(absoluteURL)">\#(plainText)</a>"#,
      markdown: "[\(plainText)](\(absoluteURL))"
    )
  }

  static func isCurrent(_ reference: ThreadReference, database: AppDatabase) -> Bool {
    (try? database.reader.read { db in
      try Chat.fetchOne(db, id: reference.chatId)?.threadReference == reference
    }) == true
  }
}
