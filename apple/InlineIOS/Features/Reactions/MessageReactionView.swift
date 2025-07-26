import InlineKit
import InlineUI
import Nuke
import NukeUI
import SwiftUI
import UIKit

struct ReactionUser {
  let userId: Int64
  let userInfo: UserInfo?

  var displayName: String {
    userInfo?.user.firstName ?? userInfo?.user.email?.components(separatedBy: "@").first ?? "User"
  }
}

class MessageReactionView: UIView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
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
  let count: Int
  let byCurrentUser: Bool
  let outgoing: Bool
  private(set) var reactionUsers: [ReactionUser]

  var onTap: ((String) -> Void)?

  // MARK: - UI Components

  private lazy var containerView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
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
    configureEmojiLabel(label)
    return label
  }()

  private lazy var avatarsContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  // MARK: - Initialization

  init(emoji: String, count: Int, byCurrentUser: Bool, outgoing: Bool, reactionUsers: [ReactionUser]) {
    self.emoji = emoji
    self.count = count
    self.byCurrentUser = byCurrentUser
    self.outgoing = outgoing
    self.reactionUsers = reactionUsers

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
    containerView.backgroundColor = byCurrentUser ?
      (
        outgoing ? ThemeManager.shared.selected.reactionOutgoingPrimary : ThemeManager.shared.selected
          .reactionIncomingPrimary
      ) :
      (
        outgoing ? ThemeManager.shared.selected.reactionOutgoingSecoundry : ThemeManager.shared.selected
          .reactionIncomingSecoundry
      )
  }

  private func setupView() {
    configureContainerAppearance()

    // Center the emoji and count labels
    stackView.distribution = .equalSpacing
    stackView.alignment = .center

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

    setupGestures()
    setupAvatars()
  }

  private func setupGestures() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)
    isUserInteractionEnabled = true

    let containerTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    containerView.addGestureRecognizer(containerTapGesture)
    containerView.isUserInteractionEnabled = true
  }

  private func setupAvatars() {
    clearExistingAvatars()
    configureAvatarsContainer()
    createAvatarViews()
  }

  private func clearExistingAvatars() {
    avatarsContainer.subviews.forEach { $0.removeFromSuperview() }
    avatarsContainer.removeConstraints(avatarsContainer.constraints)
  }

  private func configureAvatarsContainer() {
    let containerWidth = calculateAvatarsContainerWidth()
    NSLayoutConstraint.activate([
      avatarsContainer.widthAnchor.constraint(equalToConstant: containerWidth),
      avatarsContainer.heightAnchor.constraint(equalToConstant: Constants.avatarSize),
    ])
  }

  private func calculateAvatarsContainerWidth() -> CGFloat {
    guard reactionUsers.count > 0 else { return 0 }
    return Constants
      .avatarSize + CGFloat(reactionUsers.count - 1) * (Constants.avatarSize + Constants.avatarOverlapOffset)
  }

  private func createAvatarViews() {
    for (index, reactionUser) in reactionUsers.enumerated() {
      guard let userInfo = reactionUser.userInfo else { continue }

      let avatarView = UserAvatarView()
      avatarView.configure(with: userInfo, size: Constants.avatarSize)
      avatarView.translatesAutoresizingMaskIntoConstraints = false

      avatarsContainer.addSubview(avatarView)

      // Reverse the order so first avatar appears on top (rightmost)
      let reverseIndex = reactionUsers.count - 1 - index
      let leadingOffset = CGFloat(reverseIndex) * (Constants.avatarSize + Constants.avatarOverlapOffset)

      NSLayoutConstraint.activate([
        avatarView.leadingAnchor.constraint(equalTo: avatarsContainer.leadingAnchor, constant: leadingOffset),
        avatarView.centerYAnchor.constraint(equalTo: avatarsContainer.centerYAnchor),
        avatarView.widthAnchor.constraint(equalToConstant: Constants.avatarSize),
        avatarView.heightAnchor.constraint(equalToConstant: Constants.avatarSize),
      ])
    }
  }

  private func setupInteractions() {
    let interaction = UIContextMenuInteraction(delegate: self)
    addInteraction(interaction)

    // Set delegate for any long press gesture recognizers to ensure they can compete with collection view
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      for gestureRecognizer in gestureRecognizers ?? [] {
        if gestureRecognizer is UILongPressGestureRecognizer {
          gestureRecognizer.delegate = self
        }
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

  // MARK: - UIContextMenuInteractionDelegate

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    UIContextMenuConfiguration(
      identifier: nil,
      previewProvider: nil
    ) { [weak self] _ in
      guard let self else { return UIMenu(children: []) }

      // Create menu items for each user who reacted
      let userActions = reactionUsers.map { user in
        let avatarImage: UIImage = if let userInfo = user.userInfo {
          self.createAvatarImage(for: userInfo)
        } else {
          UIImage(systemName: "person.circle") ?? self.createDefaultAvatar()
        }

        return UIAction(
          title: user.displayName,
          image: avatarImage
        ) { _ in
          Navigation.shared.push(.chat(peer: .user(id: user.userId)))
        }
      }

      return UIMenu(children: userActions)
    }
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
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

  func updateCount(_ newCount: Int, animated: Bool) {
    // Avatar display is updated through updateReactionUsers
    if animated {
      UIView.animate(withDuration: Constants.animationDuration, animations: {
        self.avatarsContainer.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
      }) { _ in
        UIView.animate(withDuration: Constants.animationDuration) {
          self.avatarsContainer.transform = .identity
        }
      }
    }
  }

  func updateReactionUsers(_ newReactionUsers: [ReactionUser]) {
    reactionUsers = newReactionUsers
    setupAvatars()
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
