import AppKit
import Foundation
import InlineKit
import Logger

// Known issues:
// 1. trailing and leading new lines are not calculated properly

class MessageSizeCalculator {
  static let shared = MessageSizeCalculator()

  private let textStorage: NSTextStorage
  private let layoutManager: NSLayoutManager
  private let textContainer: NSTextContainer
  private let cache = NSCache<NSString, NSValue>()
  private let textHeightCache = NSCache<NSString, NSValue>()
  private let minTextWidthForSingleLine = NSCache<NSString, NSValue>()
  /// cache of last view height for row by id
  private let lastHeightForRow = NSCache<NSString, NSValue>()

  /// Using "" empty string gives a zero height which messes up our layout when somehow an empty text-only message gets
  /// in due to a bug
  private let emptyFallback = " "

  private let log = Log.scoped("MessageSizeCalculator", enableTracing: false)
  private var heightForSingleLine: CGFloat?

  static let safeAreaWidth: CGFloat = 50.0
  static let extraSafeWidth = 0.0

  static let maxMessageWidth: CGFloat = Theme.messageMaxWidth

  init() {
    textStorage = NSTextStorage()
    layoutManager = NSLayoutManager()
    textContainer = NSTextContainer()

    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    MessageTextConfiguration.configureTextContainer(textContainer)
    // TODO: Use message id or a fast hash for the keys instead of text
    cache.countLimit = 5_000
    textHeightCache.countLimit = 5_000
    minTextWidthForSingleLine.countLimit = 5_000
    lastHeightForRow.countLimit = 1_000
  }

  func getAvailableWidth(tableWidth width: CGFloat) -> CGFloat {
    let ceiledWidth = ceil(width)
    let paddings = Theme.messageHorizontalStackSpacing + Theme.messageSidePadding * 2
    let availableWidth: CGFloat = ceiledWidth - paddings - Theme.messageAvatarSize - Self.safeAreaWidth -
      // if we don't subtract this here, it can result is wrong calculations
      Self.extraSafeWidth

    // Ensure we don't return negative width
    return min(max(0.0, availableWidth), Self.maxMessageWidth)
  }

  func getTextWidthIfSingleLine(_ fullMessage: FullMessage, availableWidth: CGFloat) -> CGFloat? {
    // Bypass single line cache for media messages (unless when we have a max width and available width > maxWidth so we
    // know we don't need to recalc. since this function is used in message list to bypass unneccessary calcs.
    guard !fullMessage.hasMedia else { return nil }

    let text = fullMessage.message.text ?? emptyFallback
    let minTextSize = minTextWidthForSingleLine.object(forKey: text as NSString) as? CGSize

    // This is just text size, we need to take bubble paddings into account as well
    // we can probably refactor this to be more maintainable
    if let minTextSize, minTextSize.width < availableWidth {
      return minTextSize.width
    }
    return nil
  }

  func isSingleLine(_ fullMessage: FullMessage, availableWidth: CGFloat) -> Bool {
    getTextWidthIfSingleLine(fullMessage, availableWidth: availableWidth) != nil
  }

