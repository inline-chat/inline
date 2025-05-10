import AppKit
import InlineKit
import InlineUI

class ReactionItemView: NSView {
  // MARK: - Constants

  static let height: CGFloat = 30
  static let avatarSize: CGFloat = 20
  static let avatarOverlap: CGFloat = 8
  static let emojiSize: CGFloat = 16
  static let padding: CGFloat = 8

  // MARK: - Properties

  public let emoji: String
  private var reactions: [Reaction]
  private var avatarViews: [UserAvatarView] = []
  private let emojiLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.isEditable = false
    label.isBordered = false
    label.backgroundColor = .clear
    label.font = .systemFont(ofSize: 14)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let countLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.isEditable = false
    label.isBordered = false
    label.backgroundColor = .clear
    label.font = .systemFont(ofSize: 12)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  // MARK: - Initialization

  init(emoji: String, reactions: [Reaction]) {
    self.emoji = emoji
    self.reactions = reactions
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = 15
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

    // Add emoji label
    addSubview(emojiLabel)
    emojiLabel.stringValue = emoji

    // Setup constraints
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      emojiLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
      emojiLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    // Update content based on reaction count
    updateContent()
  }

  // MARK: - Content Update

  private func updateContent() {
    // Remove existing avatar views
    avatarViews.forEach { $0.removeFromSuperview() }
    avatarViews.removeAll()
    countLabel.removeFromSuperview()

    if reactions.count <= 3 {
      // Show avatars
      for (index, reaction) in reactions.prefix(3).enumerated() {
        if let userInfo = ObjectCache.shared.getUser(id: reaction.userId) {
          let avatarView = UserAvatarView(userInfo: userInfo, size: Self.avatarSize)
          avatarView.translatesAutoresizingMaskIntoConstraints = false
          addSubview(avatarView)
          avatarViews.append(avatarView)

          // Position avatar with overlap
          NSLayoutConstraint.activate([
            avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
          ])

          if index == 0 {
            avatarView.leadingAnchor.constraint(equalTo: emojiLabel.trailingAnchor, constant: 4)
              .isActive = true
          } else {
            avatarView.leadingAnchor.constraint(
              equalTo: avatarViews[index - 1].trailingAnchor,
              constant: -Self.avatarOverlap
            ).isActive = true
          }
        }
      }

      // Update width based on last avatar
      if let lastAvatar = avatarViews.last {
        trailingAnchor.constraint(equalTo: lastAvatar.trailingAnchor, constant: Self.padding).isActive = true
      }
    } else {
      // Show count
      addSubview(countLabel)
      countLabel.stringValue = "\(reactions.count)"

      NSLayoutConstraint.activate([
        countLabel.leadingAnchor.constraint(equalTo: emojiLabel.trailingAnchor, constant: 4),
        countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        trailingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: Self.padding),
      ])
    }
  }

  // MARK: - Public Methods

  func update(with reactions: [Reaction]) {
    self.reactions = reactions
    updateContent()
  }

  // MARK: - Size Calculation

  static func size(for emoji: String, reactions: [Reaction]) -> NSSize {
    // Calculate emoji width
    let emojiWidth = emoji.size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width

    // Calculate total width based on content
    let totalWidth: CGFloat
    if reactions.count <= 3 {
      // Width for avatars: first avatar has full width, subsequent ones overlap
      let avatarWidth = Self.avatarSize
      let overlapWidth = Self.avatarOverlap
      let totalAvatarWidth = avatarWidth + (CGFloat(reactions.count - 1) * (avatarWidth - overlapWidth))

      // Total width = padding + emoji + spacing + avatars + padding
      totalWidth = Self.padding + emojiWidth + 4 + totalAvatarWidth + Self.padding
    } else {
      // Width for count
      let countString = "\(reactions.count)"
      let countWidth = countString.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width

      // Total width = padding + emoji + spacing + count + padding
      totalWidth = Self.padding + emojiWidth + 4 + countWidth + Self.padding
    }

    return NSSize(width: totalWidth, height: Self.height)
  }
}
