import AppKit

/// A quiet line under the newest message, such as "Sam has notifications silenced".
final class StatusNoticeTableCell: NSView {
  static let height: CGFloat = 30

  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")

  override init(frame: NSRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    iconView.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)
    iconView.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    iconView.contentTintColor = .secondaryLabelColor

    label.font = .systemFont(ofSize: 11, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail

    let stack = NSStackView(views: [iconView, label])
    stack.orientation = .horizontal
    stack.spacing = 4
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
    ])
  }

  func configure(text: String) {
    guard label.stringValue != text else { return }
    label.stringValue = text
    setAccessibilityLabel(text)
  }
}
