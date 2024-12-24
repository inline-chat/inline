import AppKit

class CacheAttrs {
  static var shared = CacheAttrs()
  
  let cache: NSCache<NSString, NSAttributedString>
  
  init() {
    cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 1000 // Set appropriate limit
  }
  
  func get(key: String) -> NSAttributedString? {
    cache.object(forKey: NSString(string: key))
  }
  
  func set(key: String, value: NSAttributedString) {
    cache.setObject(value, forKey: NSString(string: key))
  }
  
  func clear() {
    cache.removeAllObjects()
  }
}
