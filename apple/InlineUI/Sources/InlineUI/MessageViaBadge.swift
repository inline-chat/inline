import InlineKit
import SwiftUI

/// Icons for agents people commonly send through. An agent without one gets
/// no badge, only the "Sent via" label.
public enum MessageViaAgentIcon {
  struct Icon {
    let asset: String
    /// Glyphs on a transparent background sit on a light disc; app icons fill it.
    let fillsBadge: Bool
  }

  static func icon(for agentId: String) -> Icon? {
    switch agentId {
      case "claude-code", "claude": Icon(asset: "AgentIconClaude", fillsBadge: false)
      case "codex": Icon(asset: "AgentIconCodex", fillsBadge: true)
      case "chatgpt": Icon(asset: "AgentIconChatGPT", fillsBadge: true)
      case "opencode": Icon(asset: "AgentIconOpenCode", fillsBadge: false)
      default: nil
    }
  }

  /// Whether `mark` draws a badge: a bot always does, an agent only with an icon.
  public static func hasBadge(_ mark: MessageViaPresentation.Mark?) -> Bool {
    switch mark {
      case .bot: true
      case let .agent(id): icon(for: id) != nil
      case nil: false
    }
  }
}

/// The agent mark pinned to a sender's avatar when an agent sent the message
/// for them: the agent's icon, or the signing bot's avatar.
public struct MessageViaBadge: View {
  let mark: MessageViaPresentation.Mark
  let size: CGFloat

  public init(mark: MessageViaPresentation.Mark, size: CGFloat) {
    self.mark = mark
    self.size = size
  }

  public var body: some View {
    Group {
      switch mark {
        case let .agent(id):
          if let icon = MessageViaAgentIcon.icon(for: id) {
            if icon.fillsBadge {
              Image(icon.asset, bundle: .module)
                .resizable()
                .scaledToFill()
            } else {
              Circle()
                .fill(Color.white)
                .overlay {
                  Image(icon.asset, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.14)
                }
            }
          }
        case let .bot(bot):
          UserAvatar(userInfo: bot, size: size, ignoresSafeArea: true)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }

  /// Badge diameter for an avatar of `avatarSize`, so it reads at every size
  /// without covering the face.
  public static func diameter(forAvatar avatarSize: CGFloat) -> CGFloat {
    (avatarSize * 0.44).rounded()
  }
}

/// An avatar with the agent badge in its bottom-right corner, drawn inside the
/// avatar's own square so nothing spills outside its frame. No badge when the
/// agent has no icon.
public struct MessageViaAvatar<Avatar: View>: View {
  let avatarSize: CGFloat
  let mark: MessageViaPresentation.Mark?
  let ringColor: Color
  let avatar: Avatar

  public init(
    avatarSize: CGFloat,
    mark: MessageViaPresentation.Mark?,
    ringColor: Color,
    @ViewBuilder avatar: () -> Avatar
  ) {
    self.avatarSize = avatarSize
    self.mark = mark
    self.ringColor = ringColor
    self.avatar = avatar()
  }

  public var body: some View {
    avatar
      .overlay(alignment: .bottomTrailing) {
        if let mark, MessageViaAgentIcon.hasBadge(mark) {
          MessageViaBadge(mark: mark, size: MessageViaBadge.diameter(forAvatar: avatarSize))
            .padding(1.5)
            .background(Circle().fill(ringColor))
        }
      }
      .frame(width: avatarSize, height: avatarSize)
  }
}
