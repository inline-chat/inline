import InlineKit
import InlineUI
import SwiftUI
import UIKit

final class ChatHeaderView: UIView {
  // MARK: - Properties

  private let backButton: UIButton = {
    let button = UIButton(type: .system)
    let backImage = UIImage(systemName: "chevron.left")
    button.setImage(backImage, for: .normal)
    button.tintColor = .secondaryLabel
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }()

  private let avatarView: UIView = {
    let view = UIView()
    view.backgroundColor = .clear
    view.translatesAutoresizingMaskIntoConstraints = false

    return view
  }()

  private let nameLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 17, weight: .medium)
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private let statusLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private var hostingController: UIHostingController<UserAvatar>?
  private weak var parentViewController: UIViewController?
  private var onBack: (() -> Void)?

  // MARK: - Initialization

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    backgroundColor = .clear

    addSubview(backButton)
    addSubview(avatarView)
    addSubview(nameLabel)
    addSubview(statusLabel)
    NSLayoutConstraint.activate([
      // Back button constraints
      backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      backButton.widthAnchor.constraint(equalToConstant: 44),
      backButton.heightAnchor.constraint(equalToConstant: 44),

      // Name label constraints - centered in view
      nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      // Status label constraints - centered in view
      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

      // Avatar view constraints - to the right of the name label
      avatarView.leadingAnchor.constraint(equalTo: trailingAnchor, constant: -38),
      avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatarView.widthAnchor.constraint(equalToConstant: 28),
      avatarView.heightAnchor.constraint(equalToConstant: 28),
    ])

    backButton.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
  }

  // MARK: - Configuration

  func configure(with user: User, parentVC: UIViewController, onBack: @escaping () -> Void) {
    // Clean up existing hosting controller first
    cleanupHostingController()

    parentViewController = parentVC
    self.onBack = onBack
    nameLabel.text = user.firstName
    statusLabel.text = "online"
    // Create and set up new hosting controller
    let avatar = UserAvatar(user: user, size: 26)
    let hostingController = UIHostingController(rootView: avatar)
    self.hostingController = hostingController

    // Add these lines to ensure transparency
    hostingController.view.backgroundColor = .clear
    hostingController.view.isOpaque = false

    // Add the hosting controller's view directly without managing the controller hierarchy
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    avatarView.addSubview(hostingController.view)

    // Set up constraints
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: avatarView.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor),
    ])

    // Force layout update
    parentVC.view.layoutIfNeeded()
  }

  private func cleanupHostingController() {
    if let hostingController = hostingController {
      hostingController.view.removeFromSuperview()
      self.hostingController = nil
    }
  }

  deinit {
    cleanupHostingController()
  }

  @objc private func backButtonTapped() {
    onBack?()
  }
}

struct ChatHeaderViewRepresentable: UIViewRepresentable {
  let user: User
  let onBack: () -> Void

  func makeUIView(context: Context) -> ChatHeaderView {
    ChatHeaderView()
  }

  func updateUIView(_ uiView: ChatHeaderView, context: Context) {
    if let viewController = context.environment.hostingViewController() {
      uiView.configure(with: user, parentVC: viewController, onBack: onBack)
    }
  }
}

extension EnvironmentValues {
  var hostingViewController: () -> UIViewController? {
    return { [weak controller = UIApplication.shared.keyWindow?.rootViewController] in
      controller
    }
  }
}
