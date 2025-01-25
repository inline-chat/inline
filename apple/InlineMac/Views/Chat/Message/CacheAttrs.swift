import AppKit
import InlineKit

class CacheAttrs {
  static var shared = CacheAttrs()

  let cache: NSCache<NSString, NSAttributedString>

  init() {
    cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 1_000 // Set appropriate limit
  }

  func get(key: String) -> NSAttributedString? {
    cache.object(forKey: NSString(string: key))
  }

  func getKey(_ message: Message) -> String {
    "\(message.text ?? "")___\(message.stableId)"
  }

  func get(message: Message) -> NSAttributedString? {
    // consider a hash here. // note: need to add ID otherwise messages with same text will be overriding each other
    // styles
    let key = getKey(message)
    return cache.object(forKey: NSString(string: key))
  }

  func set(message: Message, value: NSAttributedString) {
    cache.setObject(value, forKey: NSString(string: getKey(message)))
  }

  func set(key: String, value: NSAttributedString) {
    cache.setObject(value, forKey: NSString(string: key))
  }

  func invalidate() {
    cache.removeAllObjects()
  }
}
