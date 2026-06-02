import AppKit
import InlineKit
import SwiftUI

final class ComposeAutocompleteMenuItem: NSTableCellView {
  private let containerView = NSView()
  private let iconContainer = NSView()
  private let iconLabel = NSTextField()
  private let iconImageView = NSImageView()
  private let titleLabel = NSTextField()
  private let subtitleLabel = NSTextField()

  private var threadIconView: NSHostingView<AnyView>?
  private var threadIconEmoji: String?
  private var currentItem: ComposeAutocompleteItem?
  private var _isSelected = false

  private enum Layout {
    static let iconSize: CGFloat = 20
  }

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

    if item.kind == .thread {
      showThreadIcon(emoji: item.emoji)
    } else if item.kind == .emoji, let emoji = item.emoji, !emoji.isEmpty {
      hideThreadIcon()
      iconLabel.stringValue = emoji
      iconLabel.font = .systemFont(ofSize: 16)
      iconLabel.isHidden = false
      iconImageView.isHidden = true
    } else {
      hideThreadIcon()
      let symbol = item.symbol ?? "bubble.left"
      iconImageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        ?? NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
      iconImageView.isHidden = iconImageView.image == nil
      iconLabel.stringValue = ""
      iconLabel.isHidden = true
    }
  }

  private func setupView() {
    containerView.wantsLayer = true
    containerView.layer?.cornerRadius = 7
    containerView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(containerView)

    iconContainer.wantsLayer = true
    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(iconContainer)

    iconLabel.isBordered = false
    iconLabel.isEditable = false
    iconLabel.isSelectable = false
    iconLabel.alignment = .center
    iconLabel.backgroundColor = .clear
    iconLabel.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.addSubview(iconLabel)

    iconImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    iconImageView.contentTintColor = .secondaryLabelColor
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
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      containerView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

      iconContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 7),
      iconContainer.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
      iconContainer.widthAnchor.constraint(equalToConstant: Layout.iconSize),
      iconContainer.heightAnchor.constraint(equalToConstant: Layout.iconSize),

      iconLabel.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
      iconLabel.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
      iconLabel.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

      iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      iconImageView.widthAnchor.constraint(equalToConstant: 15),
      iconImageView.heightAnchor.constraint(equalToConstant: 15),

      titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -7),
      titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 3),

      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
      subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -2),
    ])

    updateAppearance()
  }

  private func showThreadIcon(emoji: String?) {
    iconLabel.stringValue = ""
    iconLabel.isHidden = true
    iconImageView.image = nil
    iconImageView.isHidden = true

    let rootView = AnyView(SidebarThreadIcon(
      emoji: emoji,
      size: Layout.iconSize,
      shape: .roundedSquare
    ))

    if let threadIconView {
      if threadIconEmoji != emoji {
        threadIconView.rootView = rootView
        threadIconEmoji = emoji
      }
      threadIconView.isHidden = false
      return
    }

    let view = NSHostingView(rootView: rootView)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    iconContainer.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
      view.topAnchor.constraint(equalTo: iconContainer.topAnchor),
      view.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
    ])

    threadIconView = view
    threadIconEmoji = emoji
  }

  private func hideThreadIcon() {
    threadIconView?.isHidden = true
  }

  private func updateAppearance() {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

    if isSelected {
      containerView.layer?.backgroundColor = NSColor.controlAccentColor
        .withAlphaComponent(isDark ? 0.52 : 0.34)
        .resolvedColor(with: effectiveAppearance)
        .cgColor
      iconContainer.layer?.backgroundColor = NSColor.clear.cgColor
      iconLabel.textColor = .labelColor
      iconImageView.contentTintColor = .labelColor
      titleLabel.textColor = .labelColor
      subtitleLabel.textColor = .secondaryLabelColor
    } else {
      containerView.layer?.backgroundColor = NSColor.clear.cgColor
      iconContainer.layer?.backgroundColor = NSColor.clear.cgColor
      iconLabel.textColor = .labelColor
      iconImageView.contentTintColor = .secondaryLabelColor
      titleLabel.textColor = .labelColor
      subtitleLabel.textColor = .secondaryLabelColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  override func draw(_ dirtyRect: NSRect) {}
}
