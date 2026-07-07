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

  public nonisolated static func == (lhs: ThreadIconView, rhs: ThreadIconView) -> Bool {
    lhs.descriptor == rhs.descriptor &&
      lhs.size == rhs.size &&
      lhs.shape == rhs.shape &&
      lhs.symbolColor == rhs.symbolColor &&
      lhs.background == rhs.background
  }

  public init(
    _ descriptor: ThreadIconDescriptor,
    size: ThreadIconSize,
    shape: ThreadIconShape = .circle,
    symbolColor: ThreadIconSymbolColor = .secondary,
    background: ThreadIconBackground = .automatic
  ) {
    self.descriptor = descriptor
    self.size = size
    self.shape = shape
    self.symbolColor = symbolColor
    self.background = background
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
      Text(emoji)
        .font(.system(size: resolvedSize * contentScale.emojiRatio, weight: .regular))
        .foregroundStyle(resolvedSymbolColor)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityHidden(true)
    } else {
      Image(systemName: ThreadIconDefaults.fallbackSymbolName(isReplyThread: descriptor.isReplyThread))
        .font(.system(size: resolvedSize * contentScale.symbolRatio, weight: .semibold))
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
    Color.primary.opacity(0.045)
  }

  private var backgroundGradient: LinearGradient {
    LinearGradient(
      colors: [
        Color.primary.opacity(0.035),
        Color.primary.opacity(0.055),
      ],
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
        return ContentScale(emojiRatio: 0.38, symbolRatio: 0.32)
      }
      return ContentScale(emojiRatio: 0.46, symbolRatio: 0.38)
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
