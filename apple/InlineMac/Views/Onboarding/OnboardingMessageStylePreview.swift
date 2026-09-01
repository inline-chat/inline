import AppKit
import InlineUI
import MacTheme
import SwiftUI

struct OnboardingPreviewIdentity {
  let displayName: String
  let avatarImage: NSImage?

  init(displayName: String, avatarImage: NSImage?) {
    self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.avatarImage = avatarImage
  }
}

struct OnboardingMessageStylePreview: View {
  static let size = CGSize(width: 460, height: 200)

  @Environment(\.colorScheme) private var colorScheme

  let style: MessageRenderStyle
  let identity: OnboardingPreviewIdentity

  var body: some View {
    let palette = PreviewMessagePalette(isDark: colorScheme == .dark)

    PreviewConversation(style: style, currentUser: identity, palette: palette)
      .frame(width: Self.size.width, height: Self.size.height)
      .background(palette.chatBackground.opacity(0.5))
      .clipped()
  }
}

private struct PreviewConversation: View {
  private static let mo = OnboardingPreviewIdentity(displayName: "Mo", avatarImage: nil)

  let style: MessageRenderStyle
  let currentUser: OnboardingPreviewIdentity
  let palette: PreviewMessagePalette

  private var messages: [PreviewMessage] {
    [
      PreviewMessage(
        id: 1,
        identity: Self.mo,
        text: "Want to review the launch notes together?",
        time: "10:42",
        isOutgoing: false,
        reply: nil
      ),
      PreviewMessage(
        id: 2,
        identity: currentUser,
        text: "Yes — give me a minute to finish this.",
        time: "10:43",
        isOutgoing: true,
        reply: nil
      ),
      PreviewMessage(
        id: 3,
        identity: Self.mo,
        text: "Perfect, I'll send them over.",
        time: "10:44",
        isOutgoing: false,
        reply: PreviewReplyContent(
          identity: currentUser,
          text: "Yes — give me a minute to finish this."
        )
      ),
    ]
  }

  @ViewBuilder
  var body: some View {
    switch style {
    case .minimal:
      PreviewMinimalConversation(messages: messages, palette: palette)
    case .bubble:
      PreviewBubbleConversation(messages: messages, palette: palette)
    }
  }
}

private struct PreviewMessage: Identifiable {
  let id: Int
  let identity: OnboardingPreviewIdentity
  let text: LocalizedStringResource
  let time: String
  let isOutgoing: Bool
  let reply: PreviewReplyContent?
}

private struct PreviewReplyContent {
  let identity: OnboardingPreviewIdentity
  let text: LocalizedStringResource
}

// Frozen snapshot of the macOS message presentation metrics used by onboarding.
// Keep these values local so the preview cannot depend on renderer internals.
private enum PreviewMessageMetrics {
  static let minimalAvatarSize: CGFloat = 30
  static let avatarContentSpacing: CGFloat = 8
  static let bubbleSideInset: CGFloat = 16
  static let minimalSideInset: CGFloat = 16
  static let messageGroupSpacing: CGFloat = 8

  static let bubbleCornerRadius: CGFloat = 14
  static let bubbleContentInset: CGFloat = 11
  static let messageTextVerticalInset: CGFloat = 6

  static let minimalNameHeight: CGFloat = 14
  static let minimalNameBottomSpacing: CGFloat = 2
  static let minimalTextMinHeight: CGFloat = 22

  static let replyHeight: CGFloat = 40
  static let bubbleReplyWidth: CGFloat = 200
  static let minimalReplyWidth: CGFloat = 260
  static let replyTopSpacing: CGFloat = 6
  static let replyBottomSpacing: CGFloat = 3
  static let minimalReplyVerticalSpacing: CGFloat = 4
  static let replyBarWidth: CGFloat = 3
  static let replyContentSpacing: CGFloat = 6
  static let replyTextTrailingInset: CGFloat = 6
  static let replyCornerRadius: CGFloat = 8

  private static let tailSourceSize = CGSize(width: 37, height: 52.4)
  private static let tailSourceBubbleEdgeX: CGFloat = 19.5183
  private static let tailSourceBottomY: CGFloat = 51.2853
  private static let tailScale: CGFloat = 14 / tailSourceBottomY

