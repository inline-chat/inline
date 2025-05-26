import InlineKit
import SafariServices
import UIKit

class MessageAttachmentEmbed: UIView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
  private enum Constants {
    static let cornerRadius: CGFloat = 12
    static let rectangleWidth: CGFloat = 4
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 6
    static let avatarSize: CGFloat = 20
  }

  static let height = 28.0
  private var outgoing: Bool = false
  private var url: URL?
  private var title: String?
  private var issueIdentifier: String?

  private lazy var avatarView: UserAvatarView = {
    let view = UserAvatarView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 17)
    label.numberOfLines = 1
    return label
  }()

  private lazy var issueIdentifierLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textAlignment = .right
    label.numberOfLines = 1
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupLayer()
    setupInteractions()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
    setupLayer()
    setupInteractions()
  }

  func configure(
    userInfo: UserInfo,
    outgoing: Bool,
    url: URL? = nil,
    issueIdentifier: String? = nil,
    title: String? = nil
  ) {
    self.outgoing = outgoing
    self.url = url
    self.title = title
    self.issueIdentifier = issueIdentifier
    
    // Configure avatar
    avatarView.configure(with: userInfo, size: Constants.avatarSize)
    
    // Get user name
    let userName = userInfo.user.firstName ?? "User"
    messageLabel.text = "\(userName) will do"
    issueIdentifierLabel.text = issueIdentifier
    updateColors()
  }

  private func setupInteractions() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)

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

    isUserInteractionEnabled = true
  }

  // MARK: - Context Menu

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let url else { return nil }

    return UIContextMenuConfiguration(
      identifier: nil,
      previewProvider: nil
    ) { [weak self] _ in
      let openAction = UIAction(
        title: "Open Issue URL",
        image: UIImage(systemName: "safari")
      ) { _ in
        guard let url = self?.url else { return }
        UIApplication.shared.open(url)
      }

      let copyURLAction = UIAction(
        title: "Copy Issue URL",
        image: UIImage(systemName: "doc.on.doc")
      ) { _ in
        UIPasteboard.general.string = self?.url?.absoluteString
      }

      return UIMenu(title: "", children: [openAction, copyURLAction])
    }
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
    return UITargetedPreview(view: self, parameters: parameters)
  }

  // MARK: - Actions

  @objc private func handleTap() {
    guard let url else { return }
    // Open URL directly in Safari instead of in-app
    UIApplication.shared.open(url)
  }

  // MARK: - Private Helpers

  private func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        return viewController
      }
      responder = nextResponder
    }
    return nil
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
}

// MARK: - Layout

private extension MessageAttachmentEmbed {
  func setupViews() {
    addSubview(avatarView)
    addSubview(messageLabel)
    addSubview(issueIdentifierLabel)

    NSLayoutConstraint.activate([
      avatarView.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: Constants.horizontalPadding
      ),
      avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatarView.widthAnchor.constraint(equalToConstant: Constants.avatarSize),
      avatarView.heightAnchor.constraint(equalToConstant: Constants.avatarSize),

      messageLabel.leadingAnchor.constraint(
        equalTo: avatarView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      issueIdentifierLabel.leadingAnchor.constraint(
        equalTo: messageLabel.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      issueIdentifierLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),
      issueIdentifierLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      heightAnchor.constraint(equalToConstant: MessageAttachmentEmbed.height),
    ])
  }

  func setupLayer() {
    layer.cornerRadius = Constants.cornerRadius
    layer.masksToBounds = true
  }

  func updateColors() {
    let textColor: UIColor = outgoing ? .white : .label
    let bgAlpha: CGFloat = outgoing ? 0.13 : 0.08
    backgroundColor = outgoing ? .white.withAlphaComponent(bgAlpha) : .systemGray.withAlphaComponent(bgAlpha)

    messageLabel.textColor = textColor
    issueIdentifierLabel.textColor = outgoing ? .white : .secondaryLabel
    avatarView.tintColor = textColor
  }
}
