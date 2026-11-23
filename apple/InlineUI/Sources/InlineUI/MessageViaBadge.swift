import InlineKit
import SwiftUI

/// Icons for agents people commonly send through. An agent without one gets
/// no badge, only the "Sent via" label.
///
/// Every icon fills its disc edge to edge: at 12–14pt a logo inset on a white
/// disc, or an app icon with its own margins, shrinks to a few unreadable pixels.
public enum MessageViaAgentIcon {
  enum Glyph {
    /// An image from the agent icon catalog; `tint` recolors a one-color mark.
    case asset(String, tint: Color?)
    /// Text drawn in a bold monospaced face, such as Codex's prompt.
    case text(String)
  }

  struct Icon {
    let background: LinearGradient
    let glyph: Glyph
    /// Glyph size as a fraction of the badge diameter.
    let glyphScale: CGFloat
    /// A light disc needs a hairline to read on light backgrounds.
    let isLight: Bool
  }

  static func icon(for agentId: String) -> Icon? {
    switch agentId {
      case "claude-code", "claude":
        Icon(
          background: solid(red: 0.851, green: 0.467, blue: 0.341),
          glyph: .asset("AgentIconClaude", tint: .white),
          glyphScale: 0.84,
          isLight: false
        )
      case "codex":
        Icon(
          background: LinearGradient(
            colors: [Color(red: 0.55, green: 0.56, blue: 1.0), Color(red: 0.25, green: 0.33, blue: 0.93)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          glyph: .text(">_"),
          glyphScale: 0.54,
          isLight: false
        )
      case "chatgpt":
        // The asset is the whole badge: a black disc with the logo.
        Icon(background: solid(red: 0, green: 0, blue: 0), glyph: .asset("AgentIconChatGPT", tint: nil), glyphScale: 1, isLight: false)
      case "opencode":
        Icon(background: solid(red: 1, green: 1, blue: 1), glyph: .asset("AgentIconOpenCode", tint: nil), glyphScale: 1, isLight: true)
      default:
        nil
    }
  }

  private static func solid(red: Double, green: Double, blue: Double) -> LinearGradient {
    let color = Color(red: red, green: green, blue: blue)
    return LinearGradient(colors: [color, color], startPoint: .top, endPoint: .bottom)
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
            agentIcon(icon)
          }
        case let .bot(bot):
          UserAvatar(userInfo: bot, size: size, ignoresSafeArea: true)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }

  private func agentIcon(_ icon: MessageViaAgentIcon.Icon) -> some View {
    let glyphSide = size * icon.glyphScale
    return ZStack {
      Circle().fill(icon.background)
      switch icon.glyph {
        case let .asset(name, tint):
          if let tint {
            Image(name, bundle: .module)
              .renderingMode(.template)
              .resizable()
              .interpolation(.high)
              .scaledToFit()
              .foregroundStyle(tint)
              .frame(width: glyphSide, height: glyphSide)
          } else {
            Image(name, bundle: .module)
              .resizable()
              .interpolation(.high)
              .scaledToFit()
              .frame(width: glyphSide, height: glyphSide)
          }
        case let .text(text):
          Text(text)
            .font(.system(size: glyphSide, weight: .heavy, design: .monospaced))
            .kerning(-glyphSide * 0.08)
            .foregroundStyle(.white)
            .fixedSize()
            // Optical center: the prompt sits low in its line box.
            .offset(y: -size * 0.03)
      }
      if icon.isLight {
        Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
      }
    }
  }

  /// Badge diameter for an avatar of `avatarSize`, so it reads at every size
  /// without covering the face.
  public static func diameter(forAvatar avatarSize: CGFloat) -> CGFloat {
    max(10, (avatarSize * 0.44).rounded())
  }

  /// Clear space between the badge and the avatar it is cut out of.
  public static func gap(forAvatar avatarSize: CGFloat) -> CGFloat {
    avatarSize < 24 ? 1 : 1.5
  }

  /// Where the badge sits in an avatar square of side `avatarSide`: its
  /// bottom-right corner, inside the square, so nothing spills outside the
  /// avatar's frame. Top-left origin.
  public static func frame(inAvatar avatarSide: CGFloat) -> CGRect {
    let diameter = diameter(forAvatar: avatarSide)
    return CGRect(x: avatarSide - diameter, y: avatarSide - diameter, width: diameter, height: diameter)
  }

  /// The hole cut out of the avatar under the badge, so the badge reads on any
  /// background without a ring painted in a guessed background color.
  public static func cutout(inAvatar avatarSide: CGFloat) -> CGRect {
    let gap = gap(forAvatar: avatarSide)
    return frame(inAvatar: avatarSide).insetBy(dx: -gap, dy: -gap)
  }

  /// The avatar's visible area with the badge's hole removed, top-left origin.
  /// Fill with the even-odd rule.
  public static func avatarMaskPath(inAvatar avatarSide: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: 0, y: 0, width: avatarSide, height: avatarSide))
    path.addEllipse(in: cutout(inAvatar: avatarSide))
    return path
  }
}

/// The avatar with the badge's hole removed, for SwiftUI masks.
private struct MessageViaAvatarMask: Shape {
  let avatarSide: CGFloat

  func path(in rect: CGRect) -> SwiftUI.Path {
    var path = SwiftUI.Path()
    path.addRect(rect)
    path.addEllipse(in: MessageViaBadge.cutout(inAvatar: avatarSide).offsetBy(dx: rect.minX, dy: rect.minY))
    return path
  }
}

/// An avatar with the agent badge in its bottom-right corner, drawn inside the
/// avatar's own square so nothing spills outside its frame. The avatar is cut
/// away around the badge. No badge when the agent has no icon.
public struct MessageViaAvatar<Avatar: View>: View {
  let avatarSize: CGFloat
  let mark: MessageViaPresentation.Mark?
  let avatar: Avatar

  public init(
    avatarSize: CGFloat,
    mark: MessageViaPresentation.Mark?,
    @ViewBuilder avatar: () -> Avatar
  ) {
    self.avatarSize = avatarSize
    self.mark = mark
    self.avatar = avatar()
  }

  public var body: some View {
    if let mark, MessageViaAgentIcon.hasBadge(mark) {
      let badge = MessageViaBadge.frame(inAvatar: avatarSize)
      ZStack(alignment: .topLeading) {
        avatar
          .frame(width: avatarSize, height: avatarSize)
          .mask(MessageViaAvatarMask(avatarSide: avatarSize).fill(style: FillStyle(eoFill: true)))
        MessageViaBadge(mark: mark, size: badge.width)
          .offset(x: badge.minX, y: badge.minY)
      }
      .frame(width: avatarSize, height: avatarSize)
    } else {
      avatar
        .frame(width: avatarSize, height: avatarSize)
    }
  }
}
