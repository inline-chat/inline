import CoreGraphics
import Foundation
import InlineAvatarCore

#if canImport(UIKit)
import UIKit
#endif

public typealias InlineUserAvatarRenderIdentity = InlineAvatarUserIdentity

public struct InlineThreadAvatarRenderIdentity: Sendable, Equatable {
  public var emoji: String?
  public var title: String?
  public var isReplyThread: Bool
  public var stableIdentifier: String

  public init(
    emoji: String?,
    title: String?,
    isReplyThread: Bool,
    stableIdentifier: String
  ) {
    self.emoji = Self.normalizedEmoji(emoji)
    self.title = title
    self.isReplyThread = isReplyThread
    self.stableIdentifier = stableIdentifier
  }

  private static func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }
    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstCharacter = trimmed.first else { return nil }
    return String(firstCharacter)
  }
}

public enum InlineAvatarBitmapRenderer {
  public static func userInitialsImageData(
    identity: InlineUserAvatarRenderIdentity,
    size: CGSize,
    scale: CGFloat
  ) -> Data? {
    #if canImport(UIKit)
    makeUserInitialsImageData(
      identity: identity,
      size: normalizedSize(size),
      scale: normalizedScale(scale)
    )
    #else
    nil
    #endif
  }

  public static func threadImageData(
    emoji: String?,
    title: String,
    isReplyThread: Bool,
    size: CGSize,
    scale: CGFloat
  ) -> Data? {
    threadImageData(
      identity: InlineThreadAvatarRenderIdentity(
        emoji: emoji,
        title: title,
        isReplyThread: isReplyThread,
        stableIdentifier: normalizedIdentifier(title, fallback: isReplyThread ? "reply-thread" : "thread")
      ),
      size: size,
      scale: scale
    )
  }

  public static func threadImageData(
    identity: InlineThreadAvatarRenderIdentity,
    size: CGSize,
    scale: CGFloat
  ) -> Data? {
    #if canImport(UIKit)
    makeThreadImageData(
      identity: identity,
      size: normalizedSize(size),
      scale: normalizedScale(scale)
    )
    #else
    nil
    #endif
  }

  private static func normalizedSize(_ size: CGSize) -> CGSize {
    CGSize(width: max(size.width, 1), height: max(size.height, 1))
  }

  private static func normalizedScale(_ scale: CGFloat) -> CGFloat {
    max(scale, 1)
  }

  private static func normalizedIdentifier(_ value: String?, fallback: String) -> String {
    guard let value else { return fallback }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }
}

#if canImport(UIKit)
private extension InlineAvatarBitmapRenderer {
  static let normalThreadFallbackSymbol = "bubble.middle.bottom.fill"
  static let replyThreadFallbackSymbol = "arrow.turn.down.right"

  static func makeUserInitialsImageData(
    identity: InlineUserAvatarRenderIdentity,
    size: CGSize,
    scale: CGFloat
  ) -> Data? {
    let presentation = InlineAvatarPresentation.user(identity: identity)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false

    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      let bounds = CGRect(origin: .zero, size: size)
      drawUserBackground(in: context.cgContext, bounds: bounds, style: presentation.style)

      if let initials = presentation.initials {
        drawCenteredText(
          initials,
          font: .systemFont(
            ofSize: min(size.width, size.height) * 0.55,
            weight: .regular
          ),
          color: platformColor(presentation.style.foregroundColor),
          in: bounds
        )
      } else {
        drawCenteredSymbol(
          "person.fill",
          pointSize: min(size.width, size.height) * 0.46,
          weight: .regular,
          color: platformColor(presentation.style.foregroundColor),
          in: bounds
        )
      }
    }

