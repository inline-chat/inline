import CoreText
import InlineKit
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public enum ThreadIconDefaults {
  public static let normalFallbackSymbol = "bubble.middle.bottom.fill"
  public static let replyFallbackSymbol = "arrow.turn.down.right"

  public static func fallbackSymbolName(isReplyThread: Bool) -> String {
    isReplyThread ? replyFallbackSymbol : normalFallbackSymbol
  }
}

public struct ThreadIconDescriptor: Equatable, Hashable, Sendable {
  public var emoji: String?
  public var title: String?
  public var isReplyThread: Bool
  public var accessibilityLabel: String?

  public init(
    emoji: String?,
    title: String? = nil,
    isReplyThread: Bool = false,
    accessibilityLabel: String? = nil
  ) {
    self.emoji = Self.normalizedEmoji(emoji)
    self.title = title
    self.isReplyThread = isReplyThread
    self.accessibilityLabel = accessibilityLabel
  }

  public init(chat: Chat) {
    self.init(
      emoji: chat.emoji,
      title: chat.humanReadableTitle ?? chat.title,
      isReplyThread: chat.isReplyThread,
      accessibilityLabel: chat.humanReadableTitle ?? chat.title
    )
  }

  public static func normalizedEmoji(_ emoji: String?) -> String? {
    guard let emoji else { return nil }

    let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstCharacter = trimmed.first else { return nil }
    return String(firstCharacter)
  }
}

public enum ThreadIconShape: Equatable, Hashable, Sendable {
  case circle
  case roundedSquare
  case none
}

public enum ThreadIconSymbolColor: Equatable, Hashable, Sendable {
  case primary
  /// A restrained primary foreground for in-app thread symbols. Notification
  /// avatars use their separate bitmap renderer and do not consume this role.
  case mutedPrimary
  case secondary
  case white
}

public enum ThreadIconBackground: Equatable, Hashable, Sendable {
  case automatic
  case solid
  case gradient
}

public enum ThreadIconSize: Equatable, Hashable, Sendable {
  case compact(CGFloat)
  case regular(CGFloat)
  case large(CGFloat)

  public var points: CGFloat {
    switch self {
    case let .compact(points), let .regular(points), let .large(points):
      return points
    }
  }

}

@MainActor
public struct ThreadIconView: View, Equatable {
  public let descriptor: ThreadIconDescriptor
  public let size: ThreadIconSize
  public let shape: ThreadIconShape
  public let symbolColor: ThreadIconSymbolColor
  public let background: ThreadIconBackground
  public let contentScaleMultiplier: CGFloat
  public let fallbackSymbolName: String?

  @Environment(\.colorScheme) private var colorScheme

  public nonisolated static func == (lhs: ThreadIconView, rhs: ThreadIconView) -> Bool {
    lhs.descriptor == rhs.descriptor &&
      lhs.size == rhs.size &&
      lhs.shape == rhs.shape &&
      lhs.symbolColor == rhs.symbolColor &&
      lhs.background == rhs.background &&
      lhs.contentScaleMultiplier == rhs.contentScaleMultiplier &&
      lhs.fallbackSymbolName == rhs.fallbackSymbolName
  }

  public init(
    _ descriptor: ThreadIconDescriptor,
    size: ThreadIconSize,
    shape: ThreadIconShape = .circle,
    symbolColor: ThreadIconSymbolColor = .secondary,
    background: ThreadIconBackground = .automatic,
    contentScaleMultiplier: CGFloat = 1,
    fallbackSymbolName: String? = nil
  ) {
    self.descriptor = descriptor
    self.size = size
    self.shape = shape
    self.symbolColor = symbolColor
    self.background = background
    self.contentScaleMultiplier = max(contentScaleMultiplier, 0)
    self.fallbackSymbolName = fallbackSymbolName
  }

  public var body: some View {
    backgroundView
      .frame(width: resolvedSize, height: resolvedSize)
      .overlay {
        content
      }
      .accessibilityLabel(accessibilityLabel)
      .fixedSize()
  }

  @ViewBuilder
  private var backgroundView: some View {
    switch shape {
    case .circle:
      switch resolvedBackground {
      case .solid:
        Circle()
          .fill(solidBackgroundColor)
      case .gradient:
        Circle()
          .fill(backgroundGradient)
      }
    case .roundedSquare:
      switch resolvedBackground {
      case .solid:
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(solidBackgroundColor)
      case .gradient:
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(backgroundGradient)
      }
    case .none:
      Color.clear
    }
  }

