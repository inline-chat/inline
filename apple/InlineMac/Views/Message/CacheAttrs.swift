import AppKit
import InlineKit
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
    var textCount: Int
    var textHash: Int
    var stableId: Int64
    var entitiesHash: Int?
    var renderStyle: MessageRenderStyle

    var stringValue: String {
      "\(isTranslated ? "T" : "")_\(textCount)_\(textHash)_\(stableId)_\(entitiesHash)_\(renderStyle.rawValue)"
    }
  }

  func getKey(_ message: FullMessage, renderStyle: MessageRenderStyle = .bubble) -> CacheKey {
    CacheKey(
      // TODO: Optimize
      isTranslated: message.translationText != nil,
      textCount: message.displayText?.count ?? 0,
      textHash: message.message.text?.hashValue ?? 0,
      stableId: message.message.stableId,
      entitiesHash: message.message.entities?.hashValue ?? 0,
      renderStyle: renderStyle
    )
  }

  func get(message: FullMessage, renderStyle: MessageRenderStyle = .bubble) -> NSAttributedString? {
    // consider a hash here. // note: need to add ID otherwise messages with same text will be overriding each other
    // styles
    let key = getKey(message, renderStyle: renderStyle)
    return cache.object(forKey: "\(key.stringValue)" as NSString)
  }

  func set(message: FullMessage, renderStyle: MessageRenderStyle = .bubble, value: NSAttributedString) {
    let key = getKey(message, renderStyle: renderStyle)
    cache.setObject(value, forKey: "\(key.stringValue)" as NSString)
  }

  func set(key: String, value: NSAttributedString) {
    cache.setObject(value, forKey: NSString(string: key))
  }

  func invalidate() {
    cache.removeAllObjects()
  }
}
