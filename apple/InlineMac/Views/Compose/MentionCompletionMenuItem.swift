import AppKit
import Combine
import InlineKit
import InlineUI
import Logger
import SwiftUI

class MentionTableCellView: NSTableCellView {
  private var avatarView: ChatIconSwiftUIBridge?
  private var groupIconView: NSImageView?
  private let nameLabel = NSTextField()
  private let usernameLabel = NSTextField()
  private let containerView = NSView()

  // state
  private var currentItem: MentionCompletionItem?
  private var _isSelected: Bool = false

  // Custom selection state property
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

  private func setupView() {
    // Container for hover effect
    containerView.wantsLayer = true
    containerView.layer?.cornerRadius = 0
    containerView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(containerView)

    // Name label - make it more compact
    nameLabel.isBordered = false
    nameLabel.isEditable = false
    nameLabel.backgroundColor = .clear
    nameLabel.font = .systemFont(ofSize: 13, weight: .regular)
    nameLabel.textColor = .labelColor
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(nameLabel)

    // Username label - make it more compact
    usernameLabel.isBordered = false
    usernameLabel.isEditable = false
    usernameLabel.backgroundColor = .clear
    usernameLabel.font = .systemFont(ofSize: 11, weight: .regular)
    usernameLabel.textColor = .secondaryLabelColor
    usernameLabel.lineBreakMode = .byTruncatingTail
    usernameLabel.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(usernameLabel)

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  func configure(with item: MentionCompletionItem) {
    guard item != currentItem else { return }
    currentItem = item

    nameLabel.stringValue = item.title
    usernameLabel.stringValue = item.subtitle ?? ""
    usernameLabel.isHidden = item.subtitle == nil

    // Remove existing avatar if any
    avatarView?.removeFromSuperview()
    avatarView = nil
    groupIconView?.removeFromSuperview()
    groupIconView = nil

    let iconView: NSView
    switch item {
      case let .user(user):
        let newAvatarView = ChatIconSwiftUIBridge(.user(user.userInfo), size: MentionCompletionMenu.Layout.avatarSize)
        newAvatarView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(newAvatarView)
        avatarView = newAvatarView
        iconView = newAvatarView

      case .group:
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
        imageView.layer?.cornerRadius = MentionCompletionMenu.Layout.avatarSize / 2
        imageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(imageView)
        groupIconView = imageView
        iconView = imageView
    }

    // Vertical layout - name and username stacked vertically
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: MentionCompletionMenu.Layout.avatarSize),
      iconView.heightAnchor.constraint(equalToConstant: MentionCompletionMenu.Layout.avatarSize),

      nameLabel.leadingAnchor.constraint(
        equalTo: iconView.trailingAnchor,
        constant: MentionCompletionMenu.Layout.avatarNameSpacing
      ),
      nameLabel.topAnchor.constraint(
        equalTo: containerView.topAnchor,
        constant: MentionCompletionMenu.Layout.verticalPadding
      ),
      nameLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: containerView.trailingAnchor,
        constant: -MentionCompletionMenu.Layout.horizontalPadding
      ),

      usernameLabel.leadingAnchor.constraint(
        equalTo: iconView.trailingAnchor,
        constant: MentionCompletionMenu.Layout.avatarNameSpacing
      ),
      usernameLabel.topAnchor.constraint(
        equalTo: nameLabel.bottomAnchor,
        constant: MentionCompletionMenu.Layout.nameUsernameSpacing
      ),
      usernameLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: containerView.trailingAnchor,
        constant: -MentionCompletionMenu.Layout.horizontalPadding
      ),
    ])

    // Set content compression resistance so username can shrink if needed
    nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    usernameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  private func updateAppearance() {
    if isSelected {
      // Selected state: accent background with white text
      containerView.layer?.backgroundColor = NSColor.accent.cgColor
      nameLabel.textColor = .white
      usernameLabel.textColor = NSColor.white.withAlphaComponent(0.9)
    } else {
      // Normal state: clear background with standard text colors
      containerView.layer?.backgroundColor = NSColor.clear.cgColor
      nameLabel.textColor = .labelColor
      usernameLabel.textColor = .secondaryLabelColor
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    // Don't call super.draw to prevent any native background drawing
    // Our custom styling in updateAppearance handles all background drawing
  }
}
