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
