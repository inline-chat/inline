import AppKit
import Foundation

class MessageSizeCalculator {
  private let textStorage: NSTextStorage
  private let layoutManager: NSLayoutManager
  private let textContainer: NSTextContainer
  private let cache = NSCache<NSString, NSValue>()
  
  init() {
    textStorage = NSTextStorage()
    layoutManager = NSLayoutManager()
    textContainer = NSTextContainer()
    
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    
    cache.countLimit = 1000
  }
  
  func calculateSize(for text: String, width: CGFloat) -> NSSize {
    let cacheKey = "\(text):\(width)" as NSString
    if let cachedSize = cache.object(forKey: cacheKey)?.sizeValue {
      return cachedSize
    }
    
    textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
    textContainer.lineFragmentPadding = 0
    
    let attributedString = NSAttributedString(
      string: text,
      attributes: [.font: NSFont.systemFont(ofSize: 14)]
    )
    textStorage.setAttributedString(attributedString)
    
    layoutManager.ensureLayout(for: textContainer)
    let height = layoutManager.usedRect(for: textContainer).height
    let size = NSSize(width: width, height: ceil(height))
    
    cache.setObject(NSValue(size: size), forKey: cacheKey)
    return size
  }
  
  func invalidateCache() {
    cache.removeAllObjects()
  }
}