    return image.pngData()
  }

  static func makeThreadImageData(
    identity: InlineThreadAvatarRenderIdentity,
    size: CGSize,
    scale: CGFloat
  ) -> Data? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false

    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      let bounds = CGRect(origin: .zero, size: size)
      let ctx = context.cgContext

      drawThreadBackground(in: ctx, bounds: bounds, seed: threadColorSeed(identity: identity))
      let iconSize = min(size.width, size.height)
      let ratios = threadContentRatios(for: iconSize)

      if let emoji = identity.emoji {
        drawCenteredText(
          emoji,
          font: .systemFont(ofSize: iconSize * ratios.emoji, weight: .regular),
          color: threadSymbolColor(),
          in: bounds
        )
      } else {
        drawCenteredSymbol(
          identity.isReplyThread ? replyThreadFallbackSymbol : normalThreadFallbackSymbol,
          pointSize: iconSize * ratios.symbol,
          color: threadSymbolColor(),
          in: bounds
        )
      }
    }

    return image.pngData()
  }

  static func normalizedString(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func drawUserBackground(in ctx: CGContext, bounds: CGRect, style: InlineAvatarStyle) {
    let topColor = style.gradientStops.first?.color ?? style.baseColor
    let bottomColor = style.gradientStops.last?.color ?? style.baseColor
    drawCircularGradient(
      in: ctx,
      bounds: bounds,
      topColor: platformColor(topColor),
      bottomColor: platformColor(bottomColor),
      fallbackColor: platformColor(bottomColor)
    )

    ctx.saveGState()
    ctx.addEllipse(in: bounds.insetBy(dx: 0.25, dy: 0.25))
    ctx.setStrokeColor(platformColor(style.borderColor).cgColor)
    ctx.setLineWidth(CGFloat(style.borderWidth))
    ctx.strokePath()
    ctx.restoreGState()
  }

  static func drawThreadBackground(in ctx: CGContext, bounds: CGRect, seed: String) {
    let baseColor = threadColor(for: seed)
    drawCircularGradient(
      in: ctx,
      bounds: bounds,
      topColor: adjustedBrightness(baseColor, by: 0.12),
      bottomColor: adjustedBrightness(baseColor, by: -0.10),
      fallbackColor: baseColor
    )
  }

  static func drawCircularGradient(
    in ctx: CGContext,
    bounds: CGRect,
    topColor: UIColor,
    bottomColor: UIColor,
    fallbackColor: UIColor
  ) {
    ctx.saveGState()
    ctx.addEllipse(in: bounds)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [topColor.cgColor, bottomColor.cgColor] as CFArray
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else {
      ctx.setFillColor(fallbackColor.cgColor)
      ctx.fill(bounds)
      ctx.restoreGState()
      return
    }

    ctx.drawLinearGradient(
      gradient,
      start: CGPoint(x: bounds.midX, y: bounds.minY),
      end: CGPoint(x: bounds.midX, y: bounds.maxY),
      options: []
    )
    ctx.restoreGState()
  }

  static func threadColor(for seed: String) -> UIColor {
    color(for: seed, palette: threadPalette)
  }

  static func color(for seed: String, palette: [(red: CGFloat, green: CGFloat, blue: CGFloat)]) -> UIColor {
    let index = paletteIndex(for: seed, paletteCount: palette.count)
    let color = palette[index]
    return UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
  }

  static var threadPalette: [(red: CGFloat, green: CGFloat, blue: CGFloat)] {
    [
      (0.42, 0.47, 0.62),
      (0.36, 0.52, 0.48),
      (0.52, 0.43, 0.60),
      (0.50, 0.48, 0.34),
      (0.36, 0.48, 0.60),
      (0.48, 0.42, 0.52),
      (0.42, 0.52, 0.42),
      (0.48, 0.44, 0.36),
    ]
  }

  static func threadColorSeed(identity: InlineThreadAvatarRenderIdentity) -> String {
    if let stableIdentifier = normalizedString(identity.stableIdentifier) {
      return stableIdentifier
    }
    if let title = normalizedString(identity.title) {
      return title
    }
    if let emoji = identity.emoji {
      return emoji
    }
    return identity.stableIdentifier
  }

  static func paletteIndex(for name: String, paletteCount: Int) -> Int {
    guard paletteCount > 0 else { return 0 }
    let hash = name.utf8.reduce(0) { $0 + Int($1) }
    return abs(hash) % paletteCount
  }

  static func adjustedBrightness(_ color: UIColor, by amount: CGFloat) -> UIColor {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
      return color
    }
    return UIColor(
      hue: hue,
      saturation: saturation,
      brightness: min(max(brightness + amount, 0), 1),
      alpha: alpha
    )
  }

  static func threadSymbolColor() -> UIColor {
    UIColor.white.withAlphaComponent(0.94)
  }

  static func threadContentRatios(for size: CGFloat) -> (emoji: CGFloat, symbol: CGFloat) {
    switch size {
    case ..<25:
      return (0.66, 0.52)
    case ..<37:
      return (0.56, 0.44)
    case ..<72:
      return (0.55, 0.46)
    default:
      return (0.38, 0.32)
    }
  }

  static func drawCenteredText(
    _ text: String,
    font: UIFont,
    color: UIColor,
    in bounds: CGRect
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ]
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let measured = attributedString.boundingRect(
      with: bounds.size,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    let drawRect = CGRect(
      x: bounds.midX - measured.width / 2,
      y: bounds.midY - measured.height / 2,
      width: measured.width,
      height: measured.height
    )
    attributedString.draw(in: drawRect)
  }

  static func drawCenteredSymbol(
    _ symbolName: String,
    pointSize: CGFloat,
    weight: UIImage.SymbolWeight = .bold,
    color: UIColor,
    in bounds: CGRect
  ) {
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let image = UIImage(systemName: symbolName, withConfiguration: configuration)?
      .withTintColor(color, renderingMode: .alwaysOriginal)
    else {
      return
    }

    let drawRect = aspectFitRect(
      for: image.size,
      in: bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2)
    )
    image.draw(in: drawRect)
  }

  static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else {
      return bounds
    }

    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
      x: bounds.midX - scaledSize.width / 2,
      y: bounds.midY - scaledSize.height / 2,
      width: scaledSize.width,
      height: scaledSize.height
    )
  }

  static func platformColor(_ color: InlineAvatarColor) -> UIColor {
    UIColor(
      red: CGFloat(color.red),
      green: CGFloat(color.green),
      blue: CGFloat(color.blue),
      alpha: CGFloat(color.alpha)
    )
  }
}
#endif
