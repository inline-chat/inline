import AppKit
import InlineKit
import InlineUI

enum URLPreviewAttachmentLayout {
  enum Mode {
    case compact
    case large
  }

  struct Plan: Equatable, Codable, Hashable {
    var size: NSSize
    var mediaSize: NSSize? = nil
    var largeStyle: UrlPreviewLargeStyle? = nil
  }

  static let cornerRadius: CGFloat = 8
  static let largeCornerRadius: CGFloat = 14
  static let compactVerticalPadding: CGFloat = 4
  static let compactLeadingPadding: CGFloat = 6
  static let compactTrailingPadding: CGFloat = 2
  static let spacing: CGFloat = 7
  static let largeHorizontalPadding: CGFloat = 12
  static let largeVerticalPadding: CGFloat = 10
  static let largeSpacing: CGFloat = 7
  static let authorSpacing: CGFloat = 6
  static let textSpacing: CGFloat = 2
  static let authorTextSpacing: CGFloat = 0
  static let largeTitleTrailingPadding: CGFloat = 14
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

  private static let largeTitleMeasurer = TextMeasurer(font: titleFont)
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
      return Plan(size: NSSize(width: width, height: Theme.urlPreviewCompactHeight))
    case .large:
      let mediaSize = largeMediaSize(for: fullAttachment, width: width)
      let largeStyle = fullAttachment.urlPreview?.largePreviewStyle ?? .standard
      return Plan(
        size: NSSize(width: width, height: largeHeight(for: fullAttachment, width: width, mediaSize: mediaSize)),
        mediaSize: mediaSize,
        largeStyle: largeStyle
      )
    }
  }

  static func largeHeight(for fullAttachment: FullAttachment, width: CGFloat) -> CGFloat {
    largeHeight(
      for: fullAttachment,
      width: width,
      mediaSize: largeMediaSize(for: fullAttachment, width: width)
    )
  }

  private static func largeHeight(
    for fullAttachment: FullAttachment,
    width: CGFloat,
    mediaSize: NSSize
  ) -> CGFloat {
    guard let preview = fullAttachment.urlPreview else { return Theme.urlPreviewCompactHeight }

    let contentWidth = largeContentWidth(for: width)
    let display = preview.largeDisplayContent(maxDescriptionLength: largeDescriptionMaxLength)
    let textHeight = largeTextHeight(display: display, width: contentWidth)
    let authorHeight = largeAuthorHeight(for: fullAttachment, width: contentWidth)
    let middleSpacing = textHeight > 0 && authorHeight > 0 ? largeSpacing : 0
    let contentHeight = textHeight + middleSpacing + authorHeight
    let contentBlockHeight = contentHeight > 0
      ? largeVerticalPadding + contentHeight + largeVerticalPadding
      : 0

    return ceil(
        mediaSize.height +
        contentBlockHeight
    )
  }

  private static func largeTextHeight(display: UrlPreviewLargeDisplayContent, width: CGFloat) -> CGFloat {
    switch display.style {
    case .standard:
      let titleWidth = max(1, width - largeTitleTrailingPadding)
      let titleHeight = display.title.map {
        limitedTextHeight($0, width: titleWidth, measurer: largeTitleMeasurer, font: titleFont, maxLines: largeTitleMaxLines)
      } ?? 0
      let descriptionHeight = display.subtitle.map {
        ceil(largeDescriptionMeasurer.measure($0, width: width).height)
      } ?? 0
      return titleHeight + (titleHeight > 0 && descriptionHeight > 0 ? textSpacing : 0) + descriptionHeight

    case .x:
      return display.body.map {
        ceil(largeDescriptionMeasurer.measure($0, width: width).height)
      } ?? 0
    }
  }

  static func largeAuthorHeight(for fullAttachment: FullAttachment, width: CGFloat) -> CGFloat {
    guard let preview = fullAttachment.urlPreview,
          preview.shouldShowLargePreviewAuthor(hasAuthorPhoto: fullAttachment.authorPhotoInfo != nil)
    else {
      return 0
    }

    let avatarHeight = fullAttachment.authorPhotoInfo == nil ? 0 : authorAvatarSize
    let textWidth = max(1, width - (avatarHeight > 0 ? authorAvatarSize + authorSpacing : 0))
    let display = preview.largeDisplayContent(maxDescriptionLength: largeDescriptionMaxLength)
    let nameHeight = display.authorName.map {
      ceil(authorMeasurer.measure($0, width: textWidth).height)
    } ?? 0
    let subtitleHeight = display.authorSubtitle.map {
      ceil(authorSubtitleMeasurer.measure($0, width: textWidth).height)
    } ?? 0
    let textSpacing: CGFloat = nameHeight > 0 && subtitleHeight > 0 ? authorTextSpacing : 0
    let textHeight = nameHeight + textSpacing + subtitleHeight

    return max(avatarHeight, textHeight)
  }

  static func largeMediaHeight(for fullAttachment: FullAttachment, width: CGFloat) -> CGFloat {
    largeMediaSize(for: fullAttachment, width: width).height
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

  static func largeMediaWidth(for width: CGFloat) -> CGFloat {
    max(1, ceil(width))
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
