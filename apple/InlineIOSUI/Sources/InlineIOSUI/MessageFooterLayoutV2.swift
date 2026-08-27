import CoreGraphics

public struct MessageFooterLayoutV2: Equatable, Codable, Sendable {
  public struct TrailingTextLine: Equatable, Codable, Sendable {
    public let usedWidth: CGFloat
    public let height: CGFloat
    public let isRTL: Bool

    public init(usedWidth: CGFloat, height: CGFloat, isRTL: Bool) {
      self.usedWidth = usedWidth
      self.height = height
      self.isRTL = isRTL
    }
  }

  public enum Placement: Equatable, Codable, Sendable {
    case inlineMetadata
    case trailingTextLineMetadata
    case metadataBelow
    case reactionsAndMetadataFooter
    case stackedFooter
  }

  public let size: CGSize
  public let textFrame: CGRect
  public let metadataFrame: CGRect
  public let reactionsFrame: CGRect?
  public let placement: Placement
}

public enum MessageFooterLayoutPlannerV2 {
  public static func layout(
    textSize: CGSize,
    metadataSize: CGSize,
    reactionsSize: CGSize?,
    isTextSingleLine: Bool,
    isRTL: Bool = false,
    trailingTextLine: MessageFooterLayoutV2.TrailingTextLine? = nil,
    maximumWidth: CGFloat,
    horizontalSpacing: CGFloat,
    verticalSpacing: CGFloat
  ) -> MessageFooterLayoutV2? {
    guard isValid(textSize),
          isValid(metadataSize),
          reactionsSize.map(isValid) ?? true,
          trailingTextLine.map(isValid) ?? true,
          maximumWidth.isFinite,
          maximumWidth > 0,
          textSize.width <= maximumWidth,
          horizontalSpacing.isFinite,
          horizontalSpacing >= 0,
          verticalSpacing.isFinite,
          verticalSpacing >= 0
    else { return nil }

    let textFrame = CGRect(origin: .zero, size: textSize)

    guard let reactionsSize else {
      if let trailingTextLine,
         !trailingTextLine.isRTL,
         trailingTextLine.usedWidth + horizontalSpacing + metadataSize.width <= maximumWidth {
        let width = max(
          textSize.width,
          trailingTextLine.usedWidth + horizontalSpacing + metadataSize.width
        )
        return MessageFooterLayoutV2(
          size: CGSize(width: width, height: textSize.height),
          textFrame: textFrame,
          metadataFrame: CGRect(
            x: trailingTextLine.usedWidth + horizontalSpacing,
            y: max(0, textSize.height - metadataSize.height),
            width: metadataSize.width,
            height: metadataSize.height
          ),
          reactionsFrame: nil,
          placement: .trailingTextLineMetadata
        )
      }

      let inlineWidth = textSize.width + horizontalSpacing + metadataSize.width
      if isTextSingleLine, inlineWidth <= maximumWidth {
        let height = max(textSize.height, metadataSize.height)
        return MessageFooterLayoutV2(
          size: CGSize(width: inlineWidth, height: height),
          textFrame: CGRect(
            x: isRTL ? metadataSize.width + horizontalSpacing : 0,
            y: 0,
            width: textSize.width,
            height: textSize.height
          ),
          metadataFrame: CGRect(
            x: isRTL ? 0 : textSize.width + horizontalSpacing,
            y: height - metadataSize.height,
            width: metadataSize.width,
            height: metadataSize.height
          ),
          reactionsFrame: nil,
          placement: .inlineMetadata
        )
      }

      let width = max(textSize.width, metadataSize.width)
      let metadataY = textSize.height + verticalSpacing
      return MessageFooterLayoutV2(
        size: CGSize(width: width, height: metadataY + metadataSize.height),
        textFrame: textFrame,
        metadataFrame: CGRect(
          x: isRTL ? 0 : width - metadataSize.width,
          y: metadataY,
          width: metadataSize.width,
          height: metadataSize.height
        ),
        reactionsFrame: nil,
        placement: .metadataBelow
      )
    }

    let footerWidth = reactionsSize.width + horizontalSpacing + metadataSize.width
    let footerY = textSize.height + verticalSpacing
    if footerWidth <= maximumWidth {
      let width = max(textSize.width, footerWidth)
      let footerHeight = max(reactionsSize.height, metadataSize.height)
      return MessageFooterLayoutV2(
        size: CGSize(width: width, height: footerY + footerHeight),
        textFrame: textFrame,
        metadataFrame: CGRect(
          x: isRTL ? 0 : width - metadataSize.width,
          y: footerY + footerHeight - metadataSize.height,
          width: metadataSize.width,
          height: metadataSize.height
        ),
        reactionsFrame: CGRect(
          x: isRTL ? width - reactionsSize.width : 0,
          y: footerY + footerHeight - reactionsSize.height,
          width: reactionsSize.width,
          height: reactionsSize.height
        ),
        placement: .reactionsAndMetadataFooter
      )
    }

    let width = max(textSize.width, max(reactionsSize.width, metadataSize.width))
    let metadataY = footerY + reactionsSize.height + verticalSpacing
    return MessageFooterLayoutV2(
      size: CGSize(width: width, height: metadataY + metadataSize.height),
      textFrame: textFrame,
      metadataFrame: CGRect(
        x: isRTL ? 0 : width - metadataSize.width,
        y: metadataY,
        width: metadataSize.width,
        height: metadataSize.height
      ),
      reactionsFrame: CGRect(
        origin: CGPoint(x: isRTL ? width - reactionsSize.width : 0, y: footerY),
        size: reactionsSize
      ),
      placement: .stackedFooter
    )
  }

  private static func isValid(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width >= 0 && size.height >= 0
  }

  private static func isValid(_ line: MessageFooterLayoutV2.TrailingTextLine) -> Bool {
    line.usedWidth.isFinite && line.height.isFinite && line.usedWidth >= 0 && line.height > 0
  }
}
