import AppKit
import Foundation
import InlineKit

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
  
  /// Used to allow AppKit make it work
  static let textSafeArea: CGFloat = 0.0
  
//  func calculateSize(for text: String, width: CGFloat) -> NSSize {
//    let cacheKey = "\(text):\(width)" as NSString
//    if let cachedSize = cache.object(forKey: cacheKey)?.sizeValue {
//      return cachedSize
//    }
//
//    textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
//    textContainer.lineFragmentPadding = 0
//
//    let attributedString = NSAttributedString(
//      string: text,
//      attributes: [.font: NSFont.systemFont(ofSize: 14)]
//    )
//    textStorage.setAttributedString(attributedString)
//
//    layoutManager.ensureLayout(for: textContainer)
//    let height = layoutManager.usedRect(for: textContainer).height
//    let size = NSSize(width: width, height: ceil(height))
//
//    cache.setObject(NSValue(size: size), forKey: cacheKey)
//    return size
//  }
  
  func calculateSize(for message: FullMessage, with props: MessageViewProps, tableWidth width: CGFloat) -> NSSize {
    print("table width \(width)")
    let text = message.message.text ?? " "
    
    
    let cacheKey = "\(message.id):\(text):\(props.toString()):\(width)" as NSString
    if let cachedSize = cache.object(forKey: cacheKey)?.sizeValue {
      print("using cached size \(cachedSize)")
      return cachedSize
    }
    
    let availableWidth = width - Theme.messageAvatarSize - Theme.messageHorizontalStackSpacing - Theme.messageSidePadding * 2 - Self.textSafeArea
    
    if availableWidth < 0 {
      print("availableWidth \(availableWidth)")
      return NSSize(width: width, height: 36)
    }
//    - Theme.messageSidePadding * 2
    
    print("availableWidth \(availableWidth)")
    textContainer.size = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
    MessageTextConfiguration.configureTextContainer(textContainer)
    
    let attributedString = NSAttributedString(
      string: text,
      attributes: [.font: MessageTextConfiguration.font]
    )
    textStorage.setAttributedString(attributedString)
    
    layoutManager.ensureLayout(for: textContainer)
    let textHeight = layoutManager.usedRect(for: textContainer).height
    print("text \(text) textHeight \(textHeight)")
    var totalHeight = ceil(textHeight)
    
    if props.firstInGroup {
      totalHeight += Theme.messageNameLabelHeight
      totalHeight += Theme.messageVerticalStackSpacing
    }
    totalHeight += Theme.messageVerticalPadding * 2
    let size = NSSize(width: width, height: totalHeight)
    
    cache.setObject(NSValue(size: size), forKey: cacheKey)
    return size
  }
  
  func invalidateCache() {
    cache.removeAllObjects()
  }
  
  static func getTextViewWidth(for tableWidth: CGFloat) -> CGFloat {
    tableWidth - Theme.messageAvatarSize - Theme.messageHorizontalStackSpacing - Self.textSafeArea
  }
}

enum MessageTextConfiguration {
  static let font = Theme.messageTextFont
  static let lineFragmentPadding = Theme.messageTextLineFragmentPadding
  static let containerInset = Theme.messageTextContainerInset
  
  static func configureTextContainer(_ container: NSTextContainer) {
    container.lineFragmentPadding = lineFragmentPadding
  }
  
  static func configureTextView(_ textView: NSTextView) {
    textView.font = font
    textView.textContainerInset = containerInset
  }
}
