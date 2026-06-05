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
  }

  static let cornerRadius: CGFloat = 8
  static let compactVerticalPadding: CGFloat = 4
  static let compactLeadingPadding: CGFloat = 6
  static let compactTrailingPadding: CGFloat = 2
  static let largePadding: CGFloat = 4
  static let spacing: CGFloat = 7
  static let largeSpacing: CGFloat = 6
  static let textSpacing: CGFloat = 2
  static let accentWidth: CGFloat = 3
  static let playIconSize: CGFloat = 14
  static let providerPlaceholderSize: CGFloat = 24
  static let compactDescriptionMaxLength = 110
  static let largeDescriptionMaxLength = 240
  static let defaultLargeAspectRatio: CGFloat = 16.0 / 9.0
  static let largeMediaMaxHeight: CGFloat = 300

  static let titleFont: NSFont = .systemFont(ofSize: 13, weight: .medium)
  static let compactDescriptionFont: NSFont = .systemFont(ofSize: 12)
  static let largeDescriptionFont: NSFont = Theme.messageTextFont

  private static let titleMeasurer = TextMeasurer(font: titleFont, lineBreakMode: .byTruncatingTail)
  private static let largeDescriptionMeasurer = TextMeasurer(font: largeDescriptionFont)

  static func mode(for fullAttachment: FullAttachment) -> Mode {
    fullAttachment.urlPreview?.isVideoPreview == true && fullAttachment.photoInfo != nil ? .large : .compact
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
      return Plan(
        size: NSSize(width: width, height: largeHeight(for: fullAttachment, width: width, mediaSize: mediaSize)),
        mediaSize: mediaSize
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
    let display = displayContent(for: preview, mode: .large)
    let titleHeight = ceil(titleMeasurer.measure(display.title, width: contentWidth).height)
    let descriptionHeight = display.subtitle.map {
      ceil(largeDescriptionMeasurer.measure($0, width: contentWidth).height)
    } ?? 0
    let textHeight = titleHeight + (descriptionHeight > 0 ? textSpacing + descriptionHeight : 0)

    return ceil(
      largePadding +
        mediaSize.height +
        largeSpacing +
        textHeight +
        largePadding
    )
  }

  static func largeMediaHeight(for fullAttachment: FullAttachment, width: CGFloat) -> CGFloat {
    largeMediaSize(for: fullAttachment, width: width).height
  }

  static func largeMediaSize(for fullAttachment: FullAttachment, width: CGFloat) -> NSSize {
    let contentWidth = largeContentWidth(for: width)
    let height = min(ceil(contentWidth / mediaAspectRatio(for: fullAttachment)), largeMediaMaxHeight)
    return NSSize(width: contentWidth, height: height)
  }

  static func mediaAspectRatio(for fullAttachment: FullAttachment) -> CGFloat {
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
    max(1, ceil(width - accentWidth - (largePadding * 2)))
  }

  private static func aspectRatio(width: Int?, height: Int?) -> CGFloat? {
    guard let width, let height, width > 0, height > 0 else { return nil }
    return CGFloat(width) / CGFloat(height)
  }
}
