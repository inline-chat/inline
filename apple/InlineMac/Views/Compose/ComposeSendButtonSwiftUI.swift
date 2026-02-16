import SwiftUI

struct ComposeSendButtonSwiftUI: View {
  @ObservedObject var state: ComposeSendButtonState
  var action: () -> Void
  var toggleSendSilently: () -> Void
  @State private var isHovering = false
  @Environment(\.colorScheme) private var colorScheme

  private let size: CGFloat = Theme.composeButtonSize
  private let disabledBackgroundColor: Color = Color(nsColor: .quinaryLabel)

  private var enabledBackgroundColor: Color {
    guard state.sendSilently else { return .accent }
    return colorScheme == .dark
      ? Color(nsColor: NSColor(calibratedWhite: 0.92, alpha: 1.0))
      : Color(nsColor: NSColor(calibratedWhite: 0.28, alpha: 1.0))
  }

  private var hoveredEnabledBackgroundColor: Color {
    guard state.sendSilently else { return .accent.opacity(0.82) }
    return colorScheme == .dark
      ? Color(nsColor: NSColor(calibratedWhite: 0.97, alpha: 1.0))
      : Color(nsColor: NSColor(calibratedWhite: 0.22, alpha: 1.0))
  }

  private var iconForegroundColor: Color {
    guard state.sendSilently else { return .white }
    return colorScheme == .dark ? .black.opacity(0.9) : .white
  }

  var body: some View {
    let isEnabled = state.canSend
    let targetSize = isEnabled ? size : size * 0.9
    let iconSize = isEnabled ? 16.0 : 14.0
    let padding = isEnabled ? 5.0 : 4.0
    Button(action: {
      guard isEnabled else { return }
      action()
    }) {
      Image(systemName: "arrow.up")
        .font(.system(size: iconSize, weight: .semibold))
        .foregroundStyle(iconForegroundColor)
        .padding(padding)
        .frame(width: targetSize, height: targetSize)
        .background(
          Circle()
            .fill(
              isEnabled
                ? (isHovering ? hoveredEnabledBackgroundColor : enabledBackgroundColor)
                : disabledBackgroundColor
            )
        )
        .scaleEffect(isEnabled && isHovering ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
    .buttonStyle(.plain)
    .opacity(1.0)
    .contextMenu {
      Button(state.sendSilently ? "Disable Send Silently" : "Send as Silent") {
        toggleSendSilently()
      }
    }
    .onHover { hovering in
      guard isEnabled else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        isHovering = hovering
      }
    }
    .animation(.easeInOut(duration: 0.18), value: state.sendSilently)
    .animation(.easeInOut(duration: 0.15), value: isEnabled)
  }
}

//
// #Preview {
//  ComposeSendButtonSwiftUI(state: ComposeSendButtonState(canSend: true), action: {})
//    .frame(width: 100, height: 100)
// }
