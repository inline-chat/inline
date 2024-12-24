import AppKit
import Foundation
import InlineKit

// Known issues:
// 1. trailing and leading new lines are not calculated properly

class MessageSizeCalculator {
  private let textStorage: NSTextStorage
  private let layoutManager: NSLayoutManager
  private let textContainer: NSTextContainer
  private let cache = NSCache<NSString, NSValue>()
  private let textHeightCache = NSCache<NSString, NSValue>()
  private let minWidthForSingleLine = NSCache<NSString, NSValue>()
  
  private let log = Log.scoped("MessageSizeCalculator")
  private var heightForSingleLine: CGFloat?
  
  static let safeAreaWidth: CGFloat = 50.0
  static let extraSafeWidth = 1.0

  init() {
    textStorage = NSTextStorage()
    layoutManager = NSLayoutManager()
    textContainer = NSTextContainer()
    
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    
    cache.countLimit = 2000
    textHeightCache.countLimit = 2000
    minWidthForSingleLine.countLimit = 2000
  }
  
  func calculateSize(for message: FullMessage, with props: MessageViewProps, tableWidth width: CGFloat) -> (NSSize, NSSize) {
    let text = message.message.text ?? ""
    
    // If text is empty, height is always 1 line
    // Ref: https://inessential.com/2015/02/05/a_performance_enhancement_for_variable-h.html
    if text.isEmpty {
      // TODO: fix this to include name, etc
      return (
        CGSize(width: 1, height: heightForSingleLineText()),
        CGSize(width: 1, height: heightForSingleLineText())
      )
    }
    
    let availableWidth = ceil(width) - Theme.messageAvatarSize - Theme.messageHorizontalStackSpacing - Theme.messageSidePadding * 2 - Self.safeAreaWidth -
      // if we don't subtract this here, it can result is wrong calculations
      Self.extraSafeWidth
    
    let cacheKey = "\(message.id):\(text):\(props.toString()):\(availableWidth)" as NSString
    if let cachedSize = cache.object(forKey: cacheKey)?.sizeValue, let cachedTextSize = textHeightCache.object(forKey: cacheKey)?.sizeValue {
      return (cachedSize, cachedTextSize)
    }
    
    var textSize: CGSize?
    
    if let minSize = minWidthForSingleLine.object(forKey: text as NSString) as? CGSize, minSize.width < width {
      log.trace("single line minWidth \(minSize.width) is less than viewport \(width)")
      textSize = CGSize(width: minSize.width, height: heightForSingleLineText())
    }
    
    if textSize == nil {
      textSize = calculateSizeForText(text, width: availableWidth)
    }
    
    let textHeight = ceil(textSize!.height)
    let textWidth = textSize!.width
    let textSizeCeiled = CGSize(width: ceil(textWidth), height: ceil(textHeight))
    
    // Mark as single line if height is equal to single line height
    if textHeight == heightForSingleLineText() {
      log.debug("cached single line text \(text) width \(textWidth)")
      minWidthForSingleLine.setObject(NSValue(size: CGSize(width: textWidth, height: textHeight)), forKey: text as NSString)
    }
    
    // don't let it be smaller than that
    var totalHeight = max(textHeight, heightForSingleLineText())
    
    if props.firstInGroup {
      totalHeight += Theme.messageNameLabelHeight
      totalHeight += Theme.messageVerticalStackSpacing
      totalHeight += Theme.messageGroupSpacing
    }
    if props.isLastMessage == true {
      totalHeight += Theme.messageListBottomInset
    }
    if props.isFirstMessage == true {
      totalHeight += Theme.messageListTopInset
    }
    if Theme.messageIsBubble {
      totalHeight += Theme.messageBubblePadding.height * 2
    }
    totalHeight += Theme.messageVerticalPadding * 2
    
    // Fitting width
    let size = NSSize(width: textWidth, height: totalHeight)
    
    cache.setObject(NSValue(size: size), forKey: cacheKey)
    textHeightCache.setObject(NSValue(size: textSizeCeiled), forKey: cacheKey)
  
    return (size, textSizeCeiled)
  }
  
  func invalidateCache() {
    cache.removeAllObjects()
  }

  private func heightForSingleLineText() -> CGFloat {
    if let height = heightForSingleLine {
      return height
    } else {
      let text = "I"
      let size = calculateSizeForText(text, width: 1000)
      heightForSingleLine = size.height
      return size.height
    }
  }
  
  private func calculateSizeForText(_ text: String, width: CGFloat) -> NSSize {
    textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
    MessageTextConfiguration.configureTextContainer(textContainer)
    
    let attributedString = NSAttributedString(
      string: text.trimmingCharacters(in: .whitespacesAndNewlines),
      attributes: [.font: MessageTextConfiguration.font]
    )
    textStorage.setAttributedString(attributedString)
    layoutManager.ensureLayout(for: textContainer)
    // Get the glyphRange to ensure we're measuring all content
//    let glyphRange = layoutManager.glyphRange(for: textContainer)
//    let textRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    
    // Alternative
    let textRect = layoutManager.usedRect(for: textContainer)

    let textHeight = ceil(textRect.height)
    let textWidth = textRect.width + Self.extraSafeWidth
    
    log.trace("calculateSizeForText \(text) width \(width) resulting in rect \(textRect)")
    
    return CGSize(width: textWidth, height: textHeight)
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
