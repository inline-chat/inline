import AppKit
import InlineKit
import Translation

class CacheAttrs {
  static var shared = CacheAttrs()

  let cache: NSCache<NSString, NSAttributedString>

  init() {
    cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 2_000
    cache.totalCostLimit = 32 * 1_024 * 1_024
  }

  func get(key: String) -> NSAttributedString? {
    cache.object(forKey: NSString(string: key))
  }

  struct CacheKey: Hashable {
    // TODO: cache language?
    var isTranslated: Bool
    var textCount: Int
    var textHash: Int
    var stableId: Int64
    var entitiesHash: Int?
    var renderStyle: MessageRenderStyle
    var styleKey: String

    var stringValue: String {
      "\(isTranslated ? "T" : "")_\(textCount)_\(textHash)_\(stableId)_\(entitiesHash)_\(renderStyle.rawValue)_\(styleKey)"
    }
  }

  func getKey(_ message: FullMessage, renderStyle: MessageRenderStyle = .bubble, styleKey: String = "") -> CacheKey {
    let displayText = message.displayText ?? ""
    let displayEntities = message.translationEntities ?? message.message.entities

    var textHasher = Hasher()
    for byte in displayText.utf8 { textHasher.combine(byte) }

    return CacheKey(
      // TODO: Optimize
      isTranslated: message.translationText != nil,
      textCount: displayText.utf16.count,
      textHash: textHasher.finalize(),
      stableId: message.message.stableId,
      entitiesHash: displayEntities?.hashValue ?? 0,
      renderStyle: renderStyle,
      styleKey: styleKey
    )
  }

  func get(message: FullMessage, renderStyle: MessageRenderStyle = .bubble, styleKey: String = "") -> NSAttributedString? {
    // consider a hash here. // note: need to add ID otherwise messages with same text will be overriding each other
    // styles
    let key = getKey(message, renderStyle: renderStyle, styleKey: styleKey)
    return cache.object(forKey: "\(key.stringValue)" as NSString)
  }

  func set(message: FullMessage, renderStyle: MessageRenderStyle = .bubble, styleKey: String = "", value: NSAttributedString) {
    let key = getKey(message, renderStyle: renderStyle, styleKey: styleKey)
    cache.setObject(
      value,
      forKey: "\(key.stringValue)" as NSString,
      cost: max(128, value.length * 8)
    )
  }

  func set(key: String, value: NSAttributedString) {
    cache.setObject(value, forKey: NSString(string: key), cost: max(128, value.length * 8))
  }

  func invalidate() {
    cache.removeAllObjects()
  }
}
