import AppKit
import Foundation
import InlineKit
import Logger
import TextProcessing
import Translation

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
  // Core Text typographic settings
  private let typographicSettings: [NSAttributedString.Key: Any]

  init() {
    textStorage = NSTextStorage()
    layoutManager = NSLayoutManager()
    textContainer = NSTextContainer()

    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    MessageTextConfiguration.configureTextContainer(textContainer)
    // TODO: Use message id or a fast hash for the keys instead of text
    cache.countLimit = 5_000
    textHeightCache.countLimit = 10_000
    minTextWidthForSingleLine.countLimit = 5_000
    lastHeightForRow.countLimit = 1_000

    // Initialize typographic settings for Core Text
    typographicSettings = [
      .font: MessageTextConfiguration.font,
      // Add any other text attributes needed for consistent rendering
      .paragraphStyle: {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return style
      }(),
    ]

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

    // let text = fullMessage.message.text ?? emptyFallback
    let text = fullMessage.displayText ?? emptyFallback
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

    /// attachments are below text
    var attachmentItems: [LayoutPlan]
    var attachments: LayoutPlan?

    /// reply is always above text
    var reply: LayoutPlan?

    /// reactions
    var reactions: LayoutPlan?

    /// layout for each reaction
    var reactionItems: [String: LayoutPlan]

    /// time can be beside text or below it. it doesn't define vertical spacing.
    var time: LayoutPlan?

    /// used for determining if the message is single line for time view positioning
    var singleLine: Bool
    var emojiMessage: Bool
    var fontSize: CGFloat
    var hasBubbleColor: Bool

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
    var hasReactions: Bool { reactions != nil }
    var hasAttachments: Bool { attachments != nil }

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
      if let reactions {
        reactions.spacing.bottom
      } else if let text {
        text.spacing.bottom
      } else if let photo {
        photo.spacing.bottom
      } else if let document {
        document.spacing.bottom
      } else {
        0.0
      }
    }

    var replyContentTop: CGFloat {
      reply?.spacing.top ?? 0
    }

    var photoContentViewTop: CGFloat {
      var top: CGFloat = photo?.spacing.top ?? 0
      if let reply {
        top += reply.spacing.top + reply.size.height + reply.spacing.bottom
      }
      return top
    }

    var documentContentViewTop: CGFloat {
      var top: CGFloat = document?.spacing.top ?? 0
      if let reply {
        top += reply.spacing.top + reply.size.height + reply.spacing.bottom
      }
      return top
    }

    var textContentViewTop: CGFloat {
      var top: CGFloat = text?.spacing.top ?? 0
      if let reply {
        top += reply.spacing.top + reply.size.height + reply.spacing.bottom
      }
      if let photo {
        top += photo.spacing.top + photo.size.height + photo.spacing.bottom
      }
      if let document {
        top += document.spacing.top + document.size.height + document.spacing.bottom
      }
      return top
    }

    var reactionsViewTop: CGFloat {
      var top: CGFloat = reactions?.spacing.top ?? 0
      if let reply {
        top += reply.spacing.top + reply.size.height + reply.spacing.bottom
      }
      if let photo {
        top += photo.spacing.top + photo.size.height + photo.spacing.bottom
      }
      if let document {
        top += document.spacing.top + document.size.height + document.spacing.bottom
      }
      if let text {
        top += text.spacing.top + text.size.height + text.spacing.bottom
      }
      return top
    }

    var attachmentsContentViewTop: CGFloat {
      var top: CGFloat = attachments?.spacing.top ?? 0
      if let reply {
        top += reply.spacing.top + reply.size.height + reply.spacing.bottom
      }
      if let photo {
        top += photo.spacing.top + photo.size.height + photo.spacing.bottom
      }
      if let document {
        top += document.spacing.top + document.size.height + document.spacing.bottom
      }
      if let text {
        top += text.spacing.top + text.size.height + text.spacing.bottom
      }
      if let reactions {
        top += reactions.spacing.top + reactions.size.height // + reactions.spacing.bottom
      }
      return top
    }

    var nameAndBubbleLeading: CGFloat {
      Theme.messageAvatarSize + Theme.messageHorizontalStackSpacing + Theme.messageSidePadding
    }
  }

  // Use a more efficient cache key
  private func cacheKey(for message: FullMessage, width: CGFloat, props: MessageViewInputProps) -> NSString {
    // Hash-based approach is faster than string concatenation
    let hashValue =
      "\(message.id)_\(message.displayText?.hashValue ?? 0)_\(Int(width))_\(props.toString())_\(message.message.entities?.entities.count ?? 0)"
    return NSString(string: "\(hashValue)")
  }

  private var singleLineDiff = 4.0

  func calculateSize(
    for message: FullMessage,
    with props: MessageViewInputProps,
    tableWidth width: CGFloat
  ) -> (NSSize, NSSize, NSSize?, LayoutPlans) {
    #if DEBUG
    let start = CFAbsoluteTimeGetCurrent()
    #endif

    let hasText = message.message.text != nil
    let text = message.displayText ?? emptyFallback
    let hasMedia = message.hasMedia
    let hasDocument = message.documentInfo != nil
    let hasReply = message.message.repliedToMessageId != nil
    let hasReactions = message.reactions.count > 0
    let hasAttachments = message.attachments.count > 0
    let isOutgoing = message.message.out == true
    var isSingleLine = false
    var isSticker = message.message.isSticker == true
    var textSize: CGSize?
    var photoSize: CGSize?
    let isTextOnly: Bool = hasText && !hasMedia && !hasDocument && !hasAttachments
    let emojiInfo: (count: Int, isAllEmojis: Bool) = isTextOnly ? text.emojiInfo : (0, false)
    // TODO: remove has reply once we confirm reply embed style looks good with emojis
    let emojiMessage = !hasReply && isTextOnly && emojiInfo.isAllEmojis && emojiInfo.count > 0
    let hasBubbleColor = !emojiMessage && !isSticker

    // Font size
    var fontSize: Double = switch emojiInfo {
      case let (count, true) where count == 1:
        Theme.messageTextFontSizeSingleEmoji
      case let (count, true) where count <= 3:
        Theme.messageTextFontSizeThreeEmojis
      case let (count, true):
        Theme.messageTextFontSizeManyEmojis
      default:
        Theme.messageTextFontSize
    }

    // Font - use this for measuring text
    var font: NSFont = MessageTextConfiguration.font.withSize(fontSize)

    // Attributed String
    let attributedString: NSAttributedString
    if let cached = CacheAttrs.shared.get(message: message) {
      attributedString = cached
    } else {
      let processed = ProcessEntities.toAttributedString(
        text: text,
        entities: message.message.entities,
        configuration: .init(
          font: font,
          textColor: MessageViewAppKit.textColor(outgoing: isOutgoing),
          linkColor: MessageViewAppKit.linkColor(outgoing: isOutgoing)
        )
      )
      // cache processed string
      CacheAttrs.shared.set(message: message, value: processed)
      attributedString = processed
    }

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
        width = ceil(CGFloat(file.width ?? 0))
        height = ceil(CGFloat(file.height ?? 0))
      } else if let photoInfo = message.photoInfo {
        let photo = photoInfo.bestPhotoSize()
        width = ceil(CGFloat(photo?.width ?? 0))
        height = ceil(CGFloat(photo?.height ?? 0))
      }
      if message.message.isSticker == true {
        photoSize = calculatePhotoSize(
          width: min(120, width),
          height: min(120, height),
          parentAvailableWidth: parentAvailableWidth,
          hasCaption: hasText
        )
      } else if message.file?.fileType == .photo || message.photoInfo != nil {
        photoSize = calculatePhotoSize(
          width: width,
          height: height,
          parentAvailableWidth: parentAvailableWidth,
          hasCaption: hasText
        )
      }
      // todo video
    }

    // Calculate document width first if we have a document
    var documentWidth: CGFloat?
    if hasDocument {
      // Documents have minimum width but can expand up to parent available width
      // Start with the minimum document width, but don't exceed parent available width
      documentWidth = min(parentAvailableWidth, Theme.documentViewWidth)
    }

    // Calculate attachments width first if we have attachments
    var attachmentsWidth: CGFloat?
    if hasAttachments {
      // Attachments have minimum width but can expand up to parent available width
      // Start with the minimum attachment width, but don't exceed parent available width
      attachmentsWidth = min(parentAvailableWidth, Theme.attachmentViewWidth)
    }

    // What's the available width for the text
    var availableWidth = min(parentAvailableWidth, photoSize?.width ?? parentAvailableWidth)

    if let photoSize {
      // if we have photo, min available width is the photo width
      availableWidth = max(availableWidth, photoSize.width)
    }

    // When we have media that constrains the width, we need to account for bubble padding
    // to ensure text doesn't overflow the bubble bounds
    if hasMedia, let photoSize {
      // Photos strictly constrain text width
      availableWidth = photoSize.width - (Theme.messageBubbleContentHorizontalInset * 2)
    } else if hasDocument {
      // Documents don't restrict text width like photos - text can use full parent width
      availableWidth = parentAvailableWidth - (Theme.messageBubbleContentHorizontalInset * 2)
    }

    #if DEBUG
    log.trace("availableWidth \(availableWidth) for text \(text)")
    #endif

    let cacheKey_ = cacheKey(for: message, width: availableWidth, props: props)
    if let cachedTextSize = textHeightCache.object(forKey: cacheKey_)?.sizeValue {
      textSize = cachedTextSize
      #if DEBUG
      log.trace("text size cache hit \(message.message.messageId)")
      #endif

      if hasText, abs(cachedTextSize.height - heightForSingleLineText()) < singleLineDiff {
        isSingleLine = true
      }
    } else {
      #if DEBUG
      log.trace("text size cache miss \(message.id)")
      #endif
    }

    // MARK: Calculate text size if caches are missed

    // Shared logic
    if hasText,
       textSize == nil,
       !emojiMessage,
       let minTextWidth = getTextWidthIfSingleLine(message, availableWidth: availableWidth)
    {
      #if DEBUG
      log.trace("single line cache hit \(message.id)")
      #endif
      isSingleLine = true
      textSize = CGSize(width: minTextWidth, height: heightForSingleLineText())
    } else {
      // remove from single line cache. possibly logic can be improved
      // FIXME: Optimize this line, it's hit too often with the whole text
      minTextWidthForSingleLine.removeObject(forKey: text as NSString)
    }

    if hasText, textSize == nil {
      let textSize_ = calculateSizeForAttributedString(attributedString, width: availableWidth, message: message)
      textSize = textSize_

      // Cache as single line if height is equal to single line height
      if hasText, abs(textSize_.height - heightForSingleLineText()) < singleLineDiff {
        isSingleLine = true
        minTextWidthForSingleLine.setObject(
          NSValue(size: textSize_),
          forKey: text as NSString
        )
      }
    }

    let textHeight = textSize?.height ?? 0.0
    let textWidth = textSize?.width ?? 0.0

    // Update document width based on content (if we have a document with text)
    if hasDocument, hasText, let currentDocumentWidth = documentWidth {
      // Document can expand to fit text content, but has minimum and maximum bounds
      let textWidthWithPadding = textWidth + (Theme.messageBubbleContentHorizontalInset * 2)
      documentWidth = max(currentDocumentWidth, min(parentAvailableWidth, textWidthWithPadding))
    }

    // Re-evaluate if we are single line based on space left after the text width
    if isSingleLine, textWidth > availableWidth - MessageTimeAndState.timeWidth {
      isSingleLine = false
    }

    // For now, just switch to multiline, later we can fit a few reactions beside the time label
    if isSingleLine, hasReactions {
      isSingleLine = false
    }

    // Force multiline mode for documents without caption text
    if isSingleLine, hasDocument, !hasText {
      isSingleLine = false
    }

    if isSingleLine, hasAttachments {
      isSingleLine = false
    }

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
    var reactionsPlan: LayoutPlan?
    var reactionItemsPlan: [String: LayoutPlan] = [:]
    var timePlan: LayoutPlan?
    var attachmentsPlan: LayoutPlan?
    var attachmentItemsPlans: [LayoutPlan] = []

    // MARK: - Name

    if props.firstInGroup, !isOutgoing, !props.isDM {
      let nameHeight = Theme.messageNameLabelHeight
      namePlan = LayoutPlan(
        size: CGSize(width: 0, height: nameHeight),
        spacing: .init(top: 0, left: 5.0, bottom: 0, right: 0)
      )
    }

    // MARK: - Avatar

    let hasName = namePlan != nil

    if props.firstInGroup {
      avatarPlan = LayoutPlan(
        size: .init(width: Theme.messageAvatarSize, height: Theme.messageAvatarSize),
        spacing: .init(
          top: hasName ? Theme.messageNameLabelHeight : 0,
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
      let textSidePadding = hasBubbleColor ? Theme.messageBubbleContentHorizontalInset : 0

      // If just text
      if !hasMedia, !hasReply {
        textTopSpacing += Theme.messageTextOnlyVerticalInsets
      }

      if isSingleLine {
        textBottomSpacing += Theme.messageTextOnlyVerticalInsets
      } else {
        textBottomSpacing += Theme.messageTextAndTimeSpacing
      }

      // Offset added height to keep bubble height unchanged
      textBottomSpacing -= additionalTextHeight

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

    if hasDocument, let documentWidth {
      documentPlan = LayoutPlan(size: .zero, spacing: .zero)
      // Use the shared document width calculated above
      documentPlan!.size = CGSize(width: documentWidth, height: Theme.documentViewHeight)

      if hasText {
        // documentPlan!.spacing = .bottom(Theme.messageTextAndPhotoSpacing)
        documentPlan!.spacing = NSEdgeInsets(
          top: 8,
          left: Theme.messageBubbleContentHorizontalInset,
          bottom: Theme.messageTextAndPhotoSpacing,
          right: Theme.messageBubbleContentHorizontalInset
        )
      } else {
        documentPlan!.spacing = NSEdgeInsets(
          top: 8,
          left: Theme.messageBubbleContentHorizontalInset,
          bottom: 8,
          right: Theme.messageBubbleContentHorizontalInset
        )
      }
    }

    // MARK: - Attachments

    if hasAttachments, let attachmentsWidth {
      attachmentsPlan = LayoutPlan(size: .zero, spacing: .zero)
      attachmentsPlan!.size = NSSize(width: attachmentsWidth, height: 0)
      attachmentsPlan!.spacing = NSEdgeInsets(
        top: Theme.messageTextAndPhotoSpacing,
        left: Theme.messageBubbleContentHorizontalInset,
        bottom: 4, // between time and attackment
        right: Theme.messageBubbleContentHorizontalInset
      )

      attachmentItemsPlans = message.attachments.map { attachment in
        var attachmentPlan = LayoutPlan(size: .zero, spacing: .zero)

        // Handle different types of attachments
        // External Task (Notion, Linear task, etc)
        if let _ = attachment.externalTask {
          attachmentPlan.size = NSSize(width: attachmentsWidth, height: Theme.externalTaskViewHeight)
          attachmentPlan.spacing = .bottom(Theme.messageAttachmentsSpacing)
        }
        // TODO: Loom

        // Add to total height
        attachmentsPlan!.size.height += attachmentPlan.size.height
        attachmentsPlan!.size.height += attachmentPlan.spacing.bottom

        return attachmentPlan
      }
    }

    // MARK: - Reactions

    if hasReactions {
      reactionsPlan = LayoutPlan(
        size: .zero,
        spacing: NSEdgeInsets(
          top: 8.0,
          left: 8.0,
          bottom: 0.0,
          right: 8.0
        )
      )

      let reactionsSpacing = 6.0
      let reactionSpacing = NSEdgeInsets(
        top: reactionsSpacing,
        left: 0,
        bottom: reactionsSpacing,
        right: reactionsSpacing
      )

      // line index of reactions row
      var reactionsCurrentLine = 0
      var currentLineWidth: CGFloat = 0

      // layout each reaction item
      for reaction in message.groupedReactions {
        let emoji = reaction.emoji
        let reactions = reaction.reactions
        // Get reaction size - this will be replaced with actual calculation later
        let reactionSize = ReactionItem.size(group: reaction)

        // Check if we need to move to next line
        if currentLineWidth + reactionSize.width + reactionsSpacing > availableWidth {
          // go to next line
          reactionsCurrentLine += 1
          currentLineWidth = 0
        }

        // Calculate absolute position in grid based on final line position
        let spacing = NSEdgeInsets(
          top: CGFloat(reactionsCurrentLine) * (reactionSize.height + reactionsSpacing), // Row offset
          left: currentLineWidth, // Column offset
          bottom: 0,
          right: 0
        )

        let reactionPlan = LayoutPlan(
          size: reactionSize,
          spacing: spacing
        )
        reactionItemsPlan[emoji] = reactionPlan

        // Add this reaction to current line
        currentLineWidth += reactionSize.width + reactionsSpacing

        // Update reactions container size
        reactionsPlan!.size.width = max(reactionsPlan!.size.width, currentLineWidth)
        reactionsPlan!.size.height = CGFloat(reactionsCurrentLine + 1) * (reactionSize.height + reactionsSpacing)
      }
    }

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
      //timePlan!.spacing = .init(top: 1.0, left: 9.0, bottom: 5.0, right: 9.0)
      timePlan!.spacing = .init(top: 1.0, left: 0.0, bottom: 5.0, right: 6.0)
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
    if let documentPlan {
      bubbleHeight += documentPlan.size.height
      bubbleHeight += documentPlan.spacing.bottom
      bubbleWidth = max(bubbleWidth, documentPlan.size.width + documentPlan.spacing.horizontalTotal)
    }
    if let attachmentsPlan {
      bubbleHeight += attachmentsPlan.size.height
      bubbleHeight += attachmentsPlan.spacing.top // between text/reactions and attachments
      bubbleHeight += attachmentsPlan.spacing.bottom
      bubbleWidth = max(bubbleWidth, attachmentsPlan.size.width + attachmentsPlan.spacing.horizontalTotal)
    }
    if let reactionsPlan {
      bubbleHeight += reactionsPlan.size.height
      bubbleHeight += reactionsPlan.spacing.bottom
      bubbleWidth = max(bubbleWidth, reactionsPlan.size.width + reactionsPlan.spacing.horizontalTotal)
    }
    if let timePlan {
      if !isSingleLine, hasText {
        bubbleHeight += timePlan.size.height
        bubbleHeight += timePlan.spacing.verticalTotal // ??? probably too much
      }
      if !isSingleLine, hasDocument, !hasText {
        bubbleHeight += timePlan.size.height
      }
      // ensure we have enough width for the time when multiline
      bubbleWidth = max(bubbleWidth, timePlan.size.width + timePlan.spacing.horizontalTotal)
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
      /// Remove extra bubble spacing for now
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
      attachmentItems: attachmentItemsPlans,
      attachments: attachmentsPlan,
      reply: replyPlan,
      reactions: reactionsPlan,
      reactionItems: reactionItemsPlan,
      time: timePlan,
      singleLine: isSingleLine,
      emojiMessage: emojiMessage,
      fontSize: fontSize,
      hasBubbleColor: hasBubbleColor
    )

    // final pass
    plan.bubble.size.height += plan.topMostContentTopSpacing
    plan.wrapper.size.height += plan.topMostContentTopSpacing

    // Fitting width
    let size = NSSize(width: plan.totalWidth, height: plan.totalHeight)

    cache.setObject(NSValue(size: size), forKey: cacheKey_)
    if let textSize {
      textHeightCache.setObject(NSValue(size: textSize), forKey: cacheKey_)
    }
    lastHeightForRow.setObject(NSValue(size: size), forKey: NSString(string: "\(message.id)"))

    return (size, textSize ?? NSSize.zero, photoSize, plan)
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
      #if DEBUG
      log.trace("heightForSingleLine \(heightForSingleLine ?? 0)")
      #endif
      return size.height
    }
  }

//  private func calculateSizeForText(_ text: String, width: CGFloat, message: FullMessage? = nil) -> NSSize {
//    textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)

//    // See if this actually helps performance or not
//    let attributedString = if let message, let attrs = CacheAttrs.shared.get(message: message) {
//      attrs
//    } else {
//      NSAttributedString(
//        string: text, // whitespacesAndNewline
//        attributes: [.font: MessageTextConfiguration.font]
//      )
//    }

//  //    let attributedString = NSAttributedString(
//  //      string: text, // whitespacesAndNewline
//  //      attributes: [.font: MessageTextConfiguration.font]
//  //    )

//    // Use separate text storages https://github.com/lordvisionz/cocoa-string-size-performance
//    let textStorage = NSTextStorage()
//    textStorage.setAttributedString(attributedString)
//    textStorage.addLayoutManager(layoutManager)
//    defer {
//      textStorage.removeLayoutManager(layoutManager)
//    }
//    layoutManager.ensureLayout(for: textContainer)
//    // Get the glyphRange to ensure we're measuring all content
//  //    let glyphRange = layoutManager.glyphRange(for: textContainer)
//  //    let textRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

//    // Alternative
//    let textRect = layoutManager.usedRect(for: textContainer)

//    let textHeight = ceil(textRect.height)
//    let textWidth = ceil(textRect.width) + Self.extraSafeWidth

//    log.trace("calculateSizeForText \(text) width \(width) resulting in rect \(textRect)")

//    return CGSize(width: textWidth, height: textHeight)
//  }

  private func calculateSizeForAttributedString(
    _ attributedString: NSAttributedString,
    width: CGFloat,
    message: FullMessage? = nil
  ) -> NSSize {
    // Create a frame setter with our attributed string
    let frameSetter = CTFramesetterCreateWithAttributedString(attributedString)

    // Calculate the frame size that would fit the text with the given constraints
    let constraintSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    let frameSize = CTFramesetterSuggestFrameSizeWithConstraints(
      frameSetter,
      CFRange(location: 0, length: attributedString.length),
      nil,
      constraintSize,
      nil
    )

    // Add a small amount of padding to account for any rounding errors
    let textWidth = ceil(frameSize.width) + Self.extraSafeWidth
    let textHeight = ceil(frameSize.height) + additionalTextHeight

    #if DEBUG
    log.trace("calculateSizeForText \(attributedString.string) width \(width) resulting in size \(frameSize)")
    #endif

    return CGSize(width: textWidth, height: textHeight)
  }

  /// This is purely used for single height text measurements so it's safe to not use the actual font here.
  private func calculateSizeForText(_ text: String, width: CGFloat) -> NSSize {
    // Create attributed string
    let attributedString = NSAttributedString(
      string: text,
      attributes: typographicSettings
    )

    return calculateSizeForAttributedString(attributedString, width: width, message: nil)
  }

  /// Fixes a bug with the text view height calculation for Chinese text that don't show last line.
  private var additionalTextHeight: CGFloat = 1.0

  func calculatePhotoSize(
    width: CGFloat,
    height: CGFloat,
    parentAvailableWidth: CGFloat,
    hasCaption: Bool
  ) -> CGSize {
    let maxMediaSize = CGSize(
      width: min(320, ceil(parentAvailableWidth)),
      height: min(320, ceil(parentAvailableWidth))
    )
    let minMediaSize = CGSize(width: 40.0, height: 40.0)
    let isLandscape = width > height

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
        if isLandscape {
          mediaWidth = maxMediaSize.width
          mediaHeight = ceil(mediaWidth / aspectRatio)
        } else {
          mediaHeight = maxMediaSize.height
          mediaWidth = ceil(mediaHeight * aspectRatio)
        }
      }
      return CGSize(width: mediaWidth, height: mediaHeight)
    }
    // Has caption, maintain reasonable size

    // handle small images
    if width < maxMediaSize.width, height < maxMediaSize.height {
      mediaWidth = ceil(maxMediaSize.width)
      mediaHeight = ceil(height)
      return CGSize(width: mediaWidth, height: mediaHeight)
    }

    // default
    mediaWidth = maxMediaSize.width
    mediaHeight = ceil(mediaWidth / aspectRatio)

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