  func calculateSize(
    for message: FullMessage,
    with props: MessageViewProps,
    tableWidth width: CGFloat
  ) -> (NSSize, NSSize, NSSize?) {
    let hasText = message.message.text != nil
    let text = message.message.text ?? emptyFallback
    let hasMedia = message.hasMedia
    let hasReply = message.message.repliedToMessageId != nil

    // If text is empty, height is always 1 line
    // Ref: https://inessential.com/2015/02/05/a_performance_enhancement_for_variable-h.html
    if hasText, text.isEmpty, !hasMedia, !hasReply {
      // TODO: fix this to include name, etc
      return (
        CGSize(width: 1, height: heightForSingleLineText()),
        CGSize(width: 1, height: heightForSingleLineText()),
        nil
      )
    }

    // Total available before taking into account photo/video size constraints as they can impact it for the text view.
    // Eg. with a narrow image with 200 width, even if window gives us 500, we should cap at 200.
    let parentAvailableWidth: CGFloat = getAvailableWidth(tableWidth: width)

    // Need it here to cap text size
    var photoSize: CGSize?

    // Add file/photo/video sizes
    if hasMedia {
      let maxMediaSize = CGSize(
        width: Theme.messageMaxWidth,
        height: 310.0
      ) // prevent too big media
      let minMediaSize = CGSize(width: 180.0, height: 20.0) // prevent too narrow media

      var width: CGFloat = 0
      var height: CGFloat = 0

      if let file = message.file {
        width = CGFloat(file.width ?? 0)
        height = CGFloat(file.height ?? 0)
      } else if let photoInfo = message.photoInfo {
        let photo = photoInfo.bestPhotoSize()
        width = CGFloat(photo?.width ?? 0)
        height = CGFloat(photo?.height ?? 0)
      }

      // /start photo
      if message.file?.fileType == .photo || message.photoInfo != nil {
        // do we have width/height?
        if width > 0, height > 0 {
          let aspectRatio = CGFloat(width) / CGFloat(height)
          var mediaWidth: CGFloat
          var mediaHeight: CGFloat

          // for landscape
          let maxAvailableWidth = min(maxMediaSize.width, parentAvailableWidth)

          if width > height {
            mediaWidth = max(
              minMediaSize.width,
              min(CGFloat(width), maxAvailableWidth)
            )
            mediaHeight = mediaWidth / aspectRatio
            if mediaHeight > maxMediaSize.height {
              mediaHeight = maxMediaSize.height
              mediaWidth = mediaHeight * aspectRatio
            }
          } else {
            // for portrait
            mediaHeight = max(
              minMediaSize.height,
              min(CGFloat(height), maxMediaSize.height)
            )
            mediaWidth = mediaHeight * aspectRatio
            if mediaWidth > maxAvailableWidth {
              mediaWidth = maxAvailableWidth
              mediaHeight = mediaWidth / aspectRatio
            }
          }

          photoSize = CGSize(width: mediaWidth, height: mediaHeight)
        } else {
          // use fallback width and height
          photoSize = minMediaSize
        }
        // /end photo
      } else {
        // Unsupported
        
        // todo video
        // todo file
      }
    }

    // What's the available width for the text
    var availableWidth = min(parentAvailableWidth, photoSize?.width ?? parentAvailableWidth)

    if let photoSize {
      // if we have photo, min available width is the photo width
      availableWidth = max(availableWidth, photoSize.width)
    }

    // Highly Experimental:
    // So we get smooth bubble resize but less lag
    // Make available width divisible by 4 to do one fourth of layouting per text
    // availableWidth = floor(availableWidth / 3) * 3

    log.trace("availableWidth \(availableWidth) for text \(text)")
    var textSize: CGSize?

    let cacheKey = "\(message.id):\(props.toString()):\(availableWidth)" as NSString
    if let cachedSize = cache.object(forKey: cacheKey)?.sizeValue,
       let cachedTextSize = textHeightCache.object(forKey: cacheKey)?.sizeValue
    {
      if hasMedia || hasReply { // we can skip reply probably
        // Just use the text size if we have media
        textSize = cachedTextSize
      } else {
        return (cachedSize, cachedTextSize, nil)
      }
    }

    // MARK: Calculate text size

    var cachHitForSingleLine = false

    // Previous local logic
//    if textSize == nil,
//       let minSize = minTextWidthForSingleLine.object(forKey: text as NSString) as? CGSize,
//       minSize.width < availableWidth
//    {
//      log.trace("single line minWidth \(minSize.width) is less than viewport \(width)")
//      cachHitForSingleLine = true
//      textSize = CGSize(width: minSize.width, height: heightForSingleLineText())
//    }

    // Shared logic
    if hasText,
       textSize == nil,
       let minTextWidth = getTextWidthIfSingleLine(message, availableWidth: availableWidth)
    {
      cachHitForSingleLine = true
      textSize = CGSize(width: minTextWidth, height: heightForSingleLineText())
    } else {
      // remove from single line cache. possibly logic can be improved
      minTextWidthForSingleLine.removeObject(forKey: text as NSString)
    }

    if hasText, textSize == nil {
      textSize = calculateSizeForText(text, width: availableWidth, message: message.message)
    }

    let textHeight = ceil(textSize?.height ?? 0.0)
    let textWidth = textSize?.width ?? 0.0
    let textSizeCeiled = CGSize(width: ceil(textWidth), height: ceil(textHeight))

    // Mark as single line if height is equal to single line height
    if hasText, !cachHitForSingleLine, abs(textHeight - heightForSingleLineText()) < 0.5 {
      log.trace("cached single line text \(text) width \(textWidth)")
      minTextWidthForSingleLine.setObject(
        NSValue(size: CGSize(width: textWidth, height: textHeight)),
        forKey: text as NSString
      )
    }

    // MARK: Add other UI element heights to the text

    // don't let it be smaller than that
    var totalHeight = 1.0

    if hasText {
      totalHeight = max(textHeight, heightForSingleLineText())
    }

    // Inter message spacing (between two bubbles vertically)
    totalHeight += Theme.messageOuterVerticalPadding * 2

    if props.firstInGroup {
      totalHeight += Theme.messageNameLabelHeight
      totalHeight += Theme.messageVerticalStackSpacing
      totalHeight += Theme.messageGroupSpacing
    }

    // Add file/photo/video sizes
    if hasMedia {
      if let photoSize {
        totalHeight += photoSize.height
      }

      // Add some padding
      totalHeight += Theme.messageContentViewSpacing
    }

    if hasReply {
      totalHeight += Theme.embeddedMessageHeight
      totalHeight += Theme.messageContentViewSpacing
    }

    let totalWidth = textWidth

    // Fitting width
    let size = NSSize(width: textWidth, height: totalHeight)

    cache.setObject(NSValue(size: size), forKey: cacheKey)
    textHeightCache.setObject(NSValue(size: textSizeCeiled), forKey: cacheKey)
    lastHeightForRow.setObject(NSValue(size: size), forKey: NSString(string: "\(message.id)"))

    return (size, textSizeCeiled, photoSize)
  }

  func cachedSize(messageStableId: Int64) -> CGSize? {
    guard let size = lastHeightForRow.object(forKey: NSString(string: "\(messageStableId)")) as? NSSize
    else { return nil }
    return size
  }

  public func invalidateCache() {
    cache.removeAllObjects()
    textHeightCache.removeAllObjects()
    minTextWidthForSingleLine.removeAllObjects()
    lastHeightForRow.removeAllObjects()
  }

  func heightForSingleLineText() -> CGFloat {
    if let height = heightForSingleLine {
      return height
    } else {
      let text = "I"
      let size = calculateSizeForText(text, width: 1_000)
      heightForSingleLine = size.height
      return size.height
    }
  }

  private func calculateSizeForText(_ text: String, width: CGFloat, message: Message? = nil) -> NSSize {
    textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)

    // See if this actually helps performance or not
    let attributedString = if let message, let attrs = CacheAttrs.shared.get(message: message) {
      attrs
    } else {
      NSAttributedString(
        string: text, // whitespacesAndNewline
        attributes: [.font: MessageTextConfiguration.font]
      )
    }

//    let attributedString = NSAttributedString(
//      string: text, // whitespacesAndNewline
//      attributes: [.font: MessageTextConfiguration.font]
//    )
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
