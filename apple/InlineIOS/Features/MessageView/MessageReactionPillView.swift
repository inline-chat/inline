import InlineKit
import InlineMessageLayout
import InlineUI
import UIKit

/// One reaction: the emoji, then up to three reactor avatars or a count. Its size is computed
/// from the model before any view exists, so the planner can place it.
final class MessageReactionPillView: UIControl {
  struct Model: Equatable {
    var emoji: String
    var count: Int
    var byCurrentUser: Bool
    /// Shown when at most `maximumAvatars` people reacted.
    var avatars: [UserInfo]
    /// Everyone who reacted, for the long-press list.
    var users: [ReactionUser]
    var emojiLayout: TextLayout
    var countLayout: TextLayout?
    var background: UIColor
    var pressedBackground: UIColor

    static func == (lhs: Model, rhs: Model) -> Bool {
      lhs.emoji == rhs.emoji && lhs.count == rhs.count && lhs.byCurrentUser == rhs.byCurrentUser
        && lhs.avatars.map(\.user.id) == rhs.avatars.map(\.user.id)
        && lhs.users.map(\.userId) == rhs.users.map(\.userId)
        && lhs.background == rhs.background
        && lhs.emojiLayout.drawsIdentically(to: rhs.emojiLayout)
    }
  }

  enum Metrics {
    static let height: CGFloat = 32
    static let padding: CGFloat = 7
    static let spacing: CGFloat = 4
    static let avatarSize: CGFloat = 26
    static let avatarStride: CGFloat = 18
    static let maximumAvatars = 3
  }

  static func size(for model: Model) -> CGSize {
    var width = Metrics.padding + model.emojiLayout.size.width
    if !model.avatars.isEmpty {
      width += Metrics.spacing + Metrics.avatarSize + CGFloat(model.avatars.count - 1) * Metrics.avatarStride
    } else if let countLayout = model.countLayout {
      width += Metrics.spacing + countLayout.size.width
    }
    return CGSize(width: ceil(width + Metrics.padding), height: Metrics.height)
  }

  private let background = UIView()
  private let emojiView = MessageTextView()
  private let countView = MessageTextView()
  private var avatarViews: [UserAvatarLayerView] = []
  private(set) var model: Model?

  var onTap: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Children take no touches, so a tap anywhere on the pill reaches the control.
    background.isUserInteractionEnabled = false
    emojiView.isUserInteractionEnabled = false
    countView.isUserInteractionEnabled = false
    addSubview(background)
    addSubview(emojiView)
    addSubview(countView)
    isAccessibilityElement = true
    accessibilityTraits = .button
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    addTarget(self, action: #selector(handlePressDown), for: [.touchDown, .touchDragEnter])
    addTarget(self, action: #selector(handlePressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    addInteraction(UIContextMenuInteraction(delegate: self))
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let users = model?.users, !users.isEmpty else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
      MessageReactionView.reactorsMenu(for: users)
    }
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    capsulePreview()
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    capsulePreview()
  }

  private func capsulePreview() -> UITargetedPreview {
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = background.backgroundColor ?? .secondarySystemFill
    parameters.visiblePath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2)
    return UITargetedPreview(view: self, parameters: parameters)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ model: Model) {
    guard model != self.model else { return }
    self.model = model
    emojiView.setLayout(model.emojiLayout)
    countView.setLayout(model.countLayout ?? .empty)
    countView.isHidden = model.countLayout == nil || !model.avatars.isEmpty
    while avatarViews.count < model.avatars.count {
      let avatar = UserAvatarLayerView()
      avatar.isUserInteractionEnabled = false
      addSubview(avatar)
      avatarViews.append(avatar)
    }
    for (index, avatar) in avatarViews.enumerated() {
      let wasHidden = avatar.isHidden || avatar.bounds.isEmpty
      avatar.isHidden = index >= model.avatars.count
      if index < model.avatars.count {
        avatar.configure(with: model.avatars[index], size: Metrics.avatarSize)
        // A new avatar starts in its slot; the others slide over with the pill's layout.
        if wasHidden {
          UIView.performWithoutAnimation { avatar.frame = avatarFrame(at: index, of: model) }
        }
      }
    }
    // Earlier reactors draw on top, as in the current pill.
    for avatar in avatarViews.prefix(model.avatars.count).reversed() {
      bringSubviewToFront(avatar)
    }
    background.backgroundColor = model.background
    accessibilityLabel = "\(model.emoji) \(model.count)"
    accessibilityTraits = model.byCurrentUser ? [.button, .selected] : .button
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The background scales while pressed.
    background.untransformedFrame = bounds
    background.layer.cornerRadius = bounds.height / 2
    guard let model else { return }
    let emoji = model.emojiLayout.size
    emojiView.textFrame = CGRect(
      x: Metrics.padding,
      y: (Metrics.height - emoji.height) / 2,
      width: emoji.width,
      height: emoji.height
    )
    for (index, avatar) in avatarViews.enumerated() where index < model.avatars.count {
      avatar.frame = avatarFrame(at: index, of: model)
    }
    if let count = model.countLayout?.size, model.avatars.isEmpty {
      countView.textFrame = CGRect(
        x: Self.trailingX(for: model),
        y: (Metrics.height - count.height) / 2,
        width: count.width,
        height: count.height
      )
    }
  }

  private static func trailingX(for model: Model) -> CGFloat {
    Metrics.padding + model.emojiLayout.size.width + Metrics.spacing
  }

  /// Avatars stack from the trailing end, earlier reactors on top.
  private func avatarFrame(at index: Int, of model: Model) -> CGRect {
    CGRect(
      x: Self.trailingX(for: model) + CGFloat(model.avatars.count - 1 - index) * Metrics.avatarStride,
      y: (Metrics.height - Metrics.avatarSize) / 2,
      width: Metrics.avatarSize,
      height: Metrics.avatarSize
    )
  }

  @objc private func handleTap() {
    guard let model else { return }
    onTap?(model.emoji)
  }

  @objc private func handlePressDown() {
    setPressed(true)
  }

  @objc private func handlePressUp() {
    setPressed(false)
  }

  private func setPressed(_ pressed: Bool) {
    guard let model else { return }
    let updates = {
      self.background.transform = pressed ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
      self.background.backgroundColor = pressed ? model.pressedBackground : model.background
    }
    guard !UIAccessibility.isReduceMotionEnabled else {
      UIView.performWithoutAnimation(updates)
      return
    }
    UIView.animate(
      withDuration: pressed ? 0.1 : 0.18,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState],
      animations: updates
    )
  }
}
