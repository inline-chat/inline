import AppKit
import Combine
import InlineKit
import InlineUI
import Logger
import SwiftUI

class MentionTableCellView: NSTableCellView {
  private var avatarView: ChatIconSwiftUIBridge?
  private let nameLabel = NSTextField()
  private let usernameLabel = NSTextField()
  private let containerView = NSView()

  // state
  private var currentParticipant: UserInfo?
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

  func configure(with participant: UserInfo) {
    // only if different from currently rendered participant
    guard participant != currentParticipant else { return }
    currentParticipant = participant

    nameLabel.stringValue = participant.user.displayName
    usernameLabel.stringValue = "@\(participant.user.username ?? participant.user.displayName)"

    // Remove existing avatar if any
    avatarView?.removeFromSuperview()

    // Create new avatar using ChatIconSwiftUIBridge
    let newAvatarView = ChatIconSwiftUIBridge(.user(participant), size: MentionCompletionMenu.Layout.avatarSize)
    newAvatarView.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(newAvatarView)
    avatarView = newAvatarView

    // Vertical layout - name and username stacked vertically
    NSLayoutConstraint.activate([
      newAvatarView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      newAvatarView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
      newAvatarView.widthAnchor.constraint(equalToConstant: MentionCompletionMenu.Layout.avatarSize),
      newAvatarView.heightAnchor.constraint(equalToConstant: MentionCompletionMenu.Layout.avatarSize),

      nameLabel.leadingAnchor.constraint(
        equalTo: newAvatarView.trailingAnchor,
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
        equalTo: newAvatarView.trailingAnchor,
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