  static let tailSize = CGSize(
    width: tailSourceSize.width * tailScale,
    height: tailSourceSize.height * tailScale
  )
  static let tailExposedWidth = (tailSourceSize.width - tailSourceBubbleEdgeX) * tailScale
  static let tailBottomOffset = tailSize.height - tailSourceBottomY * tailScale
}

private struct PreviewMinimalConversation: View {
  let messages: [PreviewMessage]
  let palette: PreviewMessagePalette

  var body: some View {
    VStack(spacing: PreviewMessageMetrics.messageGroupSpacing) {
      ForEach(messages) { message in
        PreviewMinimalMessageRow(message: message, palette: palette)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct PreviewMinimalMessageRow: View {
  let message: PreviewMessage
  let palette: PreviewMessagePalette

  var body: some View {
    HStack(alignment: .top, spacing: PreviewMessageMetrics.avatarContentSpacing) {
      PreviewAvatar(identity: message.identity, size: PreviewMessageMetrics.minimalAvatarSize)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 0) {
        PreviewSenderName(identity: message.identity, palette: palette)
          .frame(height: PreviewMessageMetrics.minimalNameHeight, alignment: .topLeading)
          .padding(.bottom, PreviewMessageMetrics.minimalNameBottomSpacing)

        if let reply = message.reply {
          PreviewReply(
            content: reply,
            width: PreviewMessageMetrics.minimalReplyWidth,
            usesWhiteStyle: false,
            palette: palette
          )
          .padding(.vertical, PreviewMessageMetrics.minimalReplyVerticalSpacing)
        }

        PreviewMessageText(text: message.text, color: palette.minimalText)
          .frame(minHeight: PreviewMessageMetrics.minimalTextMinHeight, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, PreviewMessageMetrics.minimalSideInset)
    .padding(.trailing, PreviewMessageMetrics.minimalSideInset)
  }
}

private struct PreviewBubbleConversation: View {
  let messages: [PreviewMessage]
  let palette: PreviewMessagePalette

  var body: some View {
    VStack(spacing: PreviewMessageMetrics.messageGroupSpacing) {
      ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
        PreviewBubbleMessageRow(
          message: message,
          viewportFraction: CGFloat(index + 1) / CGFloat(messages.count + 1),
          palette: palette
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct PreviewBubbleMessageRow: View {
  let message: PreviewMessage
  let viewportFraction: CGFloat
  let palette: PreviewMessagePalette

  var body: some View {
    PreviewBubble(
      message: message,
      viewportFraction: viewportFraction,
      palette: palette
    )
    .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    .padding(.leading, PreviewMessageMetrics.bubbleSideInset)
    .padding(.trailing, PreviewMessageMetrics.bubbleSideInset)
  }
}

private struct PreviewBubble: View {
  let message: PreviewMessage
  let viewportFraction: CGFloat
  let palette: PreviewMessagePalette

  private var textColor: Color {
    message.isOutgoing ? palette.outgoingText : palette.incomingText
  }

  var body: some View {
    bubbleContent
      .fixedSize(horizontal: true, vertical: true)
      .background {
        PreviewBubbleBackground(
          isOutgoing: message.isOutgoing,
          viewportFraction: viewportFraction,
          palette: palette
        )
      }
      .overlay(alignment: message.isOutgoing ? .bottomTrailing : .bottomLeading) {
        PreviewBubbleTail(
          side: message.isOutgoing ? .trailing : .leading,
          color: palette.bubbleColor(isOutgoing: message.isOutgoing),
          lightingAlpha: palette.bubbleLightingAlpha(
            isOutgoing: message.isOutgoing,
            viewportFraction: viewportFraction
          )
        )
        .frame(
          width: PreviewMessageMetrics.tailSize.width,
          height: PreviewMessageMetrics.tailSize.height
        )
        .offset(
          x: message.isOutgoing
            ? PreviewMessageMetrics.tailExposedWidth
            : -PreviewMessageMetrics.tailExposedWidth,
          y: PreviewMessageMetrics.tailBottomOffset
        )
      }
  }

  private var bubbleContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let reply = message.reply {
        PreviewReply(
          content: reply,
          width: PreviewMessageMetrics.bubbleReplyWidth,
          usesWhiteStyle: message.isOutgoing,
          palette: palette
        )
        .padding(.top, PreviewMessageMetrics.replyTopSpacing)
        .padding(.horizontal, PreviewMessageMetrics.bubbleContentInset)
        .padding(.bottom, PreviewMessageMetrics.replyBottomSpacing)
      }

      HStack(alignment: .firstTextBaseline, spacing: 4) {
        PreviewMessageText(text: message.text, color: textColor)
        PreviewTimeAndState(
          time: message.time,
          isOutgoing: message.isOutgoing,
          usesOutgoingBubbleStyle: message.isOutgoing,
          palette: palette
        )
      }
      .padding(.top, message.reply == nil ? PreviewMessageMetrics.messageTextVerticalInset : 0)
      .padding(.horizontal, PreviewMessageMetrics.bubbleContentInset)
      .padding(.bottom, PreviewMessageMetrics.messageTextVerticalInset)
    }
  }
}

private struct PreviewBubbleBackground: View {
  let isOutgoing: Bool
  let viewportFraction: CGFloat
  let palette: PreviewMessagePalette

  var body: some View {
    let shape = RoundedRectangle(
      cornerRadius: PreviewMessageMetrics.bubbleCornerRadius,
      style: .continuous
    )

    ZStack {
      shape.fill(palette.bubbleColor(isOutgoing: isOutgoing))
      shape.fill(
        Color.white.opacity(palette.bubbleLightingAlpha(
          isOutgoing: isOutgoing,
          viewportFraction: viewportFraction
        ))
      )
    }
  }
}

private struct PreviewBubbleTail: View {
  enum Side {
    case leading
    case trailing
  }

  let side: Side
  let color: Color
  let lightingAlpha: Double

  var body: some View {
    ZStack {
      PreviewBubbleTailShape(side: side).fill(color)
      PreviewBubbleTailShape(side: side).fill(Color.white.opacity(lightingAlpha))
    }
  }
}

// Frozen copy of the production tail geometry. Refresh it deliberately when the
// onboarding snapshot is updated; do not reconnect this view to the renderer.
private struct PreviewBubbleTailShape: Shape {
  let side: PreviewBubbleTail.Side

  func path(in rect: CGRect) -> Path {
    let sourceSize = CGSize(width: 37, height: 52.4)
    let scaleX = rect.width / sourceSize.width
    let scaleY = rect.height / sourceSize.height

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      let resolvedX = side == .leading ? rect.maxX - x * scaleX : rect.minX + x * scaleX
      return CGPoint(x: resolvedX, y: rect.minY + y * scaleY)
    }

    var path = Path()
    path.move(to: point(19.4761, 6.9846))
    path.addCurve(
      to: point(19.5183, 0),
      control1: point(19.5041, 6.3302),
      control2: point(19.5183, 0.6611)
    )
    path.addLine(to: point(0, 0))
    path.addLine(to: point(0, 39.8152))
    path.addCurve(
      to: point(36.1476, 50.9938),
      control1: point(8.3867, 48.2023),
      control2: point(22.1067, 52.3205)
    )
    path.addCurve(
      to: point(36.5785, 50.7275),
      control1: point(36.3267, 50.9769),
      control2: point(36.4868, 50.878)
    )
    path.addCurve(
      to: point(36.3805, 49.9764),
      control1: point(36.7373, 50.4669),
      control2: point(36.6487, 50.1307)
    )
    path.addLine(to: point(35.3668, 49.3821))
    path.addCurve(
      to: point(22.3321, 37.0489),
      control1: point(28.7234, 45.413),
      control2: point(24.3785, 41.3021)
    )
    path.addCurve(
      to: point(19.4761, 6.9846),
      control1: point(20.1278, 32.4675),
      control2: point(19.1757, 22.4468)
    )
    path.closeSubpath()
    return path
  }
}

private struct PreviewSenderName: View {
  let identity: OnboardingPreviewIdentity
  let palette: PreviewMessagePalette

  var body: some View {
    Text(identity.displayName)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(palette.senderColor(for: identity))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }
}

private struct PreviewMessageText: View {
  let text: LocalizedStringResource
  let color: Color

  var body: some View {
    Text(text)
      .font(Font(ChatTypography.current.font))
      .foregroundStyle(color)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }
}

private struct PreviewReply: View {
  let content: PreviewReplyContent
  let width: CGFloat
  let usesWhiteStyle: Bool
  let palette: PreviewMessagePalette

  private var accentColor: Color {
    usesWhiteStyle ? .white : palette.senderColor(for: content.identity)
  }

  private var textColor: Color {
    usesWhiteStyle ? .white : palette.minimalText
  }

  var body: some View {
    let shape = RoundedRectangle(
      cornerRadius: PreviewMessageMetrics.replyCornerRadius,
      style: .continuous
    )

    HStack(spacing: PreviewMessageMetrics.replyContentSpacing) {
      Rectangle()
        .fill(accentColor)
        .frame(width: PreviewMessageMetrics.replyBarWidth)

      VStack(alignment: .leading, spacing: 0) {
        Text(content.identity.displayName)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(accentColor)
          .lineLimit(1)

        Text(content.text)
          .font(Font(ChatTypography.current.font))
          .foregroundStyle(textColor)
          .lineLimit(1)
      }
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.trailing, PreviewMessageMetrics.replyTextTrailingInset)
    .frame(width: width, height: PreviewMessageMetrics.replyHeight, alignment: .leading)
    .background(
      accentColor.opacity(usesWhiteStyle ? 0.09 : 0.08),
      in: shape
    )
    .clipShape(shape)
  }
}

private struct PreviewTimeAndState: View {
  let time: String
  let isOutgoing: Bool
  let usesOutgoingBubbleStyle: Bool
  let palette: PreviewMessagePalette

  var body: some View {
    HStack(spacing: 2) {
      Text(time)
        .font(.system(size: 10, weight: .regular))

      if isOutgoing {
        Image(systemName: "checkmark")
          .font(.system(size: 8, weight: .bold))
          .frame(width: 10, height: 10)
      }
    }
    .foregroundStyle(palette.timeColor(usesOutgoingBubbleStyle: usesOutgoingBubbleStyle))
    .frame(height: 13)
    .fixedSize(horizontal: true, vertical: false)
  }
}

private struct PreviewAvatar: View {
  let identity: OnboardingPreviewIdentity
  let size: CGFloat

  @ViewBuilder
  var body: some View {
    if let avatarImage = identity.avatarImage {
      Image(nsImage: avatarImage)
        .resizable()
        .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(Circle())
    } else {
      InitialsCircle(name: identity.displayName, size: size)
    }
  }
}

@MainActor
private struct PreviewMessagePalette {
  let chatBackground: Color
  let outgoingBubble: Color
  let incomingBubble: Color
  let outgoingText: Color
  let incomingText: Color
  let minimalText: Color

  private let outgoingLighting: (top: CGFloat, bottom: CGFloat)
  private let incomingLighting: (top: CGFloat, bottom: CGFloat)

  init(isDark: Bool) {
    let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance

    chatBackground = Color(nsColor: Theme.windowContentBackgroundColor)
    outgoingBubble = Color(nsColor: Theme.messageBubblePrimaryBgColor)
    incomingBubble = Color(nsColor: Theme.messageBubbleSecondaryBgColor)
    outgoingText = .white
    incomingText = Color(nsColor: Theme.messageBubbleSecondaryTextColor)
    minimalText = Color(nsColor: .labelColor)
    outgoingLighting = Theme.messageBubbleGradientOverlayAlphas(appearance: appearance, outgoing: true)
    incomingLighting = Theme.messageBubbleGradientOverlayAlphas(appearance: appearance, outgoing: false)
  }

  func senderColor(for identity: OnboardingPreviewIdentity) -> Color {
    InitialsCircle.ColorPalette.color(for: identity.displayName)
  }

  func bubbleColor(isOutgoing: Bool) -> Color {
    isOutgoing ? outgoingBubble : incomingBubble
  }

  func bubbleLightingAlpha(isOutgoing: Bool, viewportFraction: CGFloat) -> Double {
    let lighting = isOutgoing ? outgoingLighting : incomingLighting
    let progress = min(max(viewportFraction, 0), 1)
    return Double(lighting.top + (lighting.bottom - lighting.top) * progress)
  }

  func timeColor(usesOutgoingBubbleStyle: Bool) -> Color {
    usesOutgoingBubbleStyle ? outgoingText.opacity(0.7) : Color(nsColor: .tertiaryLabelColor)
  }
}
