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
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let nameLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 16, weight: .medium)
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
    backgroundColor = .systemBackground

    let centerStack = UIStackView(arrangedSubviews: [avatarView, nameLabel])
    centerStack.axis = .vertical
    centerStack.spacing = 4
    centerStack.alignment = .center
    centerStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(backButton)
    addSubview(centerStack)

    NSLayoutConstraint.activate([
      backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      backButton.widthAnchor.constraint(equalToConstant: 44),
      backButton.heightAnchor.constraint(equalToConstant: 44),

      centerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      centerStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      centerStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

      avatarView.widthAnchor.constraint(equalToConstant: 45),
      avatarView.heightAnchor.constraint(equalToConstant: 45),
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

    // Create and set up new hosting controller
    let avatar = UserAvatar(user: user, size: 36)
    let hostingController = UIHostingController(rootView: avatar)
    self.hostingController = hostingController

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
