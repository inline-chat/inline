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

/// A crossed microphone on a white disc, worn at a face's lower corner while
/// that person's microphone is off.
public struct GridMutedBadge: View {
  let diameter: CGFloat

  public init(diameter: CGFloat) {
    self.diameter = diameter
  }

  public var body: some View {
    Image(systemName: "mic.slash.fill")
      .font(.system(size: diameter * 0.48, weight: .semibold))
      .foregroundStyle(Color.black.opacity(0.6))
      .frame(width: diameter, height: diameter)
      .background(Color.white, in: Circle())
      .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
      .accessibilityHidden(true)
  }
}

public extension AnyTransition {
  static var gridBadge: AnyTransition {
    .scale(scale: 0.5).combined(with: .opacity)
  }
}

public extension View {
  /// A faint second ring just outside a face's microphone ring that thickens
  /// with the speaker's voice, so the room can see who is talking.
  ///
  /// LiveKit reports levels a few times a second, so a soft spring carries
  /// the ring between reports instead of stepping.
  func gridSpeakingHalo(level: Float, maxWidth: CGFloat = 3) -> some View {
    background {
      GridSpeakingHaloRing(gap: 1, width: GridSpeakingHaloRing.width(level: level, maxWidth: maxWidth))
        .fill(Color.green.opacity(0.3), style: FillStyle(eoFill: true))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: level)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}

/// A ring drawn outside the view's bounds; a width of zero draws nothing.
struct GridSpeakingHaloRing: Shape {
  var gap: CGFloat
  var width: CGFloat

  var animatableData: CGFloat {
    get { width }
    set { width = newValue }
  }

  func path(in rect: CGRect) -> SwiftUI.Path {
    guard width > 0.05 else { return SwiftUI.Path() }
    let inner = rect.insetBy(dx: -gap, dy: -gap)
    var path = SwiftUI.Path(ellipseIn: inner.insetBy(dx: -width, dy: -width))
    path.addEllipse(in: inner)
    return path
  }

  /// LiveKit levels are linear amplitude, so speech mostly sits between
  /// 0.01 and 0.3. Map them in decibels: -40 dB is a whisper, -10 dB is full.
  static func width(level: Float, maxWidth: CGFloat) -> CGFloat {
    guard level > 0.005 else { return 0 }
    let decibels = 20 * log10(Double(min(level, 1)))
    let loudness = min(max((decibels + 40) / 30, 0), 1)
    return 1 + (maxWidth - 1) * CGFloat(loudness)
  }
}
