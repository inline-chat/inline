import Auth
import InlineKit
import InlineUI
import Nuke
import NukeUI
import SwiftUI
import UIKit

struct ReactionUser {
  let userId: Int64
  let userInfo: UserInfo?
  let reactedAt: Date

  var displayName: String {
    userInfo?.user.firstName ?? userInfo?.user.email?.components(separatedBy: "@").first ?? "User"
  }
}

class MessageReactionView: UIControl, UIGestureRecognizerDelegate {
  // MARK: - Constants

  private enum Constants {
    static let avatarSize: CGFloat = 26
    static let avatarOverlapOffset: CGFloat = -8
    static let emojiSize: CGFloat = 20
    static let stackSpacing: CGFloat = 4
    static let containerPadding = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
    static let menuAvatarSize: CGFloat = 24
    static let preloadAvatarSize: CGFloat = 48
    static let animationDuration: CGFloat = 0.15
    static let intrinsicWidth: CGFloat = 48
    static let intrinsicHeightPadding: CGFloat = 8
  }

  // MARK: - Properties

  let emoji: String
  private(set) var count: Int
  private(set) var byCurrentUser: Bool
  let outgoing: Bool
  private(set) var reactionUsers: [ReactionUser]
  private var backgroundPrimaryOverride: UIColor?
  private var backgroundSecondaryOverride: UIColor?
  private var avatarsWidthConstraint: NSLayoutConstraint?
  private var avatarViewsByUserID: [Int64: UserAvatarView] = [:]
  private var avatarConstraintsByUserID: [Int64: [NSLayoutConstraint]] = [:]

  var onTap: ((String) -> Void)?

  // MARK: - UI Components

