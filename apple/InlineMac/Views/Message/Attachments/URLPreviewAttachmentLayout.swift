import AppKit
import InlineKit
import InlineUI

enum URLPreviewAttachmentLayout {
  enum Mode: Codable, Hashable {
    case compact
    case large
  }

  struct Plan: Equatable, Codable, Hashable {
    var size: NSSize
    var mode: Mode
    var compact: CompactPlan? = nil
    var large: LargePlan? = nil
    var mediaSize: NSSize? = nil
    var largeStyle: UrlPreviewLargeStyle? = nil
  }

  struct Frame: Equatable, Codable, Hashable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var rect: NSRect {
      NSRect(x: x, y: y, width: width, height: height)
    }
  }

  struct CompactPlan: Equatable, Codable, Hashable {
    var backgroundFrame: Frame
    var accentFrame: Frame
    var imageFrame: Frame?
    var titleFrame: Frame
    var descriptionFrame: Frame?
    var providerPlaceholderFrame: Frame?
    var playOverlayFrame: Frame?
    var playIconFrame: Frame?
  }

  struct LargePlan: Equatable, Codable, Hashable {
    var backgroundFrame: Frame
    var mediaFrame: Frame?
    var titleFrame: Frame?
    var descriptionFrame: Frame?
    var authorAvatarFrame: Frame?
    var authorNameFrame: Frame?
    var authorSubtitleFrame: Frame?
    var providerPlaceholderFrame: Frame?
    var playOverlayFrame: Frame?
    var playIconFrame: Frame?
  }

  static let cornerRadius: CGFloat = 8
  static let largeCornerRadius: CGFloat = 14
  static let compactVerticalPadding: CGFloat = 4
  static let compactLeadingPadding: CGFloat = 6
  static let compactTrailingPadding: CGFloat = 2
  static let spacing: CGFloat = 7
  static let largeHorizontalPadding: CGFloat = 12
  static let largeVerticalPadding: CGFloat = 10
  static let largeSpacing: CGFloat = 6
  static let authorSpacing: CGFloat = 6
  static let textSpacing: CGFloat = 2
  static let authorTextSpacing: CGFloat = 0
  static let largeTextTrailingPadding: CGFloat = 14
  static let accentWidth: CGFloat = 3
  static let imageCornerRadius: CGFloat = 6
  static let playOverlaySize: CGFloat = 34
  static let playIconSize: CGFloat = 14
  static let providerPlaceholderSize: CGFloat = 24
  static let authorAvatarSize: CGFloat = 26
  static let compactDescriptionMaxLength = 110
  static let largeDescriptionMaxLength = 420
  static let largeTitleMaxLines = 2
  static let defaultLargeAspectRatio: CGFloat = 16.0 / 9.0
  static let largeMediaMaxHeight: CGFloat = 300

  static let titleFont: NSFont = .systemFont(ofSize: 13, weight: .medium)
  static let authorFont: NSFont = .systemFont(ofSize: 12, weight: .medium)
  static let authorSubtitleFont: NSFont = .systemFont(ofSize: 11)
  static let compactDescriptionFont: NSFont = .systemFont(ofSize: 12)
  static let largeDescriptionFont: NSFont = Theme.messageTextFont

  private static let compactTitleMeasurer = TextMeasurer(font: titleFont, lineBreakMode: .byTruncatingTail)
  private static let largeTitleMeasurer = TextMeasurer(font: titleFont)
  private static let compactDescriptionMeasurer = TextMeasurer(font: compactDescriptionFont, lineBreakMode: .byTruncatingTail)
  private static let authorMeasurer = TextMeasurer(font: authorFont, lineBreakMode: .byTruncatingTail)
  private static let authorSubtitleMeasurer = TextMeasurer(font: authorSubtitleFont, lineBreakMode: .byTruncatingTail)
  private static let largeDescriptionMeasurer = TextMeasurer(font: largeDescriptionFont)

  static func mode(for fullAttachment: FullAttachment) -> Mode {
    guard let preview = fullAttachment.urlPreview else { return .compact }
    return preview.prefersLargeMediaPreview(hasPhoto: fullAttachment.photoInfo != nil) ? .large : .compact
  }

  static func displayContent(for preview: UrlPreview, mode: Mode) -> UrlPreviewDisplayContent {
    preview.displayContent(maxDescriptionLength: mode == .large ? largeDescriptionMaxLength : compactDescriptionMaxLength)
  }

  static func size(for fullAttachment: FullAttachment, width: CGFloat) -> NSSize {
    plan(for: fullAttachment, width: width).size
  }

  static func plan(for fullAttachment: FullAttachment, width: CGFloat) -> Plan {
    switch mode(for: fullAttachment) {
    case .compact:
      let compact = compactPlan(for: fullAttachment, width: width)
      return Plan(
        size: NSSize(width: width, height: Theme.urlPreviewCompactHeight),
        mode: .compact,
        compact: compact
      )
    case .large:
      let large = largePlan(for: fullAttachment, width: width)
      let mediaSize = large.mediaFrame.map { NSSize(width: $0.width, height: $0.height) } ?? .zero
      let largeStyle = fullAttachment.urlPreview?.largePreviewStyle ?? .standard
      return Plan(
        size: NSSize(width: width, height: large.backgroundFrame.height),
        mode: .large,
        large: large,
        mediaSize: mediaSize,
        largeStyle: largeStyle
      )
    }
  }

  static func largeHeight(for fullAttachment: FullAttachment, width: CGFloat) -> CGFloat {
    largePlan(for: fullAttachment, width: width).backgroundFrame.height
  }

  private static func compactPlan(for fullAttachment: FullAttachment, width: CGFloat) -> CompactPlan {
    let height = Theme.urlPreviewCompactHeight
    let display = fullAttachment.urlPreview.map { displayContent(for: $0, mode: .compact) }
    let imageFrame = compactImageFrame(for: fullAttachment, height: height)
    let textX = imageFrame.map { $0.x + $0.width + spacing } ?? (accentWidth + compactLeadingPadding)
    let textWidth = max(1, floor(width - textX - compactTrailingPadding))
    let titleHeight = ceil(compactTitleMeasurer.measure(display?.title ?? "", width: textWidth).height)
    let descriptionHeight = display?.subtitle.map {
      ceil(compactDescriptionMeasurer.measure($0, width: textWidth).height)
    } ?? 0
    let textHeight = titleHeight + (descriptionHeight > 0 ? textSpacing + descriptionHeight : 0)
    let textY = max(compactVerticalPadding, floor((height - textHeight) / 2))
    let titleFrame = frame(x: textX, y: textY, width: textWidth, height: titleHeight)
    let descriptionFrame = descriptionHeight > 0
      ? frame(x: textX, y: textY + titleHeight + textSpacing, width: textWidth, height: descriptionHeight)
      : nil

    return CompactPlan(
      backgroundFrame: frame(x: 0, y: 0, width: width, height: height),
      accentFrame: frame(x: 0, y: 0, width: accentWidth, height: height),
      imageFrame: imageFrame,
      titleFrame: titleFrame,
      descriptionFrame: descriptionFrame,
      providerPlaceholderFrame: imageFrame.map { centeredFrame(size: providerPlaceholderSize, in: $0) },
      playOverlayFrame: imageFrame.map { centeredFrame(size: playOverlaySize, in: $0) },
      playIconFrame: imageFrame.map { centeredFrame(size: playIconSize, in: $0) }
    )
  }

  private static func compactImageFrame(for fullAttachment: FullAttachment, height: CGFloat) -> Frame? {
    guard showsCompactImageFrame(for: fullAttachment) else { return nil }
    let imageSize = max(1, height - (compactVerticalPadding * 2))
    return frame(x: accentWidth + compactLeadingPadding, y: compactVerticalPadding, width: imageSize, height: imageSize)
  }

  private static func showsCompactImageFrame(for fullAttachment: FullAttachment) -> Bool {
    guard let preview = fullAttachment.urlPreview else { return false }
    return fullAttachment.photoInfo != nil || preview.isVideoPreview || preview.isNotionPreview
  }

  private static func largePlan(for fullAttachment: FullAttachment, width: CGFloat) -> LargePlan {
    guard let preview = fullAttachment.urlPreview else {
      let background = frame(x: 0, y: 0, width: width, height: Theme.urlPreviewCompactHeight)
      return LargePlan(backgroundFrame: background)
    }

    let mediaSize = largeMediaSize(for: fullAttachment, width: width)
    let mediaFrame = mediaSize.height > 0 ? frame(x: 0, y: 0, width: mediaSize.width, height: mediaSize.height) : nil
    let contentWidth = largeContentWidth(for: width)
    let contentX = largeHorizontalPadding
    let textWidth = largeTextWidth(for: contentWidth)
    let contentY = mediaSize.height
    let display = preview.largeDisplayContent(maxDescriptionLength: largeDescriptionMaxLength)

    let textPlan = largeTextFrames(display: display, x: contentX, y: contentY + largeVerticalPadding, width: textWidth)
    let authorTextWidth = largeAuthorTextWidth(for: fullAttachment, contentWidth: contentWidth)
    let authorPlan = largeAuthorFrames(
      for: fullAttachment,
      display: display,
      x: contentX,
      y: contentY + largeVerticalPadding + textPlan.height + (textPlan.height > 0 ? largeSpacing : 0),
      textWidth: authorTextWidth
    )
    let middleSpacing = textPlan.height > 0 && authorPlan.height > 0 ? largeSpacing : 0
    let contentHeight = textPlan.height + middleSpacing + authorPlan.height
    let contentBlockHeight = contentHeight > 0 ? largeVerticalPadding + contentHeight + largeVerticalPadding : 0
    let height = ceil(mediaSize.height + contentBlockHeight)
    let backgroundFrame = frame(x: 0, y: 0, width: width, height: height)

    return LargePlan(
      backgroundFrame: backgroundFrame,
      mediaFrame: mediaFrame,
      titleFrame: textPlan.titleFrame,
      descriptionFrame: textPlan.descriptionFrame,
      authorAvatarFrame: authorPlan.avatarFrame,
      authorNameFrame: authorPlan.nameFrame,
      authorSubtitleFrame: authorPlan.subtitleFrame,
      providerPlaceholderFrame: mediaFrame.map { centeredFrame(size: providerPlaceholderSize, in: $0) },
      playOverlayFrame: mediaFrame.map { centeredFrame(size: playOverlaySize, in: $0) },
      playIconFrame: mediaFrame.map { centeredFrame(size: playIconSize, in: $0) }
    )
  }

  private static func largeTextFrames(
    display: UrlPreviewLargeDisplayContent,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat
  ) -> (titleFrame: Frame?, descriptionFrame: Frame?, height: CGFloat) {
    switch display.style {
    case .standard:
      let titleHeight = display.title.map {
        limitedTextHeight($0, width: width, measurer: largeTitleMeasurer, font: titleFont, maxLines: largeTitleMaxLines)
      } ?? 0
      let descriptionHeight = display.subtitle.map {
        ceil(largeDescriptionMeasurer.measure($0, width: width).height)
      } ?? 0
      let titleFrame = titleHeight > 0 ? frame(x: x, y: y, width: width, height: titleHeight) : nil
      let descriptionFrame = descriptionHeight > 0
        ? frame(x: x, y: y + titleHeight + (titleHeight > 0 ? textSpacing : 0), width: width, height: descriptionHeight)
        : nil
      let height = titleHeight + (titleHeight > 0 && descriptionHeight > 0 ? textSpacing : 0) + descriptionHeight
      return (titleFrame, descriptionFrame, height)

    case .x:
      let bodyHeight = display.body.map {
        ceil(largeDescriptionMeasurer.measure($0, width: width).height)
      } ?? 0
      let descriptionFrame = bodyHeight > 0 ? frame(x: x, y: y, width: width, height: bodyHeight) : nil
      return (nil, descriptionFrame, bodyHeight)
    }
  }

  private static func largeAuthorFrames(
    for fullAttachment: FullAttachment,
    display: UrlPreviewLargeDisplayContent,
    x: CGFloat,
    y: CGFloat,
    textWidth: CGFloat
  ) -> (avatarFrame: Frame?, nameFrame: Frame?, subtitleFrame: Frame?, height: CGFloat) {
    guard let preview = fullAttachment.urlPreview,
          preview.shouldShowLargePreviewAuthor(hasAuthorPhoto: fullAttachment.authorPhotoInfo != nil)
    else {
      return (nil, nil, nil, 0)
    }

    let avatarHeight = fullAttachment.authorPhotoInfo == nil ? 0 : authorAvatarSize
    let nameHeight = display.authorName.map {
      ceil(authorMeasurer.measure($0, width: textWidth).height)
    } ?? 0
    let subtitleHeight = display.authorSubtitle.map {
      ceil(authorSubtitleMeasurer.measure($0, width: textWidth).height)
    } ?? 0
    let textSpacing: CGFloat = nameHeight > 0 && subtitleHeight > 0 ? authorTextSpacing : 0
    let textHeight = nameHeight + textSpacing + subtitleHeight
    let height = max(avatarHeight, textHeight)
    let avatarFrame = fullAttachment.authorPhotoInfo == nil
      ? nil
      : frame(x: x, y: y + floor((height - authorAvatarSize) / 2), width: authorAvatarSize, height: authorAvatarSize)
    let textX = avatarFrame.map { $0.x + $0.width + authorSpacing } ?? x
    let textY = y + floor((height - textHeight) / 2)
    let nameFrame = nameHeight > 0 ? frame(x: textX, y: textY, width: textWidth, height: nameHeight) : nil
    let subtitleFrame = subtitleHeight > 0
      ? frame(x: textX, y: textY + nameHeight + textSpacing, width: textWidth, height: subtitleHeight)
      : nil

    return (avatarFrame, nameFrame, subtitleFrame, height)
  }

  static func largeMediaSize(for fullAttachment: FullAttachment, width: CGFloat) -> NSSize {
    guard showsLargeMediaFrame(for: fullAttachment) else {
      return .zero
    }

    let mediaWidth = largeMediaWidth(for: width)
    let height = min(ceil(mediaWidth / mediaAspectRatio(for: fullAttachment)), largeMediaMaxHeight)
    return NSSize(width: mediaWidth, height: height)
  }

  private static func showsLargeMediaFrame(for fullAttachment: FullAttachment) -> Bool {
    guard let preview = fullAttachment.urlPreview else { return false }
    return fullAttachment.photoInfo != nil || preview.isVideoPreview
  }

  static func mediaAspectRatio(for fullAttachment: FullAttachment) -> CGFloat {
    if let preview = fullAttachment.urlPreview,
       preview.isVideoPreview,
       let videoAspectRatio = aspectRatio(width: preview.externalWidth, height: preview.externalHeight)
        ?? aspectRatio(width: preview.embedWidth, height: preview.embedHeight)
    {
      return videoAspectRatio
    }

    if let photoSize = fullAttachment.photoInfo?.bestPhotoSize(),
       let aspectRatio = aspectRatio(width: photoSize.width, height: photoSize.height)
    {
      return aspectRatio
    }

    guard let preview = fullAttachment.urlPreview else { return defaultLargeAspectRatio }
    return aspectRatio(width: preview.externalWidth, height: preview.externalHeight)
      ?? aspectRatio(width: preview.embedWidth, height: preview.embedHeight)
      ?? defaultLargeAspectRatio
  }

  static func largeContentWidth(for width: CGFloat) -> CGFloat {
    max(1, ceil(width - (largeHorizontalPadding * 2)))
  }

  static func largeTextWidth(for contentWidth: CGFloat) -> CGFloat {
    max(1, ceil(contentWidth - largeTextTrailingPadding))
  }

  static func largeAuthorTextWidth(for fullAttachment: FullAttachment, contentWidth: CGFloat) -> CGFloat {
    let hasAvatar = fullAttachment.authorPhotoInfo != nil
    let avatarWidth = hasAvatar ? authorAvatarSize + authorSpacing : 0
    return max(1, ceil(contentWidth - avatarWidth))
  }

  static func largeMediaWidth(for width: CGFloat) -> CGFloat {
    max(1, ceil(width))
  }

  private static func frame(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> Frame {
    Frame(
      x: ceil(x),
      y: ceil(y),
      width: max(0, ceil(width)),
      height: max(0, ceil(height))
    )
  }

  private static func centeredFrame(size: CGFloat, in parent: Frame) -> Frame {
    frame(
      x: parent.x + floor((parent.width - size) / 2),
      y: parent.y + floor((parent.height - size) / 2),
      width: size,
      height: size
    )
  }

  private static func aspectRatio(width: Int?, height: Int?) -> CGFloat? {
    guard let width, let height, width > 0, height > 0 else { return nil }
    return CGFloat(width) / CGFloat(height)
  }

  private static func limitedTextHeight(
    _ text: String,
    width: CGFloat,
    measurer: TextMeasurer,
    font: NSFont,
    maxLines: Int
  ) -> CGFloat {
    let height = ceil(measurer.measure(text, width: width).height)
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    return min(height, lineHeight * CGFloat(maxLines))
  }
}
