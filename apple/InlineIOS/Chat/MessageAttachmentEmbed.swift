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
  }

  static let height = 28.0
  private var outgoing: Bool = false
  private var url: URL?
  private var title: String?
  private var issueIdentifier: String?

  private lazy var circleImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    imageView.image = UIImage(systemName: "circle", withConfiguration: config)
    imageView.contentMode = .scaleAspectFit
    return imageView
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
    userName: String,
    outgoing: Bool,
    url: URL? = nil,
    issueIdentifier: String? = nil,
    title: String? = nil
  ) {
    self.outgoing = outgoing
    self.url = url
    self.title = title
    self.issueIdentifier = issueIdentifier
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
        title: "Open in Safari",
        image: UIImage(systemName: "safari")
      ) { _ in
        guard let url = self?.url else { return }
        UIApplication.shared.open(url)
      }

      var actions: [UIAction] = [openAction]

      let copyTitleAction = UIAction(
        title: "Copy Title",
        image: UIImage(systemName: "doc.on.doc")
      ) { _ in
        UIPasteboard.general.string = self?.title
      }

      let copyIssueIdentifierAction = UIAction(
        title: "Copy Issue Identifier",
        image: UIImage(systemName: "doc.on.doc")
      ) { _ in
        UIPasteboard.general.string = self?.issueIdentifier
      }
      return UIMenu(title: "", children: actions + [copyTitleAction, copyIssueIdentifierAction])
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
    addSubview(circleImageView)
    addSubview(messageLabel)
    addSubview(issueIdentifierLabel)

    NSLayoutConstraint.activate([
      circleImageView.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: Constants.horizontalPadding
      ),
      circleImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      circleImageView.widthAnchor.constraint(equalToConstant: 16),
      circleImageView.heightAnchor.constraint(equalToConstant: 16),

      messageLabel.leadingAnchor.constraint(
        equalTo: circleImageView.trailingAnchor,
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
    circleImageView.tintColor = textColor
  }
}
