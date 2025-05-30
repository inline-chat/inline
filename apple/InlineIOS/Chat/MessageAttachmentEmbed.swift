import InlineKit
import Logger
import SafariServices
import UIKit

class MessageAttachmentEmbed: UIView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
  private enum Constants {
    static let cornerRadius: CGFloat = 10
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 8
    static let avatarSize: CGFloat = 20
    static let lineSpacing: CGFloat = 4
  }

  private var outgoing: Bool = false
  private var url: URL?
  private var title: String?
  private var issueIdentifier: String?
  private var externalTask: ExternalTask?
  private var messageId: Int64?
  private var chatId: Int64?

  private lazy var avatarView: UserAvatarView = {
    let view = UserAvatarView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var usernameLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.numberOfLines = 1
    return label
  }()

  private lazy var checkboxImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.image = UIImage(systemName: "square")
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()

  private lazy var taskTitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 15)
    label.numberOfLines = 0
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
    title: String? = nil,
    externalTask: ExternalTask? = nil,
    messageId: Int64? = nil,
    chatId: Int64? = nil
  ) {
    self.outgoing = outgoing
    self.url = url
    self.title = title
    self.issueIdentifier = issueIdentifier
    self.externalTask = externalTask
    self.messageId = messageId
    self.chatId = chatId

    print("TITLE is \(title)")
    avatarView.configure(with: userInfo, size: Constants.avatarSize)

    let userName = userInfo.user.firstName ?? "User"
    usernameLabel.text = "\(userName) will do"

    taskTitleLabel.text = title ?? "Task"

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
        title: "Open URL",
        image: UIImage(systemName: "safari")
      ) { _ in
        guard let url = self?.url else { return }
        UIApplication.shared.open(url)
      }

      let copyURLAction = UIAction(
        title: "Copy URL",
        image: UIImage(systemName: "doc.on.doc")
      ) { _ in
        UIPasteboard.general.string = self?.url?.absoluteString
      }

      let deleteAction = UIAction(
        title: "Delete",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.showDeleteConfirmation()
      }

      return UIMenu(title: "", children: [
        openAction,
        copyURLAction,
        UIMenu(title: "", options: .displayInline, children: [
          deleteAction,
        ]),
      ])
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

  private func showDeleteConfirmation() {
    guard let viewController = findViewController() else { return }

    let alert = UIAlertController(
      title: "Delete Task",
      message: "This will delete the task from both Inline and Notion. This action cannot be undone.",
      preferredStyle: .alert
    )

    let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      self?.deleteAttachment()
    }

    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)

    alert.addAction(deleteAction)
    alert.addAction(cancelAction)

    viewController.present(alert, animated: true)
  }

  private func deleteAttachment() {
    guard let externalTask,
          let messageId,
          let chatId
    else {
      Log.shared.error("Missing required data for attachment deletion")
      return
    }

    Task {
      do {
        try await DataManager.shared.deleteAttachment(
          externalTask: externalTask,
          messageId: messageId,
          chatId: chatId
        )
      } catch {
        Log.shared.error("Failed to delete attachment", error: error)

        DispatchQueue.main.async { [weak self] in
          self?.showErrorAlert(error: error)
        }
      }
    }
  }

  private func showErrorAlert(error: Error) {
    guard let viewController = findViewController() else { return }

    let alert = UIAlertController(
      title: "Delete Failed",
      message: "Failed to delete the task: \(error.localizedDescription)",
      preferredStyle: .alert
    )

    let okAction = UIAlertAction(title: "OK", style: .default)
    alert.addAction(okAction)

    viewController.present(alert, animated: true)
  }
}

// MARK: - Layout

private extension MessageAttachmentEmbed {
  func setupViews() {
    addSubview(avatarView)
    addSubview(usernameLabel)
    addSubview(checkboxImageView)
    addSubview(taskTitleLabel)

    NSLayoutConstraint.activate([
      // First line - Avatar and username
      avatarView.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: Constants.horizontalPadding
      ),
      avatarView.topAnchor.constraint(
        equalTo: topAnchor,
        constant: Constants.verticalPadding
      ),
      avatarView.widthAnchor.constraint(equalToConstant: Constants.avatarSize),
      avatarView.heightAnchor.constraint(equalToConstant: Constants.avatarSize),

      usernameLabel.leadingAnchor.constraint(
        equalTo: avatarView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      usernameLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
      usernameLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),

      // Second line - Checkbox and task title
      checkboxImageView.leadingAnchor.constraint(
        equalTo: usernameLabel.leadingAnchor
      ),
      checkboxImageView.topAnchor.constraint(
        equalTo: usernameLabel.bottomAnchor,
        constant: Constants.lineSpacing
      ),
      checkboxImageView.widthAnchor.constraint(equalToConstant: Constants.avatarSize),
      checkboxImageView.heightAnchor.constraint(equalToConstant: Constants.avatarSize),

      taskTitleLabel.leadingAnchor.constraint(
        equalTo: checkboxImageView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      taskTitleLabel.topAnchor.constraint(equalTo: checkboxImageView.topAnchor),
      taskTitleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),

      taskTitleLabel.bottomAnchor.constraint(
        lessThanOrEqualTo: bottomAnchor,
        constant: -Constants.verticalPadding
      ),
    ])
  }

  func setupLayer() {
    layer.cornerRadius = Constants.cornerRadius
    layer.masksToBounds = true
  }

  func updateColors() {
    let textColor: UIColor = outgoing ? .white : .label
    let secondaryTextColor: UIColor = outgoing ? .white.withAlphaComponent(0.9) : .secondaryLabel
    let bgAlpha: CGFloat = outgoing ? 0.13 : 0.08
    backgroundColor = outgoing ? .white.withAlphaComponent(bgAlpha) : .systemGray.withAlphaComponent(bgAlpha)

    usernameLabel.textColor = textColor
    taskTitleLabel.textColor = textColor
    checkboxImageView.tintColor = textColor
    avatarView.tintColor = textColor
  }
}
