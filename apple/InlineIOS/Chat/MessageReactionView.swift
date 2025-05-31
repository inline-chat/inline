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
    UIView.performWithoutAnimation {
      view.layer.cornerRadius = 14
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var stackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 0
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var emojiLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 17)

    if emoji == "✓" || emoji == "✔️" {
      let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
      let checkmarkImage = UIImage(systemName: "checkmark", withConfiguration: config)?
        .withTintColor(UIColor(hex: "#2AAC28")!, renderingMode: .alwaysOriginal)
      let imageAttachment = NSTextAttachment()
      imageAttachment.image = checkmarkImage
      let attributedString = NSAttributedString(attachment: imageAttachment)
      label.attributedText = attributedString
    } else {
      label.text = emoji
    }

    return label
  }()

  private lazy var countLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 13)
    label.text = "\(count)"
    return label
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

  private func setupView() {
    // Configure container appearance
    containerView.backgroundColor = byCurrentUser ?
      (outgoing ? UIColor.reactionBackgroundOutgoingSelf : UIColor.reactionBackgroundIncomingSelf) :
      (outgoing ? UIColor.reactionBackgroundOutgoing : UIColor.reactionBackgroundIncoming)

    // Configure text colors
    countLabel.textColor = outgoing ? .white : .label

    // Center the emoji and count labels
    stackView.distribution = .equalSpacing
    stackView.alignment = .center

    // Add subviews
    addSubview(containerView)
    containerView.addSubview(stackView)

    stackView.addArrangedSubview(emojiLabel)
    stackView.addArrangedSubview(countLabel)

    // Setup constraints
    NSLayoutConstraint.activate([
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
    ])

    // Setup tap gesture
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)
    isUserInteractionEnabled = true

    let containerTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    containerView.addGestureRecognizer(containerTapGesture)
    containerView.isUserInteractionEnabled = true
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
        let request = ImageRequest(url: remoteUrl, processors: [.resize(width: 48)])
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
    parameters.visiblePath = UIBezierPath(roundedRect: containerView.bounds, cornerRadius: 14)
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

  override var intrinsicContentSize: CGSize {
    let height = stackView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height + 8
    return CGSize(width: 48, height: height)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    intrinsicContentSize
  }

  func updateCount(_ newCount: Int, animated: Bool) {
    guard count != newCount else { return }

    if animated {
      UIView.animate(withDuration: 0.15, animations: {
        self.countLabel.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
      }) { _ in
        self.countLabel.text = "\(newCount)"
        UIView.animate(withDuration: 0.15) {
          self.countLabel.transform = .identity
        }
      }
    } else {
      countLabel.text = "\(newCount)"
    }
  }

  func updateReactionUsers(_ newReactionUsers: [ReactionUser]) {
    reactionUsers = newReactionUsers
  }

  private func createAvatarImage(for userInfo: UserInfo) -> UIImage {
    // Try to get an already loaded image first
    if let photo = userInfo.profilePhoto?.first {
      if let localUrl = photo.getLocalURL() {
        if let image = UIImage(contentsOfFile: localUrl.path) {
          return resizeImage(image, to: CGSize(width: 24, height: 24))
        }
      }

      // Check Nuke's cache for remote images
      if let remoteUrl = photo.getRemoteURL() {
        let request = ImageRequest(url: remoteUrl, processors: [.resize(width: 48)])
        if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request)?.image {
          return resizeImage(cachedImage, to: CGSize(width: 24, height: 24))
        }

        // Also check without processors in case it was cached differently
        let simpleRequest = ImageRequest(url: remoteUrl)
        if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: simpleRequest)?.image {
          return resizeImage(cachedImage, to: CGSize(width: 24, height: 24))
        }
      }
    }

    // Fallback: create initials avatar synchronously
    return createInitialsAvatar(for: userInfo, size: 24)
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

    print("Creating initials avatar: name='\(nameForInitials)', initials='\(initials)', color=\(baseColor)")

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

      // Draw initials (matching UserAvatarView font size)
      let fontSize = size * 0.5 // Matching UserAvatarView's relative sizing
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
