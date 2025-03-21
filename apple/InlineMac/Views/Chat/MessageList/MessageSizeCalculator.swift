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

  static let safeAreaWidth: CGFloat = Theme.messageRowSafeAreaInset
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

    prepareForUse()
  }


  // Call when new chat view is initialized
  public func prepareForUse() {
    // Re-call to pick up fresh time format
    MessageTimeAndState.precalculateTimeWidth()
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

  struct LayoutPlan: Equatable, Codable, Hashable {
    var size: NSSize

    /// outer spacings
    var spacing: NSEdgeInsets
  }

  struct LayoutPlans: Equatable, Codable, Hashable {
    /// the outer wrapper of bubble, avatar, and name, currently doesn't define width
    var wrapper: LayoutPlan

    /// name can be present or not, and it's always above bubble
    var name: LayoutPlan?

    /// avatar can be present or not, and it's to the left of the bubble
    var avatar: LayoutPlan?

    /// bubble wraps all the content elements, but it can be hidden for certain messages like stickers or emojis
    var bubble: LayoutPlan

    /// text
    var text: LayoutPlan?

    /// photo is always above text
    var photo: LayoutPlan?

    /// document is always above text, and it's mutually exclusive with other media types
    var document: LayoutPlan?

    /// reply is always above text
    var reply: LayoutPlan?

    /// time can be beside text or below it. it doesn't define vertical spacing.
    var time: LayoutPlan?

    // used for determining if the message is single line for time view positioning
    var singleLine: Bool

    // computed
    var totalHeight: CGFloat {
      var height = wrapper.size.height
      height += wrapper.spacing.verticalTotal
      return height
    }

    var totalWidth: CGFloat {
      var width = wrapper.size.width
      width += wrapper.spacing.horizontalTotal
      return width
    }

    var hasText: Bool { text != nil }
    var hasPhoto: Bool { photo != nil }
    var hasAvatar: Bool { avatar != nil }
    var hasName: Bool { name != nil }
    var hasReply: Bool { reply != nil }
    var hasDocument: Bool { document != nil }

    // used as edge inset for content view stack
    var topMostContentTopSpacing: CGFloat {
      if let reply {
        reply.spacing.top
      } else if let photo {
        photo.spacing.top
      } else if let document {
        document.spacing.top
      } else if let text {
        text.spacing.top
      } else {
        0
      }
    }

    // used as edge inset for content view stack
    var bottomMostContentBottomSpacing: CGFloat {
      if let text {
        text.spacing.bottom
      } else if let photo {
        photo.spacing.bottom
      } else {
        0.0
      }
    }

    var nameAndBubbleLeading: CGFloat {
      Theme.messageAvatarSize + Theme.messageHorizontalStackSpacing + Theme.messageSidePadding
    }
  }

  // Use a more efficient cache key
  private func cacheKey(for message: FullMessage, width: CGFloat, props: MessageViewInputProps) -> NSString {
    // Hash-based approach is faster than string concatenation
    let hashValue = "\(message.id)_\(Int(width))_\(props.hashValue)".hashValue
    return NSString(string: "\(hashValue)")
  }

  func calculateSize(
    for message: FullMessage,
    with props: MessageViewInputProps,
    tableWidth width: CGFloat
  ) -> (NSSize, NSSize, NSSize?, LayoutPlans) {
    let hasText = message.message.text != nil
    let text = message.message.text ?? emptyFallback
    let hasMedia = message.hasMedia
    let hasDocument = message.documentInfo != nil
    let hasReply = message.message.repliedToMessageId != nil
    let isOutgoing = message.message.out == true
    var isSingleLine = false
    var textSize: CGSize?
    var photoSize: CGSize?

    // If text is empty, height is always 1 line
    // Ref: https://inessential.com/2015/02/05/a_performance_enhancement_for_variable-h.html
    if hasText, text.isEmpty {
      textSize = CGSize(width: 1, height: heightForSingleLineText())
      isSingleLine = true
    }

    // Total available before taking into account photo/video size constraints as they can impact it for the text view.
    // Eg. with a narrow image with 200 width, even if window gives us 500, we should cap at 200.
    let parentAvailableWidth: CGFloat = getAvailableWidth(tableWidth: width)

    // Add file/photo/video sizes
    if hasMedia {
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

      if message.file?.fileType == .photo || message.photoInfo != nil {
        photoSize = calculatePhotoSize(
          width: width,
          height: height,
          parentAvailableWidth: parentAvailableWidth,
          hasCaption: hasText
        )
      }
      // todo video
    }

    // What's the available width for the text
    var availableWidth = min(parentAvailableWidth, photoSize?.width ?? parentAvailableWidth)

    if let photoSize {
      // if we have photo, min available width is the photo width
      availableWidth = max(availableWidth, photoSize.width)
    }

    log.trace("availableWidth \(availableWidth) for text \(text)")

    let cacheKey_ = cacheKey(for: message, width: availableWidth, props: props)
    if let cachedSize = cache.object(forKey: cacheKey_)?.sizeValue,
       let cachedTextSize = textHeightCache.object(forKey: cacheKey_)?.sizeValue
    {
      textSize = cachedTextSize

      if hasText, abs(cachedTextSize.height - heightForSingleLineText()) < 0.5 {
        isSingleLine = true
      }
    }

    // MARK: Calculate text size if caches are missed

    // Shared logic
    if hasText,
       textSize == nil,
       let minTextWidth = getTextWidthIfSingleLine(message, availableWidth: availableWidth)
    {
      isSingleLine = true
      textSize = CGSize(width: minTextWidth, height: heightForSingleLineText())
    } else {
      // remove from single line cache. possibly logic can be improved
      minTextWidthForSingleLine.removeObject(forKey: text as NSString)
    }

    if hasText, textSize == nil {
      let textSize_ = calculateSizeForText(text, width: availableWidth, message: message.message)
      textSize = textSize_

      // Cache as single line if height is equal to single line height
      if hasText, abs(textSize_.height - heightForSingleLineText()) < 0.5 {
        isSingleLine = true
        minTextWidthForSingleLine.setObject(
          NSValue(size: textSize_),
          forKey: text as NSString
        )
      }
    }

    let textHeight = ceil(textSize?.height ?? 0.0)
    let textWidth = textSize?.width ?? 0.0
    let textSizeCeiled = CGSize(width: ceil(textWidth), height: ceil(textHeight))

    // MARK: - Layout Plans

    // we prepare our plans and after done with calculations we will use them to calculate the final size
    // some rules:
    // - spacing means outer spacing, so it's additive to the size of the element (it's different from insets)
    // - for content views we add just bottom spacing to all elements, except for the first element in the group which
    // has top as well.
    // - we add left edge spacing to elements stacked together, except for the last element which needs right spacing as
    // well.
    // - we don't set width for most elements, only photo and text that can affact the width of the bubble

    var wrapperPlan = LayoutPlan(size: .zero, spacing: .zero)
    var bubblePlan = LayoutPlan(size: .zero, spacing: .zero)
    var namePlan: LayoutPlan?
    var avatarPlan: LayoutPlan?
    var textPlan: LayoutPlan?
    var photoPlan: LayoutPlan?
    var documentPlan: LayoutPlan?
    var replyPlan: LayoutPlan?
    var timePlan: LayoutPlan?

    // MARK: - Name

    if props.firstInGroup {
      let nameHeight = Theme.messageNameLabelHeight
      namePlan = LayoutPlan(
        size: CGSize(width: 0, height: nameHeight),
        spacing: .init(top: 0, left: 5.0, bottom: 0, right: 0)
      )
    }

    // MARK: - Avatar

    if props.firstInGroup {
      avatarPlan = LayoutPlan(
        size: .init(width: Theme.messageAvatarSize, height: Theme.messageAvatarSize),
        spacing: .init(
          top: Theme.messageNameLabelHeight,
          left: Theme.messageSidePadding,
          bottom: 0,
          right: Theme.messageHorizontalStackSpacing
        )
      )
    }

    // MARK: - Text

    if hasText {
      let textHeight = max(textHeight, heightForSingleLineText())
      var textTopSpacing: CGFloat = 0
      var textBottomSpacing: CGFloat = 0
      let textSidePadding = Theme.messageBubbleContentHorizontalInset

      // If just text
      if !hasMedia, !hasReply {
        textTopSpacing += Theme.messageTextOnlyVerticalInsets
      }

      if isSingleLine {
        textBottomSpacing += Theme.messageTextOnlyVerticalInsets
      } else {
        textBottomSpacing += Theme.messageTextAndTimeSpacing
      }

      textPlan = LayoutPlan(
        size: NSSize(width: ceil(textWidth), height: ceil(textHeight)),
        spacing: NSEdgeInsets(
          top: textTopSpacing,
          left: textSidePadding,
          bottom: textBottomSpacing,
          right: textSidePadding
        )
      )
    }

    // MARK: - Reply

    if hasReply {
      replyPlan = LayoutPlan(size: .zero, spacing: .zero)
      replyPlan!.size.height = Theme.embeddedMessageHeight
      replyPlan!.size.width = 200
      replyPlan!.spacing = .init(
        top: 6.0,
        left: Theme.messageBubbleContentHorizontalInset,
        bottom: 3.0,
        right: Theme.messageBubbleContentHorizontalInset
      )
    }

    // MARK: - Photo

    if let photoSize {
      photoPlan = LayoutPlan(size: .zero, spacing: .zero)
      photoPlan!.size = photoSize

      if hasText {
        photoPlan!.spacing = .bottom(Theme.messageTextAndPhotoSpacing)
      } else {
        photoPlan!.spacing = .zero
      }
    }

    // MARK: - Document

    if hasDocument {
      documentPlan = LayoutPlan(size: .zero, spacing: .zero)
      documentPlan!.size = CGSize(width: 200, height: Theme.documentViewHeight)

      if hasText {
        documentPlan!.spacing = .bottom(Theme.messageTextAndPhotoSpacing)
      } else {
        documentPlan!.spacing = .vertical(Theme.messageBubbleContentHorizontalInset)
      }
    }

    // MARK: - Reactions

    // todo

    // MARK: - Time Size

    timePlan = LayoutPlan(size: .zero, spacing: .zero)
    timePlan!.size = CGSize(
      width: isOutgoing ?
        MessageTimeAndState.timeWidth + MessageTimeAndState.symbolWidth :
        MessageTimeAndState.timeWidth,
      height: Theme.messageTimeHeight
    )

    if isSingleLine {
      timePlan!.spacing = .init(top: 0, left: 0, bottom: 5.0, right: 9.0)
    } else {
      timePlan!.spacing = .init(top: 1.0, left: 9.0, bottom: 5.0, right: 9.0)
    }

    // modify isSignleLine to be false if we have photo or document and text won't fit in a single line with time
    if isSingleLine, let textPlan, let photoPlan {
      let textWidth = textPlan.size.width + textPlan.spacing.horizontalTotal
      let timeWidth = timePlan!.size.width + timePlan!.spacing.horizontalTotal
      let totalWidth = textWidth + timeWidth

      if totalWidth > photoPlan.size.width {
        isSingleLine = false
      }
    }

    // MARK: - Bubble

    var bubbleWidth: CGFloat = 0
    var bubbleHeight: CGFloat = 0

    if let textPlan {
      bubbleHeight += textPlan.size.height
      bubbleHeight += textPlan.spacing.bottom
      bubbleWidth = max(bubbleWidth, textPlan.size.width + textPlan.spacing.horizontalTotal)

      if isSingleLine, let timePlan {
        bubbleWidth = max(bubbleWidth, textPlan.size.width + textPlan.spacing.horizontalTotal + timePlan.size.width)
      }
    }
    if let replyPlan {
      bubbleHeight += replyPlan.size.height
      bubbleHeight += replyPlan.spacing.bottom
      bubbleWidth = max(bubbleWidth, replyPlan.size.width + replyPlan.spacing.horizontalTotal)
    }
    if let photoPlan {
      bubbleHeight += photoPlan.size.height
      bubbleHeight += photoPlan.spacing.bottom
      bubbleWidth = photoPlan.size.width
    }
    if let timePlan {
      if !isSingleLine {
        bubbleHeight += timePlan.size.height
        bubbleHeight += timePlan.spacing.verticalTotal // ??? probably too much
      }
    }

    bubblePlan.size = CGSize(width: bubbleWidth, height: bubbleHeight)
    bubblePlan.spacing = .zero

    // MARK: - Wrapper

    var wrapperWidth: CGFloat = bubblePlan.size.width
    var wrapperHeight: CGFloat = bubblePlan.size.height
    var wrapperTopSpacing: CGFloat = 0

    if let namePlan {
      wrapperHeight += namePlan.size.height
      wrapperHeight += namePlan.spacing.verticalTotal
    }
    if props.firstInGroup {
      wrapperTopSpacing = Theme.messageGroupSpacing
    }
    if let avatarPlan {
      wrapperWidth += avatarPlan.size.width
      wrapperWidth += avatarPlan.spacing.horizontalTotal
    }

    wrapperHeight += bubblePlan.spacing.top
    wrapperHeight += bubblePlan.spacing.bottom

    wrapperPlan.size = CGSize(width: wrapperWidth, height: wrapperHeight)
    wrapperPlan.spacing = .init(
      top: wrapperTopSpacing + Theme.messageOuterVerticalPadding,
      left: 0,
      bottom: Theme.messageOuterVerticalPadding,
      right: 0
    )

    // MARK: - Finalize Layout Plan

    var plan = LayoutPlans(
      wrapper: wrapperPlan,
      name: namePlan,
      avatar: avatarPlan,
      bubble: bubblePlan,
      text: textPlan,
      photo: photoPlan,
      document: documentPlan,
      reply: replyPlan,
      time: timePlan,
      singleLine: isSingleLine
    )

    // final pass
    plan.bubble.size.height += plan.topMostContentTopSpacing
    plan.wrapper.size.height += plan.topMostContentTopSpacing

    // Fitting width
    let size = NSSize(width: plan.totalWidth, height: plan.totalHeight)

    cache.setObject(NSValue(size: size), forKey: cacheKey_)
    textHeightCache.setObject(NSValue(size: textSizeCeiled), forKey: cacheKey_)
    lastHeightForRow.setObject(NSValue(size: size), forKey: NSString(string: "\(message.id)"))

    return (size, textSizeCeiled, photoSize, plan)
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
      let text = "Ij"
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

  func calculatePhotoSize(
    width: CGFloat,
    height: CGFloat,
    parentAvailableWidth: CGFloat,
    hasCaption: Bool
  ) -> CGSize {
    let maxMediaSize = CGSize(
      width: min(320, parentAvailableWidth),
      height: min(320, parentAvailableWidth)
    )
    let minMediaSize = CGSize(width: 40.0, height: 40.0)

    guard width > 0, height > 0 else {
      return minMediaSize
    }

    let aspectRatio = CGFloat(width) / CGFloat(height)
    var mediaWidth: CGFloat
    var mediaHeight: CGFloat

    if !hasCaption {
      if width < maxMediaSize.width, height < maxMediaSize.height {
        mediaWidth = width
        mediaHeight = height
      } else {
        mediaWidth = maxMediaSize.width
        mediaHeight = mediaWidth / aspectRatio
      }
    }
    // Has caption, maintain reasonable size

    // handle small images
    if width < maxMediaSize.width, height < maxMediaSize.height {
      mediaWidth = maxMediaSize.width
      mediaHeight = height
      return CGSize(width: mediaWidth, height: mediaHeight)
    }

    // default
    mediaWidth = maxMediaSize.width
    mediaHeight = mediaWidth / aspectRatio

    if mediaHeight > maxMediaSize.height {
      mediaHeight = maxMediaSize.height
      mediaWidth = maxMediaSize.width
    }

    return CGSize(width: mediaWidth, height: mediaHeight)
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
