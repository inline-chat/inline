import AppKit
import InlineKit
import SwiftUI

extension MainSplitView {
  func viewController(for route: Nav2Route) -> NSViewController {
    switch route {
      case .empty:
        return PlaceholderContentViewController(message: "Select a chat to get started")

      case let .chat(peer):
        return ChatViewAppKit(peerId: peer, dependencies: dependencies)

      case let .chatInfo(peer):
        return NSHostingController(
          rootView: ChatInfo(peerId: peer)
            .environment(dependencies: dependencies)
        )

      case let .profile(userId):
        if let userInfo = ObjectCache.shared.getUser(id: userId) {
          return NSHostingController(
            rootView: UserProfile(userInfo: userInfo)
              .environment(dependencies: dependencies)
          )
        }
        return PlaceholderContentViewController(message: "Profile unavailable")

      case .createSpace:
        return CreateSpaceViewController(dependencies: dependencies)

      case .newChat:
        if let spaceId = dependencies.nav2?.activeSpaceId {
          return NewChatViewController(spaceId: spaceId, dependencies: dependencies)
        }
        return PlaceholderContentViewController(message: "Open a space to start a chat")

      case .inviteToSpace:
        if let spaceId = dependencies.nav2?.activeSpaceId {
          return InviteToSpaceViewController(spaceId: spaceId, dependencies: dependencies)
        }
        return PlaceholderContentViewController(message: "Open a space to invite members")
    }
  }
}

private final class PlaceholderContentViewController: NSViewController {
  private let message: String
  private let imageView = NSImageView()

  init(message: String) {
    self.message = message
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let label = NSTextField(labelWithString: message)
    label.alignment = .center
    label.textColor = .secondaryLabelColor

    imageView.image = NSImage(named: "inline-logo-bg")
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false

    let container = AppearanceAwareView { [weak self] in
      self?.updateForAppearance()
    }

    container.addSubview(imageView)
    container.addSubview(label)

    label.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
      imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 320),

      label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
    ])

    view = container
    updateForAppearance()
  }

  private func updateForAppearance() {
    let bestMatch = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    let isDarkMode = bestMatch == .darkAqua
    imageView.alphaValue = isDarkMode ? 0.2 : 1.0
  }
}

private final class AppearanceAwareView: NSView {
  private let onChange: () -> Void

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onChange()
  }
}
