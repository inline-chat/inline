import AppKit
import InlineKit

/// Sits in the composer's place in a chat with a bot the viewer can't message:
/// says whose bot it is, and offers to message the owner. Same capsule and
/// viewport spacing as Glass Compose, so the chat's bottom edge doesn't jump.
final class BotNoAccessBar: NSView {
  private static let mode = ComposeControlMode.glass
  static var height: CGFloat { mode.wrapperMinHeight }

  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let actionButton = NSButton()
  private var labelTrailingToButton: NSLayoutConstraint!
  private var labelTrailingToEdge: NSLayoutConstraint!
  private let onMessageOwner: (Int64) -> Void
  private var ownerUserID: Int64?

  init(onMessageOwner: @escaping (Int64) -> Void) {
    self.onMessageOwner = onMessageOwner
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let pillContent = NSView()
    let capsule: NSView
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.style = .regular
      glass.cornerRadius = Self.mode.textMinHeight / 2
      glass.contentView = pillContent
      capsule = glass
    } else {
      let material = NSVisualEffectView()
      material.material = .popover
      material.blendingMode = .withinWindow
      material.wantsLayer = true
      material.layer?.cornerRadius = Self.mode.textMinHeight / 2
      material.layer?.masksToBounds = true
      material.addSubview(pillContent)
      capsule = material
    }
    capsule.translatesAutoresizingMaskIntoConstraints = false
    pillContent.translatesAutoresizingMaskIntoConstraints = false
    addSubview(capsule)

    icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    icon.contentTintColor = .secondaryLabelColor
    icon.setAccessibilityElement(false)

    label.font = .systemFont(ofSize: 13)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    actionButton.isBordered = false
    actionButton.bezelStyle = .inline
    actionButton.font = .systemFont(ofSize: 13, weight: .medium)
    actionButton.contentTintColor = .controlAccentColor
    actionButton.target = self
    actionButton.action = #selector(messageOwner)
    actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    actionButton.setContentHuggingPriority(.required, for: .horizontal)

    for view in [icon, label, actionButton] {
      view.translatesAutoresizingMaskIntoConstraints = false
      pillContent.addSubview(view)
    }

    let inset = Self.mode.pillContentInset + 4
    labelTrailingToButton = label.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12)
    labelTrailingToEdge = label.trailingAnchor.constraint(lessThanOrEqualTo: pillContent.trailingAnchor, constant: -inset)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.mode.viewportHorizontalInset),
      capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.mode.viewportHorizontalInset),
      capsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.mode.viewportBottomInset),
      capsule.heightAnchor.constraint(equalToConstant: Self.mode.textMinHeight),
      pillContent.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
      pillContent.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
      pillContent.topAnchor.constraint(equalTo: capsule.topAnchor),
      pillContent.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
      icon.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: inset),
      icon.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
      label.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
      actionButton.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -inset),
      actionButton.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func update(_ notice: BotNoAccessNotice) {
    ownerUserID = notice.ownerUserID
    label.stringValue = notice.text
    label.toolTip = notice.text
    let showsAction = notice.actionTitle != nil && notice.ownerUserID != nil
    actionButton.title = notice.actionTitle ?? ""
    actionButton.isHidden = !showsAction
    labelTrailingToButton.isActive = showsAction
    labelTrailingToEdge.isActive = !showsAction
    setAccessibilityLabel(notice.text)
  }

  @objc private func messageOwner() {
    guard let ownerUserID else { return }
    onMessageOwner(ownerUserID)
  }
}
