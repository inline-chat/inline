import AppKit
import SwiftUI

final class SpacePickerOverlayWindow: NSPanel {
  static var contentInsetX: CGFloat { SpacePickerOverlayStyle.shadowInsetX }
  static var contentInsetY: CGFloat { SpacePickerOverlayStyle.shadowInsetY }

  private let hostingView: SpacePickerHostingView
  private let contentContainer = NSView()
  private let preferredWidth: CGFloat

  init(rootView: SpacePickerOverlayView, preferredWidth: CGFloat) {
    self.preferredWidth = preferredWidth
    hostingView = SpacePickerHostingView(rootView: rootView)
    super.init(
      contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )

    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .floating
    collectionBehavior = [.fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    isMovableByWindowBackground = false
    isFloatingPanel = true
    hidesOnDeactivate = false

    contentContainer.translatesAutoresizingMaskIntoConstraints = false
    contentContainer.wantsLayer = true
    contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
    contentContainer.layer?.masksToBounds = false

    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    hostingView.layer?.masksToBounds = false

    contentContainer.addSubview(hostingView)
    contentView = contentContainer

    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(
        equalTo: contentContainer.leadingAnchor,
        constant: Self.contentInsetX
      ),
      hostingView.trailingAnchor.constraint(
        equalTo: contentContainer.trailingAnchor,
        constant: -Self.contentInsetX
      ),
      hostingView.topAnchor.constraint(
        equalTo: contentContainer.topAnchor,
        constant: Self.contentInsetY
      ),
      hostingView.bottomAnchor.constraint(
        equalTo: contentContainer.bottomAnchor,
        constant: -Self.contentInsetY
      ),
      hostingView.widthAnchor.constraint(equalToConstant: preferredWidth),
    ])

    updateContentSize()
  }

  override var canBecomeKey: Bool {
    false
  }

  override var canBecomeMain: Bool {
    false
  }

  func update(rootView: SpacePickerOverlayView) {
    hostingView.rootView = rootView
    updateContentSize()
  }

  private func updateContentSize() {
    hostingView.layoutSubtreeIfNeeded()
    let size = hostingView.fittingSize
    let insetX = Self.contentInsetX * 2
    let insetY = Self.contentInsetY * 2
    setContentSize(NSSize(width: preferredWidth + insetX, height: size.height + insetY))
  }
}

private final class SpacePickerHostingView: NSHostingView<SpacePickerOverlayView> {
  override var isOpaque: Bool {
    false
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }
}