  private lazy var containerView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    return view
  }()

  private lazy var stackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = Constants.stackSpacing
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var emojiLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: Constants.emojiSize, weight: .medium)
    label.translatesAutoresizingMaskIntoConstraints = false
    configureEmojiLabel(label)
    return label
  }()

  private lazy var avatarsContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  // MARK: - Initialization

  init(
    emoji: String,
    count: Int,
    byCurrentUser: Bool,
    outgoing: Bool,
    reactionUsers: [ReactionUser],
    backgroundPrimaryOverride: UIColor? = nil,
    backgroundSecondaryOverride: UIColor? = nil
  ) {
    self.emoji = emoji
    self.count = count
    self.byCurrentUser = byCurrentUser
    self.outgoing = outgoing
    self.reactionUsers = reactionUsers
    self.backgroundPrimaryOverride = backgroundPrimaryOverride
    self.backgroundSecondaryOverride = backgroundSecondaryOverride

    super.init(frame: .zero)
    setupView()
    setupInteractions()
    preloadAvatarImages()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func configureEmojiLabel(_ label: UILabel) {
    label.text = nil
    label.attributedText = nil

    if emoji == "✓" || emoji == "✔️" {
      let config = UIImage.SymbolConfiguration(pointSize: Constants.emojiSize, weight: .semibold)
      let checkmarkColor = (byCurrentUser && !outgoing) || (!byCurrentUser && outgoing) ? UIColor
        .white : UIColor(hex: "#2AAC28")!
      let checkmarkImage = UIImage(systemName: "checkmark", withConfiguration: config)?
        .withTintColor(checkmarkColor, renderingMode: .alwaysOriginal)

      let imageAttachment = NSTextAttachment()
      imageAttachment.image = checkmarkImage
      label.attributedText = NSAttributedString(attachment: imageAttachment)
    } else {
      label.text = emoji
    }
  }

  private func configureContainerAppearance() {
    if let primaryOverride = backgroundPrimaryOverride, let secondaryOverride = backgroundSecondaryOverride {
      containerView.backgroundColor = byCurrentUser ? primaryOverride : secondaryOverride
      return
    }

    if let override = backgroundPrimaryOverride ?? backgroundSecondaryOverride {
      containerView.backgroundColor = override
      return
    }

    containerView.backgroundColor = byCurrentUser
      ? (
        outgoing ? ThemeManager.shared.selected.reactionOutgoingPrimary : ThemeManager.shared.selected
          .reactionIncomingPrimary
      )
      : (
        outgoing ? ThemeManager.shared.selected.reactionOutgoingSecoundry : ThemeManager.shared.selected
          .reactionIncomingSecoundry
      )
  }

  private func setupView() {
    configureContainerAppearance()

    // Add subviews
    addSubview(containerView)
    containerView.addSubview(stackView)

    stackView.addArrangedSubview(emojiLabel)
    stackView.addArrangedSubview(avatarsContainer)

    NSLayoutConstraint.activate([
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: Constants.containerPadding.top),
      stackView.leadingAnchor.constraint(
        equalTo: containerView.leadingAnchor,
        constant: Constants.containerPadding.left
      ),
      stackView.trailingAnchor.constraint(
        equalTo: containerView.trailingAnchor,
        constant: -Constants.containerPadding.right
      ),
      stackView.bottomAnchor.constraint(
        equalTo: containerView.bottomAnchor,
        constant: -Constants.containerPadding.bottom
      ),
    ])

    setupAvatars()
  }

  private func setupAvatars() {
    let widthConstraint = avatarsContainer.widthAnchor.constraint(equalToConstant: 0)
    avatarsWidthConstraint = widthConstraint
    NSLayoutConstraint.activate([
      widthConstraint,
      avatarsContainer.heightAnchor.constraint(equalToConstant: Constants.avatarSize),
    ])
    updateAvatars(with: reactionUsers, animated: false)
  }

  private func setupInteractions() {
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    addTarget(self, action: #selector(handlePressDown), for: [.touchDown, .touchDragEnter])
    addTarget(
      self,
      action: #selector(handlePressUp),
      for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
    )

    let interaction = UIContextMenuInteraction(delegate: self)
    addInteraction(interaction)

    // Set delegate for any long press gesture recognizers to ensure they can compete with collection view
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      for gestureRecognizer in gestureRecognizers ?? []
        where gestureRecognizer is UILongPressGestureRecognizer {
        gestureRecognizer.delegate = self
      }
    }
  }

  private func preloadAvatarImages() {
    // Preload avatar images in the background for better context menu performance
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }

      for user in reactionUsers {
        guard let userInfo = user.userInfo,
              let photo = userInfo.profilePhoto?.first,
              let remoteUrl = photo.getRemoteURL() else { continue }

        // Check if already cached
        let request = ImageRequest(url: remoteUrl, processors: [.resize(width: Constants.preloadAvatarSize)])
        if ImagePipeline.shared.cache.cachedImage(for: request) == nil {
          // Preload the image
          try? await ImagePipeline.shared.image(for: request)
        }
      }
    }
  }

  // MARK: - Actions

  @objc private func handleTap() {
    onTap?(emoji)
  }

  @objc private func handlePressDown() {
    setPressed(true)
  }

  @objc private func handlePressUp() {
    setPressed(false)
  }

  private func setPressed(_ pressed: Bool) {
    let updates = {
      self.containerView.transform = pressed
        ? CGAffineTransform(scaleX: 0.96, y: 0.96)
        : .identity
      self.containerView.alpha = pressed ? 0.82 : 1
    }

    guard !UIAccessibility.isReduceMotionEnabled else {
      UIView.performWithoutAnimation(updates)
      return
    }

    if pressed {
      UIView.animate(
        withDuration: 0.1,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: updates
      )
    } else {
      UIView.animate(
        withDuration: 0.18,
        delay: 0,
        usingSpringWithDamping: 0.82,
        initialSpringVelocity: 0.35,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: updates
      )
    }
  }

  // MARK: - UIContextMenuInteractionDelegate

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    UIContextMenuConfiguration(
      identifier: nil,
      previewProvider: nil
    ) { [weak self] _ in
      guard let self else { return UIMenu(children: []) }
      let currentUserId = Auth.shared.getCurrentUserId()
      let sortedReactionUsers = reactionUsers.sorted { $0.reactedAt > $1.reactedAt }

      // Create menu items for each user who reacted
      let userActions = sortedReactionUsers.map { user in
        let avatarImage: UIImage = if let userInfo = user.userInfo {
          self.createAvatarImage(for: userInfo)
        } else {
          UIImage(systemName: "person.circle") ?? self.createDefaultAvatar()
        }

        let userName = if let currentUserId, user.userId == currentUserId {
          "You"
        } else {
          user.displayName
        }

        return UIAction(
          title: userName,
          subtitle: self.timestampString(for: user.reactedAt),
          image: avatarImage
        ) { _ in
          NotificationCenter.default.post(
            name: Notification.Name("NavigateToUser"),
            object: nil,
            userInfo: ["userId": user.userId]
          )
        }
      }

      return UIMenu(children: userActions)
    }
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    makeContextMenuPreview()
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    makeContextMenuPreview()
  }

  private func makeContextMenuPreview() -> UITargetedPreview? {
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = containerView.backgroundColor ?? .secondarySystemFill
    parameters.visiblePath = UIBezierPath(
      roundedRect: containerView.bounds,
      cornerRadius: containerView.bounds.height / 2
    )
    return UITargetedPreview(view: containerView, parameters: parameters)
  }

  // MARK: - UIGestureRecognizerDelegate

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Allow simultaneous recognition with other gesture recognizers
    true
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Don't require other gesture recognizers to fail
    false
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Don't require this gesture recognizer to fail for others
    false
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    UIView.performWithoutAnimation {
      containerView.layer.cornerRadius = containerView.bounds.height / 2
    }
  }

  override var intrinsicContentSize: CGSize {
    let stackSize = stackView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    let width = stackSize.width + Constants.containerPadding.left + Constants.containerPadding.right
    let height = stackSize.height + Constants.containerPadding.top + Constants.containerPadding.bottom
    return CGSize(width: width, height: height)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    intrinsicContentSize
  }

  func update(
    count newCount: Int,
    byCurrentUser newByCurrentUser: Bool,
    reactionUsers newReactionUsers: [ReactionUser],
    animated: Bool
  ) {
    let appearanceChanged = byCurrentUser != newByCurrentUser
    count = newCount
    byCurrentUser = newByCurrentUser
    reactionUsers = newReactionUsers

    let updateAppearance = {
      self.configureContainerAppearance()
      self.configureEmojiLabel(self.emojiLabel)
    }
    if animated, appearanceChanged, !UIAccessibility.isReduceMotionEnabled {
      UIView.transition(
        with: containerView,
        duration: Constants.animationDuration,
        options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
        animations: updateAppearance
      )
    } else {
      UIView.performWithoutAnimation(updateAppearance)
    }

    updateAvatars(with: newReactionUsers, animated: animated)
  }

  private func updateAvatars(with users: [ReactionUser], animated: Bool) {
    let shouldAnimate = animated && !UIAccessibility.isReduceMotionEnabled
    if shouldAnimate {
      layoutIfNeeded()
    }

    let visibleUsers = users.filter { $0.userInfo != nil }
    let desiredUserIDs = visibleUsers.map(\.userId)
    let desiredUserIDSet = Set(desiredUserIDs)
    let removedUserIDs = Set(avatarViewsByUserID.keys).subtracting(desiredUserIDSet)

    var addedViews: [UserAvatarView] = []
    var removedViews: [UserAvatarView] = []
    var removedConstraints: [NSLayoutConstraint] = []

    for userID in removedUserIDs {
      guard let avatarView = avatarViewsByUserID.removeValue(forKey: userID) else { continue }
      removedViews.append(avatarView)
      if let constraints = avatarConstraintsByUserID.removeValue(forKey: userID) {
        removedConstraints.append(contentsOf: constraints)
      }
    }

    for reactionUser in visibleUsers {
      guard let userInfo = reactionUser.userInfo else { continue }

      let avatarView: UserAvatarView
      if let existingView = avatarViewsByUserID[reactionUser.userId] {
        avatarView = existingView
      } else {
        avatarView = UserAvatarView()
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.alpha = shouldAnimate ? 0 : 1
        avatarView.transform = shouldAnimate
          ? CGAffineTransform(scaleX: 0.8, y: 0.8)
          : .identity
        avatarsContainer.addSubview(avatarView)
        avatarViewsByUserID[reactionUser.userId] = avatarView
        let constraints = [
          avatarView.leadingAnchor.constraint(equalTo: avatarsContainer.leadingAnchor),
          avatarView.centerYAnchor.constraint(equalTo: avatarsContainer.centerYAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        avatarConstraintsByUserID[reactionUser.userId] = constraints
        addedViews.append(avatarView)
      }
      avatarView.configure(with: userInfo, size: Constants.avatarSize)
    }

    let overlapStride = Constants.avatarSize + Constants.avatarOverlapOffset
    for (index, userID) in desiredUserIDs.enumerated() {
      let reverseIndex = desiredUserIDs.count - 1 - index
      avatarConstraintsByUserID[userID]?.first?.constant = CGFloat(reverseIndex) * overlapStride
    }

    let containerWidth: CGFloat = if desiredUserIDs.isEmpty {
      0
    } else {
      Constants.avatarSize + CGFloat(desiredUserIDs.count - 1) * overlapStride
    }
    avatarsWidthConstraint?.constant = containerWidth
    invalidateIntrinsicContentSize()

    for userID in desiredUserIDs.reversed() {
      if let view = avatarViewsByUserID[userID] {
        avatarsContainer.bringSubviewToFront(view)
      }
    }

    let animations = {
      self.layoutIfNeeded()
      addedViews.forEach {
        $0.alpha = 1
        $0.transform = .identity
      }
      removedViews.forEach {
        $0.alpha = 0
        $0.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
      }
    }
    let completion = {
      NSLayoutConstraint.deactivate(removedConstraints)
      removedViews.forEach { $0.removeFromSuperview() }
    }

    guard shouldAnimate else {
      UIView.performWithoutAnimation(animations)
      completion()
      return
    }

    UIView.animate(
      withDuration: 0.2,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.35,
      options: [.allowUserInteraction, .beginFromCurrentState],
      animations: animations
    ) { _ in
      completion()
    }
  }

  func updateBackgroundOverrides(primary: UIColor?, secondary: UIColor?) {
    backgroundPrimaryOverride = primary
    backgroundSecondaryOverride = secondary
    configureContainerAppearance()
  }

  private func createAvatarImage(for userInfo: UserInfo) -> UIImage {
    // Try to get an already loaded image first
    if let photo = userInfo.profilePhoto?.first {
      if let localUrl = photo.getLocalURL() {
        if let image = UIImage(contentsOfFile: localUrl.path) {
          return resizeImage(image, to: CGSize(width: Constants.menuAvatarSize, height: Constants.menuAvatarSize))
        }
      }

      // Check Nuke's cache for remote images
      if let remoteUrl = photo.getRemoteURL() {
        let request = ImageRequest(url: remoteUrl, processors: [.resize(width: Constants.preloadAvatarSize)])
        if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request)?.image {
          return resizeImage(cachedImage, to: CGSize(width: Constants.menuAvatarSize, height: Constants.menuAvatarSize))
        }

        // Also check without processors in case it was cached differently
        let simpleRequest = ImageRequest(url: remoteUrl)
        if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: simpleRequest)?.image {
          return resizeImage(cachedImage, to: CGSize(width: Constants.menuAvatarSize, height: Constants.menuAvatarSize))
        }
      }
    }

    // Fallback: create initials avatar synchronously
    return createInitialsAvatar(for: userInfo, size: Constants.menuAvatarSize)
  }

  private func createInitialsAvatar(for userInfo: UserInfo, size: CGFloat) -> UIImage {
    let user = userInfo.user
    let nameForInitials = AvatarColorUtility.formatNameForHashing(
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email
    )

    let initials = nameForInitials.first.map(String.init)?.uppercased() ?? "User"
    let baseColor = AvatarColorUtility.uiColorFor(name: nameForInitials)

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    let image = renderer.image { context in
      let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))

      // Create circular clipping path
      let circlePath = UIBezierPath(ovalIn: rect)
      circlePath.addClip()

      // Draw gradient background (matching UserAvatarView)
      let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
      let adjustedColor = isDarkMode ? baseColor.adjustLuminosity(by: -0.1) : baseColor

      let colorSpace = CGColorSpaceCreateDeviceRGB()
      let colors = [
        adjustedColor.adjustLuminosity(by: 0.2).cgColor,
        adjustedColor.cgColor,
      ]

      if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0]) {
        context.cgContext.drawLinearGradient(
          gradient,
          start: CGPoint(x: rect.midX, y: rect.minY),
          end: CGPoint(x: rect.midX, y: rect.maxY),
          options: []
        )
      }

      let fontSize = size * 0.5
      let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor.white,
      ]

      let textSize = initials.size(withAttributes: attributes)
      let textRect = CGRect(
        x: (rect.width - textSize.width) / 2,
        y: (rect.height - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
      )

      initials.draw(in: textRect, withAttributes: attributes)
    }

    return image.withRenderingMode(.alwaysOriginal)
  }

  private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    let resizedImage = renderer.image { _ in
      let rect = CGRect(origin: .zero, size: size)

      // Create circular clipping path
      let circlePath = UIBezierPath(ovalIn: rect)
      circlePath.addClip()

      // Draw the image within the circular clip
      image.draw(in: rect)
    }
    return resizedImage.withRenderingMode(.alwaysOriginal)
  }

  private func createDefaultAvatar() -> UIImage {
    // Implement the logic to create a default avatar image
    // This is a placeholder and should be replaced with the actual implementation
    UIImage(systemName: "person.circle") ?? UIImage()
  }

  private func timestampString(for date: Date) -> String {
    "\(Self.menuDateFormatter.string(from: date)), \(Self.menuTimeFormatter.string(from: date))"
  }

  private static let menuDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    formatter.doesRelativeDateFormatting = true
    return formatter
  }()

  private static let menuTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()
}

// MARK: - UIColor Extension

extension UIColor {
  /// Background color for reactions on outgoing messages by others
  static let reactionBackgroundOutgoing = UIColor(.white).withAlphaComponent(0.3)

  /// Background color for reactions on outgoing messages by the current user
  static let reactionBackgroundOutgoingSelf = UIColor(.white).withAlphaComponent(0.4)

  /// Background color for reactions on incoming messages by the current user
  static let reactionBackgroundIncomingSelf = ThemeManager.shared.selected.secondaryTextColor?
    .withAlphaComponent(0.4) ?? .systemGray6.withAlphaComponent(0.5)

  /// Background color for reactions on incoming messages by others
  static let reactionBackgroundIncoming = ThemeManager.shared.selected.secondaryTextColor?
    .withAlphaComponent(0.2) ?? .systemGray6.withAlphaComponent(0.2)
}
