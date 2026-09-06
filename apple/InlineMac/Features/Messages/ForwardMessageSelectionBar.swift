import AppKit
import SwiftUI

/// A compact, list-level capsule for the active message selection.
final class ForwardMessageSelectionBar: NSView {
  private let actions: NSHostingView<ForwardSelectionActions>
  private let onForward: () -> Void
  private let onCancel: () -> Void

  init(target: AnyObject, forwardAction: Selector, cancelAction: Selector) {
    let forward: () -> Void = { [weak target] in
      guard let target else { return }
      NSApp.sendAction(forwardAction, to: target, from: nil)
    }
    let cancel: () -> Void = { [weak target] in
      guard let target else { return }
      NSApp.sendAction(cancelAction, to: target, from: nil)
    }
    onForward = forward
    onCancel = cancel
    actions = NSHostingView(rootView: ForwardSelectionActions(count: 0, onForward: forward, onCancel: cancel))
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    actions.translatesAutoresizingMaskIntoConstraints = false
    addSubview(actions)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 36),
      widthAnchor.constraint(equalToConstant: 184),
      actions.leadingAnchor.constraint(equalTo: leadingAnchor),
      actions.trailingAnchor.constraint(equalTo: trailingAnchor),
      actions.topAnchor.constraint(equalTo: topAnchor),
      actions.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    toolTip = "Click to select messages. Shift-click to select a range. Escape to cancel."
  }

  required init?(coder: NSCoder) { nil }

  func update(count: Int) {
    actions.rootView = ForwardSelectionActions(count: count, onForward: onForward, onCancel: onCancel)
  }
}

private struct ForwardSelectionActions: View {
  let count: Int
  let onForward: () -> Void
  let onCancel: () -> Void

  var body: some View {
    if #available(macOS 26.0, *) {
      controls.glassEffect(.regular, in: .capsule)
    } else {
      controls.background(.regularMaterial, in: Capsule())
    }
  }

  private var controls: some View {
    HStack(spacing: 8) {
      Button(action: onCancel) {
        Image(systemName: "xmark")
          .frame(width: 28, height: 28)
          .contentShape(Circle())
      }
      .modifier(ForwardSelectionButtonHover())
      .accessibilityLabel("Cancel selection")
      .help("Cancel selection (Escape)")
      Text("\(count) selected")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
      Button(action: onForward) {
        Image(systemName: "arrowshape.turn.up.right")
          .frame(width: 28, height: 28)
          .contentShape(Circle())
      }
      .modifier(ForwardSelectionButtonHover())
      .accessibilityLabel("Forward selected messages")
      .help("Forward selected messages (Return)")
      .disabled(count == 0)
    }
    .buttonStyle(.plain)
    .font(.system(size: 12, weight: .medium))
    .padding(.horizontal, 6)
    .frame(height: 36)
  }
}

private struct ForwardSelectionButtonHover: ViewModifier {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .background(
        Color.primary.opacity(isHovered && isEnabled ? 0.07 : 0),
        in: Circle()
      )
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}
