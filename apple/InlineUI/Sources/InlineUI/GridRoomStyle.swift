import InlineKit
import InlineProtocol
import SwiftUI

/// One look and feel for Grid rooms on Mac and iPhone. Rooms are glass objects
/// that give a little under a tap, and faces spring into a room and drift out,
/// flying between rooms when you switch.
public enum GridMotion {
  /// Faces moving between rooms and rooms reshaping: snappy, a touch of bounce.
  public static let move = Animation.spring(response: 0.36, dampingFraction: 0.74)
  /// Rooms and faces arriving.
  public static let appear = Animation.spring(response: 0.42, dampingFraction: 0.62)
  /// Leaving is quick and quiet.
  public static let disappear = Animation.easeOut(duration: 0.16)
  /// Pressing down follows the finger; letting go springs back past rest.
  public static let press = Animation.spring(response: 0.18, dampingFraction: 0.82)
  public static let release = Animation.spring(response: 0.34, dampingFraction: 0.48)
}

public extension AnyTransition {
  /// A face pops in with a small bounce and leaves with the slightest shrink.
  static var gridFace: AnyTransition {
    .asymmetric(
      insertion: .scale(scale: 0.6).combined(with: .opacity).animation(GridMotion.appear),
      removal: .scale(scale: 0.86).combined(with: .opacity).animation(GridMotion.disappear)
    )
  }

  static var gridRoom: AnyTransition {
    .asymmetric(
      insertion: .scale(scale: 0.72).combined(with: .opacity).animation(GridMotion.appear),
      removal: .scale(scale: 0.9).combined(with: .opacity).animation(GridMotion.disappear)
    )
  }
}

public extension InlineProtocol.Grid {
  /// Who is in which room. Animating on it moves faces between rooms together.
  var gridLayoutKey: [[Int64]] {
    rooms.map { [$0.id] + $0.avatars.map(\.user.id) }
  }
}

/// Which faces a room shows. A full room keeps its size: the last slot turns
/// into "+N", and your own face always stays in view.
public enum GridRoomFaces {
  public static func visible(_ avatars: [GridAvatar], slots: Int) -> [GridAvatar] {
    guard avatars.count > slots, slots > 1 else { return avatars }
    var shown = Array(avatars.prefix(slots - 1))
    if !shown.contains(where: \.ownedByCurrentSession), let you = avatars.first(where: \.ownedByCurrentSession) {
      shown[shown.count - 1] = you
    }
    return shown
  }
}

public enum GridRoomShape {
  public static let cornerRadius: CGFloat = 18

  public static var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }
}

/// Squishes on press and springs back on release, like pressing a soft object.
public struct GridPressStyle: ButtonStyle {
  let pressedScale: CGFloat

  public init(pressedScale: CGFloat = 0.94) {
    self.pressedScale = pressedScale
  }

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? pressedScale : 1)
      .brightness(configuration.isPressed ? -0.03 : 0)
      .animation(configuration.isPressed ? GridMotion.press : GridMotion.release, value: configuration.isPressed)
  }
}

public extension View {
  /// The room surface: glass, tinted with the accent while you are in it.
  func gridRoomGlass(isCurrent: Bool, accent: Color) -> some View {
    modifier(GridRoomGlass(isCurrent: isCurrent, accent: accent))
  }

  /// A small glass capsule for a room's name, sitting on its top edge.
  func gridRoomTagGlass() -> some View {
    modifier(GridRoomTagGlass())
  }

  /// Rises barely under the pointer; the press is where the bounce lives.
  func gridHoverLift() -> some View {
    modifier(GridHoverLift())
  }
}

private struct GridHoverLift: ViewModifier {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .scaleEffect(isHovered && isEnabled ? 1.01 : 1)
      .animation(GridMotion.press, value: isHovered && isEnabled)
      .onHover { isHovered = $0 }
  }
}

private struct GridRoomGlass: ViewModifier {
  let isCurrent: Bool
  let accent: Color

  func body(content: Content) -> some View {
    let shape = GridRoomShape.shape
    Group {
      if #available(iOS 26.0, macOS 26.0, *) {
        content
          .glassEffect(isCurrent ? .regular.tint(accent.opacity(0.24)) : .regular, in: shape)
      } else {
        content
          .background(isCurrent ? accent.opacity(0.12) : Color.clear, in: shape)
          .background(.regularMaterial, in: shape)
      }
    }
    .overlay {
      shape.strokeBorder(isCurrent ? accent.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
    }
    .contentShape(shape)
    .animation(GridMotion.move, value: isCurrent)
  }
}

private struct GridRoomTagGlass: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.glassEffect(.regular, in: Capsule())
    } else {
      content.background(.regularMaterial, in: Capsule())
    }
  }
}

/// Holds several glass rooms so they render as one layer of glass.
public struct GridGlassGroup<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content

  public init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  public var body: some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      // Below the gap between rooms, so neighbours never melt together.
      GlassEffectContainer(spacing: spacing / 2) { content }
    } else {
      content
    }
  }
}
