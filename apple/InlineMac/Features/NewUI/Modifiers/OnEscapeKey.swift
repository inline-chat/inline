import AppKit
import SwiftUI

private struct OnEscapeKeyModifier: ViewModifier {
  let id: String
  let enabled: Bool
  let action: () -> Void

  func body(content: Content) -> some View {
    content
      .background {
        EscapeKeyHandlerInstaller(id: id, enabled: enabled, action: action)
          .frame(width: 0, height: 0)
      }
  }
}

extension View {
  func attachWindowKeyMonitor(_ keyMonitor: KeyMonitor) -> some View {
    onHostingWindowChange { window in
      keyMonitor.attach(window: window)
    }
  }

  func onEscapeKey(
    _ id: String,
    enabled: Bool = true,
    perform action: @escaping () -> Void
  ) -> some View {
    modifier(OnEscapeKeyModifier(id: id, enabled: enabled, action: action))
  }
}

private struct EscapeKeyHandlerInstaller: NSViewRepresentable {
  @Environment(\.keyMonitor) private var keyMonitor

  let id: String
  let enabled: Bool
  let action: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.update(
      keyMonitor: keyMonitor,
      id: id,
      enabled: enabled,
      action: action
    )
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.remove()
  }

  @MainActor
  final class Coordinator {
    private weak var keyMonitor: KeyMonitor?
    private var id: String?
    private var enabled = false
    private var action: (() -> Void)?
    private var unsubscribe: (() -> Void)?

    func update(
      keyMonitor: KeyMonitor?,
      id: String,
      enabled: Bool,
      action: @escaping () -> Void
    ) {
      let needsInstall =
        self.keyMonitor !== keyMonitor ||
        self.id != id ||
        self.enabled != enabled ||
        unsubscribe == nil

      self.keyMonitor = keyMonitor
      self.id = id
      self.enabled = enabled
      self.action = action

      guard enabled, let keyMonitor else {
        remove()
        return
      }

      guard needsInstall else { return }

      remove()
      unsubscribe = keyMonitor.addHandler(for: .escape, key: id) { [weak self] _ in
        self?.action?()
      }
    }

    func remove() {
      unsubscribe?()
      unsubscribe = nil
    }
  }
}
