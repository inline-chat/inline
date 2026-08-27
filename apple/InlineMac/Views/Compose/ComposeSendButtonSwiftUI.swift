import SwiftUI

struct ComposeSendButtonSwiftUI: View {
  @ObservedObject private var settings = AppSettings.shared
  @ObservedObject var state: ComposeSendButtonState
  let mode: ComposeControlMode
  let presentation: ComposeControlPresentation
  let allowsSendSilently: Bool
  var action: () -> Void
  var toggleSendSilently: () -> Void
  @State private var isHovering = false
  @Environment(\.colorScheme) private var colorScheme

  private var size: CGFloat { presentation.buttonSize(mode: mode) }
  private let disabledBackgroundColor: Color = Color(nsColor: .quinaryLabelColor)

  private var enabledBackgroundColor: Color {
    _ = settings.themeRevision
    guard state.sendSilently else { return Color(nsColor: Theme.accentColor) }
    return colorScheme == .dark
      ? Color(nsColor: NSColor(calibratedWhite: 0.92, alpha: 1.0))
      : Color(nsColor: NSColor(calibratedWhite: 0.28, alpha: 1.0))
  }

  private var hoveredEnabledBackgroundColor: Color {
    guard state.sendSilently else { return Color(nsColor: Theme.accentColor).opacity(0.82) }
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
    let backgroundScale = isEnabled ? (isHovering ? 0.95 : 1.0) : 0.9
    Button(action: {
      guard isEnabled else { return }
      action()
    }) {
      ZStack {
        Circle()
          .fill(
            isEnabled
              ? (isHovering ? hoveredEnabledBackgroundColor : enabledBackgroundColor)
              : disabledBackgroundColor
          )
          .frame(width: size, height: size)
          .scaleEffect(backgroundScale)
          .animation(.easeInOut(duration: 0.1), value: isHovering)
          .animation(.easeInOut(duration: 0.15), value: isEnabled)
          .animation(.easeInOut(duration: 0.18), value: state.sendSilently)

        Image(systemName: presentation.sendSymbolName)
          .font(.system(size: presentation.iconPointSize(mode: mode), weight: .medium))
          .foregroundStyle(iconForegroundColor)
          .frame(width: size, height: size)
          .opacity(isEnabled ? 1 : 0.7)
          .animation(.easeInOut(duration: 0.15), value: isEnabled)
          .animation(.easeInOut(duration: 0.18), value: state.sendSilently)
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .opacity(1.0)
    .contextMenu {
      if allowsSendSilently {
        Button(state.sendSilently ? "Disable Send Silently" : "Send as Silent") {
          toggleSendSilently()
        }
      }
    }
    .onHover { hovering in
      guard isEnabled else { return }
      isHovering = hovering
    }
  }
}

//
// #Preview {
//  ComposeSendButtonSwiftUI(state: ComposeSendButtonState(canSend: true), action: {})
//    .frame(width: 100, height: 100)
// }
