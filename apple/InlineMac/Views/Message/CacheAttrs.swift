import AppKit
import InlineKit
import InlineProtocol
import Translation

class CacheAttrs {
  static var shared = CacheAttrs()

  let cache: NSCache<NSString, NSAttributedString>

  init() {
    cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 2_000 // Set appropriate limit
  }

  func get(key: String) -> NSAttributedString? {
    cache.object(forKey: NSString(string: key))
  }

  struct CacheKey: Hashable {
    // TODO: cache language?
    var isTranslated: Bool
    var textSignature: String
    var stableId: Int64
    var entitiesSignature: String
    var richTextSignature: String?
    var renderStyle: MessageRenderStyle
    var styleKey: String

    var stringValue: String {
      "\(isTranslated ? "T" : "")_\(textSignature)_\(stableId)_\(entitiesSignature)_\(richTextSignature ?? "rich-off")_\(renderStyle.rawValue)_\(styleKey)"
    }
  }

  func getKey(_ message: FullMessage, renderStyle: MessageRenderStyle = .bubble, styleKey: String = "") -> CacheKey {
    let rendersOriginalText = message.displayText == message.message.text
    return CacheKey(
      isTranslated: !rendersOriginalText,
      textSignature: MessageRenderCacheSignature.content(for: message),
      stableId: message.message.stableId,
      entitiesSignature: MessageRenderCacheSignature.entities(for: message.message.entities),
      richTextSignature: richTextSignature(for: message, rendersOriginalText: rendersOriginalText),
      renderStyle: renderStyle,
      styleKey: styleKey
    )
  }

  private func richTextSignature(for message: FullMessage, rendersOriginalText: Bool) -> String? {
    guard rendersOriginalText,
          let richText = MessageSizeCalculator.shared.effectiveRichText(for: message)
    else { return nil }

    return richText.stableSignature
  }

  func get(message: FullMessage, renderStyle: MessageRenderStyle = .bubble, styleKey: String = "") -> NSAttributedString? {
    // consider a hash here. // note: need to add ID otherwise messages with same text will be overriding each other
    // styles
    let key = getKey(message, renderStyle: renderStyle, styleKey: styleKey)
    return cache.object(forKey: "\(key.stringValue)" as NSString)
  }

  func set(message: FullMessage, renderStyle: MessageRenderStyle = .bubble, styleKey: String = "", value: NSAttributedString) {
    let key = getKey(message, renderStyle: renderStyle, styleKey: styleKey)
    cache.setObject(value, forKey: "\(key.stringValue)" as NSString)
  }

  func set(key: String, value: NSAttributedString) {
    cache.setObject(value, forKey: NSString(string: key))
  }

  func invalidate() {
    cache.removeAllObjects()
  }
}

enum MessageRenderCacheSignature {
  static func content(for message: FullMessage, fallback: String? = nil) -> String {
    let displayText = message.displayText ?? fallback
    if let translation = message.currentTranslation,
       displayText == translation.translation
    {
      return [
        "t",
        "\(message.id)",
        translation.language,
        "\(translation.msgRev)",
        "\(milliseconds(translation.date))",
        edgeSignature(for: displayText),
        entities(for: translation.entities),
      ].joined(separator: ":")
    }

    return [
      "m",
      "\(message.id)",
      "\(message.message.messageId)",
      "\(message.message.rev)",
      "\(milliseconds(message.message.date))",
      "\(milliseconds(message.message.editDate))",
      edgeSignature(for: displayText),
      entities(for: message.message.entities),
      message.message.hasVoice ? "voice" : "text",
    ].joined(separator: ":")
  }

  static func entities(for entities: MessageEntities?) -> String {
    guard let entities, !entities.entities.isEmpty else { return "0" }
    var hash = fnvOffset
    append(entities.entities.count, to: &hash)
    for entity in entities.entities {
      append(entity.type.rawValue, to: &hash)
      append(entity.offset, to: &hash)
      append(entity.length, to: &hash)
      switch entity.entity {
      case let .mention(value):
        append("mention", to: &hash)
        append(value.userID, to: &hash)
      case let .textURL(value):
        append("textURL", to: &hash)
        append(value.url, to: &hash)
      case let .pre(value):
        append("pre", to: &hash)
        append(value.language, to: &hash)
      case let .thread(value):
        append("thread", to: &hash)
        append(value.chatID, to: &hash)
      case let .threadTitle(value):
        append("threadTitle", to: &hash)
        append(value.spaceID, to: &hash)
        append(value.title, to: &hash)
      case .none:
        append("none", to: &hash)
      }
    }
    return "\(entities.entities.count):\(String(hash, radix: 16))"
  }

  private static func milliseconds(_ date: Date?) -> Int64 {
    guard let date else { return 0 }
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  private static func edgeSignature(for text: String?) -> String {
    guard let text, !text.isEmpty else { return "0:0:0" }
    let prefix = text.prefix(48)
    let suffix = text.suffix(48)
    return "\(text.utf8.count):\(fingerprint(prefix)):\(fingerprint(suffix))"
  }

  private static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
  private static let fnvPrime: UInt64 = 1_099_511_628_211

  private static func fingerprint(_ text: Substring) -> String {
    var hash = fnvOffset
    for byte in text.utf8 {
      update(&hash, byte)
    }
    return String(hash, radix: 16)
  }

  private static func append(_ value: some CustomStringConvertible, to hash: inout UInt64) {
    for byte in value.description.utf8 {
      update(&hash, byte)
    }
    update(&hash, 0xff)
  }

  private static func update(_ hash: inout UInt64, _ byte: UInt8) {
    hash ^= UInt64(byte)
    hash &*= fnvPrime
  }
}