  @ViewBuilder
  private var content: some View {
    if let emoji = descriptor.emoji {
      let fontSize = resolvedSize * contentScale.emojiRatio * contentScaleMultiplier
      Text(emoji)
        .font(.system(size: fontSize, weight: .regular))
        .foregroundStyle(resolvedSymbolColor)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .offset(ThreadIconEmojiOpticalCenter.offset(for: emoji, fontSize: fontSize))
        .accessibilityHidden(true)
    } else {
      Image(systemName: fallbackSymbolName ?? ThreadIconDefaults.fallbackSymbolName(isReplyThread: descriptor.isReplyThread))
        .font(.system(
          size: resolvedSize * contentScale.symbolRatio * contentScaleMultiplier,
          weight: descriptor.isReplyThread ? .bold : .semibold
        ))
        .foregroundStyle(resolvedSymbolColor)
        .accessibilityHidden(true)
    }
  }

  private var resolvedSize: CGFloat {
    size.points
  }

  private var cornerRadius: CGFloat {
    resolvedSize * size.cornerRadiusRatio
  }

  private var solidBackgroundColor: Color {
    switch colorScheme {
    case .dark:
      Color.white.opacity(0.14)
    case .light:
      Color.black.opacity(0.065)
    @unknown default:
      Color.primary.opacity(0.085)
    }
  }

  private var backgroundGradient: LinearGradient {
    let colors: [Color] = switch colorScheme {
    case .dark:
      [
        Color.white.opacity(0.20),
        Color.white.opacity(0.13),
      ]
    case .light:
      [
        Color.black.opacity(0.05),
        Color.black.opacity(0.08),
      ]
    @unknown default:
      [
        Color.primary.opacity(0.07),
        Color.primary.opacity(0.11),
      ]
    }

    return LinearGradient(
      colors: colors,
      startPoint: .top,
      endPoint: .bottom
    )
  }

  private var resolvedBackground: ResolvedBackground {
    switch background {
    case .solid:
      return .solid
    case .gradient:
      return .gradient
    case .automatic:
      #if os(iOS)
      return .gradient
      #else
      return .solid
      #endif
    }
  }

  private var resolvedSymbolColor: Color {
    return symbolColor.color
  }

  private var contentScale: ContentScale {
    ContentScale.resolved(for: size, shape: shape)
  }

  private var accessibilityLabel: Text {
    Text(descriptor.accessibilityLabel ?? descriptor.title ?? "Thread")
  }
}

@MainActor
public enum ThreadIconImageRenderer {
  #if os(macOS)
  public static func nsImage(
    _ descriptor: ThreadIconDescriptor,
    size: ThreadIconSize,
    shape: ThreadIconShape = .circle,
    symbolColor: ThreadIconSymbolColor = .secondary,
    background: ThreadIconBackground = .automatic,
    colorScheme: ColorScheme
  ) -> NSImage? {
    let view = ThreadIconView(
      descriptor,
      size: size,
      shape: shape,
      symbolColor: symbolColor,
      background: background
    )
    .environment(\.colorScheme, colorScheme)
    .frame(width: size.points, height: size.points)

    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: size.points, height: size.points)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

    guard let image = renderer.nsImage else { return nil }
    image.size = NSSize(width: size.points, height: size.points)
    image.isTemplate = false
    return image
  }
  #endif

  #if os(iOS)
  public static func uiImage(
    _ descriptor: ThreadIconDescriptor,
    size: ThreadIconSize,
    shape: ThreadIconShape = .circle,
    symbolColor: ThreadIconSymbolColor = .secondary,
    background: ThreadIconBackground = .automatic,
    colorScheme: ColorScheme
  ) -> UIImage? {
    let view = ThreadIconView(
      descriptor,
      size: size,
      shape: shape,
      symbolColor: symbolColor,
      background: background
    )
    .environment(\.colorScheme, colorScheme)
    .frame(width: size.points, height: size.points)

    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: size.points, height: size.points)
    renderer.scale = UIScreen.main.scale
    return renderer.uiImage
  }
  #endif
}

/// Nudges lopsided emoji, such as 🎯, toward the middle of their icon box. Text
/// layout centers a glyph's box, so uneven artwork looks off-center without this.
@MainActor
enum ThreadIconEmojiOpticalCenter {
  /// Correct only part of the gap, so the emoji's outline doesn't look shifted instead.
  private static let correctionStrength: CGFloat = 0.6
  /// About 1pt at the 15.4pt font size used by compact sidebar icons.
  private static let maxOffsetRatio: CGFloat = 0.065
  private static let canvasSize = 32
  private static let measuringFontSize: CGFloat = 20
  /// Keeps faint antialiased edge pixels from stretching the bounding box.
  private static let boundingBoxMinAlpha = 64

  private static var ratios: [String: CGSize] = [:]

