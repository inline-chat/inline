import AppKit
import SwiftUI

extension View {
  func nativeWindowTabTitle(_ title: String?) -> some View {
    modifier(NativeWindowTabModifier(title: title, icon: nil, updatesTitle: true, updatesIcon: false))
  }

  func nativeWindowTabIcon(_ icon: ChatIcon.PeerType?) -> some View {
    modifier(NativeWindowTabModifier(title: nil, icon: icon, updatesTitle: false, updatesIcon: true))
  }

  func nativeWindowTab(title: String?, icon: ChatIcon.PeerType?) -> some View {
    modifier(NativeWindowTabModifier(title: title, icon: icon, updatesTitle: true, updatesIcon: true))
  }
}

private struct NativeWindowTabModifier: ViewModifier {
  let title: String?
  let icon: ChatIcon.PeerType?
  let updatesTitle: Bool
  let updatesIcon: Bool

  @State private var controller = NativeWindowTabController()

  func body(content: Content) -> some View {
    content
      .onHostingWindowChange { window in
        controller.attach(to: window)
      }
      .onAppear {
        controller.update(title: title, icon: icon, updatesTitle: updatesTitle, updatesIcon: updatesIcon)
      }
      .onChange(of: title) { _, _ in
        controller.update(title: title, icon: icon, updatesTitle: updatesTitle, updatesIcon: updatesIcon)
      }
      .onChange(of: icon) { _, _ in
        controller.update(title: title, icon: icon, updatesTitle: updatesTitle, updatesIcon: updatesIcon)
      }
      .onDisappear {
        controller.clear()
      }
  }
}

@MainActor
private final class NativeWindowTabController {
  private static let iconSize: CGFloat = 18

  private var title: String?
  private var icon: ChatIcon.PeerType?
  private var updatesTitle = false
  private var updatesIcon = false
  private weak var window: NSWindow?
  private var accessoryView: ChatIconSwiftUIBridge?

  func attach(to window: NSWindow?) {
    guard self.window !== window else { return }
    detach(from: self.window)
    self.window = window
    apply()
  }

  func update(
    title: String?,
    icon: ChatIcon.PeerType?,
    updatesTitle: Bool,
    updatesIcon: Bool
  ) {
    let changed = self.title != title ||
      self.icon != icon ||
      self.updatesTitle != updatesTitle ||
      self.updatesIcon != updatesIcon
    guard changed else { return }

    if let window {
      if self.updatesTitle, updatesTitle == false {
        window.tab.title = nil
      }

      if self.updatesIcon, updatesIcon == false {
        detachIcon(from: window)
      }
    }

    self.title = title
    self.icon = icon
    self.updatesTitle = updatesTitle
    self.updatesIcon = updatesIcon
    apply()
  }

  func clear() {
    title = nil
    icon = nil
    detach(from: window)
    window = nil
    accessoryView = nil
  }

  private func apply() {
    guard let window else { return }

    if updatesTitle {
      window.tab.title = title
    }

    guard updatesIcon else { return }

    guard let icon else {
      detachIcon(from: window)
      return
    }

    if let accessoryView {
      accessoryView.update(peerType: icon)
      if window.tab.accessoryView !== accessoryView {
        window.tab.accessoryView = accessoryView
      }
      return
    }

    let accessoryView = ChatIconSwiftUIBridge(
      icon,
      size: Self.iconSize,
      backgroundOpacity: 0.95,
      ignoresSafeArea: true
    )
    accessoryView.setContentCompressionResistancePriority(.required, for: .horizontal)
    accessoryView.setContentCompressionResistancePriority(.required, for: .vertical)

    NSLayoutConstraint.activate([
      accessoryView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      accessoryView.heightAnchor.constraint(equalToConstant: Self.iconSize),
    ])

    self.accessoryView = accessoryView
    window.tab.accessoryView = accessoryView
  }

  private func detach(from window: NSWindow?) {
    guard let window else { return }

    if updatesTitle {
      window.tab.title = nil
    }

    detachIcon(from: window)
  }

  private func detachIcon(from window: NSWindow) {
    guard let accessoryView else {
      window.tab.accessoryView = nil
      return
    }
    guard window.tab.accessoryView === accessoryView else { return }
    window.tab.accessoryView = nil
  }
}
