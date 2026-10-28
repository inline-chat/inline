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
    /// How far the old and new count travel when the number rolls.
    static let rollDistance: CGFloat = 12
    /// A new pill or avatar pops in from this scale with `pop`'s bounce.
    static let popScale: CGFloat = 0.3
  }

  /// The overshoot a new pill or avatar settles with; frames and fades keep the row's motion.
  /// About as quick as the row's spring, with a small bounce that settles in under half a second.
  static func pop(_ changes: @escaping () -> Void) {
    UIView.animate(
      springDuration: 0.3,
      bounce: 0.35,
      initialSpringVelocity: 0,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: changes
    )
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
  private(set) var countView = MessageTextView()
  /// Numbers rolling out, with where they end. Each roll brings a fresh view in: an animation that
  /// begins from the current state would start a reused view from what is on screen, not from its
  /// starting state.
  private(set) var leavingCountViews: [(view: MessageTextView, target: CGRect)] = []
  /// Avatars by reactor, so a reactor's avatar moves instead of another one taking its place.
  private(set) var avatarViews: [Int64: UserAvatarLayerView] = [:]
  private var leavingAvatars: [Int64: UserAvatarLayerView] = [:]
  /// New avatars waiting for `popAppearing()`.
  private var poppingAvatars: [UserAvatarLayerView] = []
  private var pendingBackground: UIColor?
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

  /// Installs `model`. With `animated`, the caller sets starting states without animation and
  /// then runs `layoutIfNeeded()` inside the row's motion: avatars slide, the count rolls and the
  /// color crossfades on that one curve, and new avatars settle with `popAppearing()`.
  func configure(_ model: Model, animated: Bool = false) {
    guard model != self.model else { return }
    let previous = self.model
    self.model = model
    let animated = animated && previous != nil
    emojiView.setLayout(model.emojiLayout)

    // The number rolls up when it grows and down when it shrinks: the shown number leaves and a
    // fresh view arrives.
    if !animated {
      leavingCountViews.forEach { $0.view.removeFromSuperview() }
      leavingCountViews.removeAll()
    }
    if animated, let previous, Self.showsCount(previous), Self.showsCount(model), previous.count != model.count,
       let oldFrame = Self.countFrame(for: previous), let newFrame = Self.countFrame(for: model)
    {
      let direction: CGFloat = model.count > previous.count ? 1 : -1
      leavingCountViews.append((countView, oldFrame.offsetBy(dx: 0, dy: -direction * Metrics.rollDistance)))
      let arriving = MessageTextView()
      arriving.isUserInteractionEnabled = false
      addSubview(arriving)
      arriving.setLayout(model.countLayout ?? .empty)
      arriving.textFrame = newFrame.offsetBy(dx: 0, dy: direction * Metrics.rollDistance)
      arriving.alpha = 0
      countView = arriving
    } else {
      countView.setLayout(model.countLayout ?? .empty)
      if animated, !Self.showsCount(previous ?? model), let frame = Self.countFrame(for: model) {
        countView.textFrame = frame
        countView.alpha = 0
      }
    }

    // Avatars keep their reactor: leaving ones shrink out where they are, new ones pop in their slot.
    let ids = Set(model.avatars.map(\.user.id))
    for (id, avatar) in avatarViews where !ids.contains(id) {
      avatarViews[id] = nil
      if animated {
        leavingAvatars[id] = avatar
      } else {
        avatar.removeFromSuperview()
      }
    }
    if !animated {
      leavingAvatars.values.forEach { $0.removeFromSuperview() }
      leavingAvatars.removeAll()
    }
    for (index, info) in model.avatars.enumerated() {
      let id = info.user.id
      // A reactor who comes back mid-fade keeps their avatar; layout brings it back.
      if let returning = leavingAvatars.removeValue(forKey: id) {
        avatarViews[id] = returning
      }
      if let avatar = avatarViews[id] {
        avatar.configure(with: info, size: Metrics.avatarSize)
        continue
      }
      let avatar = UserAvatarLayerView()
      avatar.isUserInteractionEnabled = false
      addSubview(avatar)
      avatar.configure(with: info, size: Metrics.avatarSize)
      avatar.untransformedFrame = avatarFrame(at: index, of: model)
      if animated {
        avatar.alpha = 0
        avatar.transform = CGAffineTransform(scaleX: Metrics.popScale, y: Metrics.popScale)
        poppingAvatars.append(avatar)
      }
      avatarViews[id] = avatar
    }
    // Earlier reactors draw on top, as in the current pill.
    for info in model.avatars.reversed() {
      if let avatar = avatarViews[info.user.id] { bringSubviewToFront(avatar) }
    }

    if animated {
      pendingBackground = model.background
    } else {
      background.backgroundColor = model.background
    }
    accessibilityLabel = "\(model.emoji) \(model.count)"
    accessibilityTraits = model.byCurrentUser ? [.button, .selected] : .button
    setNeedsLayout()
  }

  /// New avatars settle at full size; call inside `MessageReactionPillView.pop`.
  func popAppearing() {
    for avatar in poppingAvatars {
      avatar.transform = .identity
    }
    poppingAvatars.removeAll()
  }

  /// Drops avatars that finished leaving. Interrupted ones keep animating and stay.
  func removeFinishedTransitions() {
    for (id, avatar) in leavingAvatars where avatar.layer.animationKeys()?.isEmpty ?? true {
      avatar.removeFromSuperview()
      leavingAvatars[id] = nil
    }
    leavingCountViews.removeAll { leaving in
      guard leaving.view.layer.animationKeys()?.isEmpty ?? true else { return false }
      leaving.view.removeFromSuperview()
      return true
    }
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
    for (index, info) in model.avatars.enumerated() {
      guard let avatar = avatarViews[info.user.id] else { continue }
      avatar.untransformedFrame = avatarFrame(at: index, of: model)
      avatar.alpha = 1
      if !poppingAvatars.contains(avatar) { avatar.transform = .identity }
    }
    for avatar in leavingAvatars.values {
      avatar.alpha = 0
      avatar.transform = CGAffineTransform(scaleX: Metrics.popScale, y: Metrics.popScale)
    }
    if let frame = Self.countFrame(for: model) {
      countView.textFrame = frame
    }
    countView.alpha = Self.showsCount(model) ? 1 : 0
    for leaving in leavingCountViews {
      leaving.view.textFrame = leaving.target
      leaving.view.alpha = 0
    }
    if let pendingBackground {
      background.backgroundColor = pendingBackground
      self.pendingBackground = nil
    }
  }

  private static func showsCount(_ model: Model) -> Bool {
    model.avatars.isEmpty && model.countLayout != nil
  }

  private static func countFrame(for model: Model) -> CGRect? {
    guard let size = model.countLayout?.size else { return nil }
    return CGRect(x: trailingX(for: model), y: (Metrics.height - size.height) / 2, width: size.width, height: size.height)
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