  /// Offset in points, snapped to half points so most emoji stay where they are.
  static func offset(for emoji: String, fontSize: CGFloat) -> CGSize {
    let ratio = ratio(for: emoji)
    return CGSize(
      width: (ratio.width * fontSize * 2).rounded() / 2,
      height: (ratio.height * fontSize * 2).rounded() / 2
    )
  }

  /// Measured once per emoji, so rendering a row afterward is only a dictionary lookup.
  private static func ratio(for emoji: String) -> CGSize {
    if let ratio = ratios[emoji] { return ratio }
    let ratio = measureRatio(for: emoji)
    ratios[emoji] = ratio
    return ratio
  }

  /// Compares the opacity-weighted center of the emoji's pixels with the center of
  /// their bounding box. Using the box as the reference keeps this independent of
  /// font line metrics. Bitmap rows run top-down, matching SwiftUI's offset direction.
  private static func measureRatio(for emoji: String) -> CGSize {
    guard let context = CGContext(
      data: nil,
      width: canvasSize,
      height: canvasSize,
      bitsPerComponent: 8,
      bytesPerRow: canvasSize * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return .zero }

    let font = CTFontCreateUIFontForLanguage(.system, measuringFontSize, nil)
    let attributes = [kCTFontAttributeName as NSAttributedString.Key: font as Any]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: attributes))
    context.textPosition = CGPoint(x: 3, y: 8)
    CTLineDraw(line, context)

    guard let data = context.data else { return .zero }
    let pixels = data.bindMemory(to: UInt8.self, capacity: canvasSize * canvasSize * 4)

    var totalAlpha = 0.0
    var weightedX = 0.0
    var weightedY = 0.0
    var (minX, maxX) = (canvasSize, -1)
    var (minY, maxY) = (canvasSize, -1)

    for y in 0 ..< canvasSize {
      for x in 0 ..< canvasSize {
        let alpha = Int(pixels[(y * canvasSize + x) * 4 + 3])
        guard alpha > 0 else { continue }
        totalAlpha += Double(alpha)
        weightedX += Double(x * alpha)
        weightedY += Double(y * alpha)
        guard alpha >= boundingBoxMinAlpha else { continue }
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return .zero }

    return CGSize(
      width: correctedRatio(center: CGFloat(minX + maxX) / 2, weighted: CGFloat(weightedX / totalAlpha)),
      height: correctedRatio(center: CGFloat(minY + maxY) / 2, weighted: CGFloat(weightedY / totalAlpha))
    )
  }

  private static func correctedRatio(center: CGFloat, weighted: CGFloat) -> CGFloat {
    let ratio = (center - weighted) / measuringFontSize * correctionStrength
    return min(max(ratio, -maxOffsetRatio), maxOffsetRatio)
  }
}

private enum ResolvedBackground: Equatable {
  case solid
  case gradient
}

private struct ContentScale: Equatable {
  let emojiRatio: CGFloat
  let symbolRatio: CGFloat

  static func resolved(for size: ThreadIconSize, shape: ThreadIconShape) -> ContentScale {
    if shape == .none, size.points <= 24 {
      return ContentScale(emojiRatio: 0.70, symbolRatio: 0.55)
    }

    switch size {
    case .compact:
      return ContentScale(emojiRatio: 0.66, symbolRatio: 0.52)
    case .regular:
      return ContentScale(emojiRatio: 0.56, symbolRatio: 0.44)
    case let .large(points):
      if points >= 72 {
        return ContentScale(emojiRatio: 0.46, symbolRatio: 0.38)
      }
      return ContentScale(emojiRatio: 0.55, symbolRatio: 0.46)
    }
  }
}

private extension ThreadIconSize {
  var cornerRadiusRatio: CGFloat {
    switch self {
    case .compact:
      return 0.40
    case .regular:
      return 0.36
    case .large:
      return 0.32
    }
  }
}

private extension ThreadIconSymbolColor {
  var color: Color {
    switch self {
    case .primary:
      .primary
    case .mutedPrimary:
      Color.primary.opacity(0.76)
    case .secondary:
      .secondary
    case .white:
      Color.white.opacity(0.94)
    }
  }
}

#if DEBUG
#Preview("Thread Icons") {
  HStack(spacing: 12) {
    ThreadIconView(ThreadIconDescriptor(emoji: "💬"), size: .compact(20), shape: .none)
    ThreadIconView(ThreadIconDescriptor(emoji: nil), size: .compact(20), shape: .none)
    ThreadIconView(ThreadIconDescriptor(emoji: "🧠"), size: .regular(32))
    ThreadIconView(
      ThreadIconDescriptor(emoji: nil, isReplyThread: true),
      size: .regular(32)
    )
    ThreadIconView(ThreadIconDescriptor(emoji: "🚀"), size: .large(56))
  }
  .padding()
}
#endif
