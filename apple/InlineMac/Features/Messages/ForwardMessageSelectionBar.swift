import AppKit

/// Uses the same capsule, detached controls and viewport spacing as Glass Compose.
final class ForwardMessageSelectionBar: NSView {
  private static let mode = ComposeControlMode.glass
  static var height: CGFloat { mode.wrapperMinHeight }

  private let countLabel = NSTextField(labelWithString: "")
  private let cancelButton = NSButton()
  private let forwardButton = NSButton()
  private let deleteButton = NSButton()
  private let progress = NSProgressIndicator()
  private let onForward: () -> Void
  private let onDelete: () -> Void
  private let onCancel: () -> Void

  init(
    surfaceStyle: ChatViewAppearance.SurfaceStyle = .content,
    onForward: @escaping () -> Void,
    onDelete: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onForward = onForward
    self.onDelete = onDelete
    self.onCancel = onCancel
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let background = GlassComposeBackgroundUnderlayView(surfaceStyle: surfaceStyle)
    pin(background, to: self)

    let controls = NSView()
    let pillContent = NSView()
    let capsule: NSView
    let container: NSView
    if #available(macOS 26.0, *) {
      let glassContainer = NSGlassEffectContainerView()
      glassContainer.spacing = Self.mode.glassSpacing
      glassContainer.contentView = controls
      pin(controls, to: controls.superview ?? glassContainer)
      container = glassContainer

      let glass = NSGlassEffectView()
      glass.style = .regular
      glass.cornerRadius = Self.mode.textMinHeight / 2
      if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
      glass.contentView = pillContent
      pin(pillContent, to: pillContent.superview ?? glass)
      capsule = glass
    } else {
      container = controls
      let material = NSVisualEffectView()
      material.material = .popover
      material.blendingMode = .withinWindow
      material.wantsLayer = true
      material.layer?.cornerRadius = Self.mode.textMinHeight / 2
      material.layer?.masksToBounds = true
      pin(pillContent, to: material)
      capsule = material
    }

    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)
    for view in [cancelButton, capsule, deleteButton] {
      view.translatesAutoresizingMaskIntoConstraints = false
      controls.addSubview(view)
    }
    for view in [countLabel, forwardButton, progress] {
      view.translatesAutoresizingMaskIntoConstraints = false
      pillContent.addSubview(view)
    }

    configure(cancelButton, symbol: "xmark", label: "Cancel message selection", help: "Cancel selection (Escape)",
              pointSize: Self.mode.sideIconPointSize, action: #selector(cancel))
    configure(deleteButton, symbol: "trash", label: "Delete selected messages", help: "Delete selected messages (Delete)",
              pointSize: Self.mode.sideIconPointSize, action: #selector(deleteSelected))
    deleteButton.contentTintColor = .systemRed
    deleteButton.hasDestructiveAction = true
    configure(forwardButton, symbol: "arrowshape.turn.up.right", label: "Forward selected messages", help: "Choose recipients (Return)",
              pointSize: Self.mode.sendIconPointSize, action: #selector(forward))
    forwardButton.bezelColor = Theme.accentColor
    forwardButton.contentTintColor = .white

    countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    countLabel.textColor = .labelColor
    countLabel.lineBreakMode = .byTruncatingTail
    countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    progress.style = .spinning
    progress.controlSize = .small
    progress.isDisplayedWhenStopped = false

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.mode.viewportHorizontalInset),
      container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.mode.viewportHorizontalInset),
      container.topAnchor.constraint(equalTo: topAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.mode.viewportBottomInset),
      cancelButton.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
      cancelButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
      cancelButton.widthAnchor.constraint(equalToConstant: Self.mode.sideButtonSize),
      cancelButton.heightAnchor.constraint(equalToConstant: Self.mode.sideButtonSize),
      capsule.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: Self.mode.glassSpacing),
      capsule.topAnchor.constraint(equalTo: controls.topAnchor),
      capsule.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
      deleteButton.leadingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: Self.mode.glassSpacing),
      deleteButton.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
      deleteButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
      deleteButton.widthAnchor.constraint(equalToConstant: Self.mode.sideButtonSize),
      deleteButton.heightAnchor.constraint(equalToConstant: Self.mode.sideButtonSize),
      countLabel.leadingAnchor.constraint(
        equalTo: pillContent.leadingAnchor, constant: 8 + Theme.composeTextViewHorizontalPadding
      ),
      countLabel.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
      countLabel.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -8),
      progress.trailingAnchor.constraint(equalTo: forwardButton.leadingAnchor, constant: -Self.mode.pillContentInset),
      progress.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
      progress.widthAnchor.constraint(equalToConstant: 16),
      progress.heightAnchor.constraint(equalToConstant: 16),
      forwardButton.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -Self.mode.sendButtonEdgeInset),
      forwardButton.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
      forwardButton.widthAnchor.constraint(equalToConstant: Self.mode.sendButtonSize),
      forwardButton.heightAnchor.constraint(equalToConstant: Self.mode.sendButtonSize),
    ])
    update(count: 0, isDeleting: false)
  }

  required init?(coder: NSCoder) { nil }

  private func pin(_ content: NSView, to parent: NSView) {
    content.translatesAutoresizingMaskIntoConstraints = false
    if content.superview == nil { parent.addSubview(content) }
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
      content.topAnchor.constraint(equalTo: parent.topAnchor),
      content.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
  }

  private func configure(_ button: NSButton, symbol: String, label: String, help: String, pointSize: CGFloat, action: Selector) {
    button.title = ""
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
    button.setAccessibilityLabel(label)
    button.toolTip = help
    button.target = self
    button.action = action
    if #available(macOS 26.0, *) {
      button.bezelStyle = .glass
      button.borderShape = .circle
    } else {
      button.bezelStyle = .circular
    }
  }

  func update(count: Int, isDeleting: Bool) {
    countLabel.stringValue = "\(count) selected"
    countLabel.setAccessibilityLabel(count == 1 ? "1 message selected" : "\(count) messages selected")
    cancelButton.isEnabled = !isDeleting
    forwardButton.isEnabled = count > 0 && !isDeleting
    deleteButton.isEnabled = count > 0 && !isDeleting
    if isDeleting { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
  }

  @objc private func forward() { onForward() }
  @objc private func deleteSelected() { onDelete() }
  @objc private func cancel() { onCancel() }
}
