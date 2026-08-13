import CoreGraphics
import Foundation

/// Pure geometry for Telegram-style document rows. Text measurement stays with the host UI;
/// this type only resolves stable frames from those measurements.
public struct DocumentFileLayoutPlan: Equatable, Sendable {
  public struct MediaInput: Equatable, Sendable {
    public let hasThumbnail: Bool
    public let height: CGFloat
    public let width: CGFloat

    public init(hasThumbnail: Bool, height: CGFloat, width: CGFloat) {
      self.hasThumbnail = hasThumbnail
      self.height = height
      self.width = width
    }
  }

  public struct MetadataInput: Equatable, Sendable {
    public let fileSizeWidth: CGFloat
    public let actionWidth: CGFloat
    public let allowsAction: Bool
    public let showsClose: Bool

    public init(fileSizeWidth: CGFloat, actionWidth: CGFloat, allowsAction: Bool, showsClose: Bool) {
      self.fileSizeWidth = fileSizeWidth
      self.actionWidth = actionWidth
      self.allowsAction = allowsAction
      self.showsClose = showsClose
    }
  }

  public static let iconSize: CGFloat = 36
  public static let thumbnailSize: CGFloat = 70
  public static let thumbnailCornerRadius: CGFloat = 8
  public static let mediaSpacing: CGFloat = 10
  public static let metadataSpacing: CGFloat = 4
  public static let closeButtonSize: CGFloat = 24
  public static let closeReservation: CGFloat = 32
  public static let labelHeight: CGFloat = 16

  public let size: CGSize
  public let mediaFrame: CGRect
  public let iconFrame: CGRect
  public let fileNameFrame: CGRect
  public let fileSizeFrame: CGRect
  public let actionFrame: CGRect
  public let showsAction: Bool
  public let closeFrame: CGRect?

  public static func preferredWidth(
    hasThumbnail: Bool,
    minimumWidth: CGFloat,
    fileNameWidth: CGFloat,
    metadataWidth: CGFloat
  ) -> CGFloat {
    let mediaSize = hasThumbnail ? thumbnailSize : iconSize
    let measuredWidth = mediaSize + mediaSpacing + max(fileNameWidth, metadataWidth)
    return ceil(max(minimumWidth, measuredWidth))
  }

  public static func make(media: MediaInput, metadata: MetadataInput) -> Self {
    let mediaSize = media.hasThumbnail ? thumbnailSize : iconSize
    let mediaFrame = CGRect(
      x: 0,
      y: floor((media.height - mediaSize) / 2),
      width: mediaSize,
      height: mediaSize
    )
    let iconFrame = CGRect(
      x: floor(mediaFrame.midX - iconSize / 2),
      y: floor(mediaFrame.midY - iconSize / 2),
      width: iconSize,
      height: iconSize
    )
    let closeWidth = metadata.showsClose ? closeReservation : 0
    let textX = mediaFrame.maxX + mediaSpacing
    let availableTextWidth = max(0, media.width - textX - closeWidth)
    let centerY = floor(media.height / 2)
    let showsAction = metadata.allowsAction
      && metadata.fileSizeWidth + metadataSpacing + metadata.actionWidth <= availableTextWidth
    let resolvedFileSizeWidth = min(metadata.fileSizeWidth, availableTextWidth)
    let actionX = textX + resolvedFileSizeWidth + metadataSpacing

    return Self(
      size: CGSize(width: media.width, height: media.height),
      mediaFrame: mediaFrame,
      iconFrame: iconFrame,
      fileNameFrame: CGRect(
        x: textX,
        y: centerY + 2,
        width: availableTextWidth,
        height: labelHeight
      ),
      fileSizeFrame: CGRect(
        x: textX,
        y: centerY - labelHeight - 2,
        width: resolvedFileSizeWidth,
        height: labelHeight
      ),
      actionFrame: CGRect(
        x: actionX,
        y: centerY - labelHeight - 3,
        width: showsAction ? metadata.actionWidth : 0,
        height: labelHeight + 4
      ),
      showsAction: showsAction,
      closeFrame: metadata.showsClose
        ? CGRect(
          x: max(0, media.width - closeButtonSize),
          y: floor(centerY - closeButtonSize / 2),
          width: closeButtonSize,
          height: closeButtonSize
        )
        : nil
    )
  }
}
