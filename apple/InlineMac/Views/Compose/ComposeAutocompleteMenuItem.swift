import AppKit
import InlineKit

final class ComposeAutocompleteMenuItem: NSTableCellView {
  private let containerView = NSView()
  private let iconContainer = NSView()
  private let iconLabel = NSTextField()
  private let iconImageView = NSImageView()
  private let titleLabel = NSTextField()
  private let subtitleLabel = NSTextField()

  private var currentItem: ComposeAutocompleteItem?
  private var _isSelected = false

  var isSelected: Bool {
    get { _isSelected }
    set {
      guard _isSelected != newValue else { return }
      _isSelected = newValue
      updateAppearance()
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with item: ComposeAutocompleteItem) {
    guard item != currentItem else { return }
    currentItem = item

    titleLabel.stringValue = item.title
    subtitleLabel.stringValue = item.subtitle ?? ""
    subtitleLabel.isHidden = item.subtitle?.isEmpty != false

    if let emoji = item.emoji, !emoji.isEmpty {
      iconLabel.stringValue = emoji
      iconLabel.font = .systemFont(ofSize: 16)
      iconLabel.isHidden = false
      iconImageView.isHidden = true
    } else if let symbol = item.symbol, !symbol.isEmpty {
      iconImageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      iconImageView.isHidden = iconImageView.image == nil
      iconLabel.stringValue = iconImageView.image == nil ? "#" : ""
      iconLabel.font = .systemFont(ofSize: 13, weight: .medium)
      iconLabel.isHidden = iconImageView.image != nil
    } else {
      iconLabel.stringValue = ""
      iconLabel.isHidden = false
      iconImageView.isHidden = true
    }
  }

  private func setupView() {
    containerView.wantsLayer = true
    containerView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(containerView)

    iconContainer.wantsLayer = true
    iconContainer.layer?.cornerRadius = 11
    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(iconContainer)

    iconLabel.isBordered = false
    iconLabel.isEditable = false
    iconLabel.isSelectable = false
    iconLabel.alignment = .center
    iconLabel.backgroundColor = .clear
    iconLabel.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.addSubview(iconLabel)

    iconImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    iconImageView.contentTintColor = .controlAccentColor
    iconImageView.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.addSubview(iconImageView)

    titleLabel.isBordered = false
    titleLabel.isEditable = false
    titleLabel.isSelectable = false
    titleLabel.backgroundColor = .clear
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(titleLabel)

    subtitleLabel.isBordered = false
    subtitleLabel.isEditable = false
    subtitleLabel.isSelectable = false
    subtitleLabel.backgroundColor = .clear
    subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(subtitleLabel)

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      iconContainer.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
      iconContainer.widthAnchor.constraint(equalToConstant: 22),
      iconContainer.heightAnchor.constraint(equalToConstant: 22),

      iconLabel.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
      iconLabel.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
      iconLabel.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

      iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      iconImageView.widthAnchor.constraint(equalToConstant: 14),
      iconImageView.heightAnchor.constraint(equalToConstant: 14),

      titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 5),

      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
      subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -4),
    ])

    updateAppearance()
  }

  private func updateAppearance() {
    if isSelected {
      containerView.layer?.backgroundColor = NSColor.accent.cgColor
      iconContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
      iconLabel.textColor = .white
      iconImageView.contentTintColor = .white
      titleLabel.textColor = .white
      subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
    } else {
      containerView.layer?.backgroundColor = NSColor.clear.cgColor
      iconContainer.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
      iconLabel.textColor = .controlAccentColor
      iconImageView.contentTintColor = .controlAccentColor
      titleLabel.textColor = .labelColor
      subtitleLabel.textColor = .secondaryLabelColor
    }
  }

  override func draw(_ dirtyRect: NSRect) {}
}
