import AppKit

final class UnreadSeparatorTableCell: NSView {
  static let height: CGFloat = 24

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

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
    ])
  }

  private func updateBackgroundColor() {
    guard let layer else { return }
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
