import AppKit

final class UnreadSeparatorTableCell: NSView {
  private static let contentHeight: CGFloat = 24
  private static let verticalInset: CGFloat = 9
  static let height: CGFloat = contentHeight + (verticalInset * 2)

  private let contentView = NSView()
  private let label = NSTextField(labelWithString: "")
  private var currentText: String?

  override init(frame: NSRect) {
    super.init(frame: frame)
    setupView()
    updateBackgroundColor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackgroundColor()
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.wantsLayer = true
    addSubview(contentView)

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    contentView.addSubview(label)

    NSLayoutConstraint.activate([
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentView.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
      contentView.heightAnchor.constraint(equalToConstant: Self.contentHeight),

      label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
    ])
  }

  private func updateBackgroundColor() {
    guard let layer = contentView.layer else { return }
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let color = isDark
      ? NSColor.white.withAlphaComponent(0.05)
      : NSColor.black.withAlphaComponent(0.03)
    layer.backgroundColor = color.cgColor
  }

  func configure(text: String) {
    guard currentText != text else { return }
    currentText = text
    label.stringValue = text
  }
}

final class ClearedHistoryTableCell: NSView {
  static let height: CGFloat = 34
  private static let labelYOffset: CGFloat = -4

  var onRemoveClear: (() -> Void)?

  private let hoverHighlightView = NSView()
  private let label = NSTextField(labelWithString: "")
  private var currentCollapsedAt: Date?
  private var isHovered = false
  private var labelTrackingArea: NSTrackingArea?

  override init(frame: NSRect) {
    super.init(frame: frame)
    setupView()
    updateAppearance(animated: false)
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = .clear

    hoverHighlightView.translatesAutoresizingMaskIntoConstraints = false
    hoverHighlightView.wantsLayer = true
    hoverHighlightView.layer?.cornerRadius = 10
    addSubview(hoverHighlightView)

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Self.labelYOffset),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

      hoverHighlightView.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
      hoverHighlightView.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
      hoverHighlightView.centerYAnchor.constraint(equalTo: label.centerYAnchor),
      hoverHighlightView.heightAnchor.constraint(equalToConstant: 20),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityHelp(
      NSLocalizedString("Shows all messages", comment: "Cleared history accessibility help")
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance(animated: false)
  }

  override func layout() {
    super.layout()
    updateTrackingAreas()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let labelTrackingArea {
      removeTrackingArea(labelTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: interactiveRect,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self
    )
    addTrackingArea(trackingArea)
    labelTrackingArea = trackingArea
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    interactiveRect.contains(point) ? self : nil
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovered = true
    updateAppearance(animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    updateAppearance(animated: true)
  }

  override func mouseDown(with event: NSEvent) {
    onRemoveClear?()
  }

  func configure(collapsedAt: Date?) {
    guard currentCollapsedAt != collapsedAt || label.stringValue.isEmpty else { return }
    currentCollapsedAt = collapsedAt
    label.stringValue = Self.displayString(for: collapsedAt)
    setAccessibilityLabel(label.stringValue)
  }

  private var interactiveRect: NSRect {
    hoverHighlightView.frame
  }

  private func updateAppearance(animated: Bool) {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    hoverHighlightView.layer?.backgroundColor = (
      isDark ? NSColor.white : NSColor.black
    ).withAlphaComponent(0.06).cgColor

    let updates = {
      self.hoverHighlightView.alphaValue = self.isHovered ? 1 : 0
      self.label.alphaValue = self.isHovered ? 1 : 0.78
    }

    guard animated else {
      updates()
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.allowsImplicitAnimation = true
      self.hoverHighlightView.animator().alphaValue = self.isHovered ? 1 : 0
      self.label.animator().alphaValue = self.isHovered ? 1 : 0.78
    }
  }

  private static func displayString(for collapsedAt: Date?) -> String {
    guard let collapsedAt else {
      return NSLocalizedString("Cleared history", comment: "Cleared history marker fallback")
    }

    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(collapsedAt) {
      let time = collapsedAt.formatted(date: .omitted, time: .shortened)
      return String(
        format: NSLocalizedString("Cleared at %@", comment: "Cleared history marker today"),
        time
      )
    }

    let startOfToday = calendar.startOfDay(for: Date())
    let startOfCollapsedDay = calendar.startOfDay(for: collapsedAt)
    let daysAgo = calendar.dateComponents([.day], from: startOfCollapsedDay, to: startOfToday).day
    let date: String
    if let daysAgo, (1 ... 6).contains(daysAgo) {
      date = collapsedAt.formatted(.dateTime.weekday(.wide))
    } else if calendar.component(.year, from: collapsedAt) == calendar.component(.year, from: Date()) {
      date = collapsedAt.formatted(.dateTime.month(.abbreviated).day())
    } else {
      date = collapsedAt.formatted(.dateTime.month(.abbreviated).day().year())
    }
    return String(
      format: NSLocalizedString("Cleared on %@", comment: "Cleared history marker date"),
      date
    )
  }
}
