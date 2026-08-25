import AppKit
import SwiftUI

struct OnboardingPreviewIdentity {
  let displayName: String
  let initials: String
  let avatarImage: NSImage?

  init(displayName: String, avatarImage: NSImage?) {
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.displayName = trimmedName
    initials = trimmedName
      .split(whereSeparator: \Character.isWhitespace)
      .prefix(2)
      .compactMap(\.first)
      .map(String.init)
      .joined()
      .uppercased()
    self.avatarImage = avatarImage
  }
}

struct OnboardingMessageStylePreview: View {
  static let size = CGSize(width: 500, height: 230)

  @Environment(\.colorScheme) private var colorScheme

  let style: MessageRenderStyle
  let identity: OnboardingPreviewIdentity

  var body: some View {
    OnboardingPreviewConversation(
      style: style,
      currentUser: identity,
      palette: OnboardingPreviewPalette(isDark: colorScheme == .dark)
    )
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(width: Self.size.width, height: Self.size.height)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
    .clipped()
  }
}

private struct OnboardingPreviewConversation: View {
  private static let mo = OnboardingPreviewIdentity(displayName: "Mo", avatarImage: nil)

  let style: MessageRenderStyle
  let currentUser: OnboardingPreviewIdentity
  let palette: OnboardingPreviewPalette

  var body: some View {
    VStack(spacing: style == .bubble ? 8 : 10) {
      OnboardingPreviewMessageRow(
        style: style,
        identity: Self.mo,
        text: "Want to review the launch notes together?",
        isOutgoing: false,
        reply: nil,
        palette: palette
      )
      OnboardingPreviewMessageRow(
        style: style,
        identity: currentUser,
        text: "Yes — give me a minute to finish this.",
        isOutgoing: true,
        reply: OnboardingPreviewReplyContent(
          author: Self.mo.displayName,
          text: "Want to review the launch notes together?"
        ),
        palette: palette
      )
      OnboardingPreviewMessageRow(
        style: style,
        identity: Self.mo,
        text: "Perfect, I'll send them over.",
        isOutgoing: false,
        reply: nil,
        palette: palette
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct OnboardingPreviewMessageRow: View {
  let style: MessageRenderStyle
  let identity: OnboardingPreviewIdentity
  let text: LocalizedStringResource
  let isOutgoing: Bool
  let reply: OnboardingPreviewReplyContent?
  let palette: OnboardingPreviewPalette

  var body: some View {
    switch style {
    case .minimal:
      HStack(alignment: .top, spacing: 8) {
        OnboardingPreviewAvatar(identity: identity, palette: palette)

        VStack(alignment: .leading, spacing: 3) {
          Text(identity.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.name)
            .lineLimit(1)

          if let reply {
            OnboardingPreviewReply(
              content: reply,
              isInsideBubble: false,
              isOutgoing: isOutgoing,
              palette: palette
            )
          }

          Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

    case .bubble:
      HStack(alignment: .bottom, spacing: 7) {
        if !isOutgoing {
          OnboardingPreviewAvatar(identity: identity, palette: palette)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(identity.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOutgoing ? palette.outgoingText.opacity(0.82) : palette.name)
            .lineLimit(1)

          if let reply {
            OnboardingPreviewReply(
              content: reply,
              isInsideBubble: true,
              isOutgoing: isOutgoing,
              palette: palette
            )
          }

          Text(text)
            .font(.body)
            .foregroundStyle(isOutgoing ? palette.outgoingText : palette.incomingText)
            .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
          isOutgoing ? palette.outgoingBubble : palette.incomingBubble,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )

        if isOutgoing {
          OnboardingPreviewAvatar(identity: identity, palette: palette)
        }
      }
      .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
  }
}

private struct OnboardingPreviewReplyContent {
  let author: String
  let text: LocalizedStringResource
}

private struct OnboardingPreviewReply: View {
  let content: OnboardingPreviewReplyContent
  let isInsideBubble: Bool
  let isOutgoing: Bool
  let palette: OnboardingPreviewPalette

  var body: some View {
    HStack(spacing: 6) {
      Capsule()
        .fill(isOutgoing ? palette.outgoingText.opacity(0.8) : palette.name)
        .frame(width: 2)

      VStack(alignment: .leading, spacing: 1) {
        Text(content.author)
          .font(.caption2.weight(.semibold))
        Text(content.text)
          .font(.caption2)
          .lineLimit(1)
      }
      .foregroundStyle(isOutgoing ? palette.outgoingText.opacity(0.86) : palette.incomingText.opacity(0.8))
    }
    .padding(.horizontal, isInsideBubble ? 6 : 0)
    .padding(.vertical, isInsideBubble ? 4 : 1)
    .background(
      isInsideBubble ? palette.replyBackground(isOutgoing: isOutgoing) : .clear,
      in: RoundedRectangle(cornerRadius: 6, style: .continuous)
    )
  }
}

private struct OnboardingPreviewAvatar: View {
  let identity: OnboardingPreviewIdentity
  let palette: OnboardingPreviewPalette

  var body: some View {
    if let avatarImage = identity.avatarImage {
      Image(nsImage: avatarImage)
        .resizable()
        .scaledToFill()
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    } else {
      Text(identity.initials.isEmpty ? "?" : identity.initials)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(palette.avatar, in: Circle())
    }
  }
}

private struct OnboardingPreviewPalette {
  let name: Color
  let avatar: Color
  let outgoingBubble: Color
  let incomingBubble: Color
  let outgoingText: Color
  let incomingText: Color

  init(isDark: Bool) {
    name = Color(nsColor: .controlAccentColor)
    avatar = Color(nsColor: .controlAccentColor)
    outgoingBubble = Color(nsColor: .controlAccentColor)
    incomingBubble = Color(white: isDark ? 0.22 : 0.91)
    outgoingText = .white
    incomingText = .primary
  }

  func replyBackground(isOutgoing: Bool) -> Color {
    isOutgoing ? outgoingText.opacity(0.12) : incomingText.opacity(0.06)
  }
}
