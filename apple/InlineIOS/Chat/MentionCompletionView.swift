import InlineKit
import Logger
import SwiftUI
import UIKit

protocol MentionCompletionDelegate: AnyObject {
  func mentionCompletion(
    _ view: MentionCompletionView,
    didSelectUser user: UserInfo,
    withText text: String,
    userId: Int64
  )
  func mentionCompletionDidRequestClose(_ view: MentionCompletionView)
}

public class MentionCompletionView: UIView {
  public static let maxHeight: CGFloat = 200
  public static let itemHeight: CGFloat = 56

  weak var delegate: MentionCompletionDelegate?

  private var participants: [UserInfo] = []
  private var filteredParticipants: [UserInfo] = []
  private var selectedIndex = 0

  private lazy var scrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.backgroundColor = .clear
    scrollView.alwaysBounceVertical = true
    scrollView.bounces = true
    return scrollView
  }()

  private lazy var stackView: UIStackView = {
    let stackView = UIStackView()
    stackView.axis = .vertical
    stackView.spacing = 0
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }()

  private lazy var backgroundView: UIVisualEffectView = {
    if #available(iOS 26.0, *) {
      let glassEffect = UIGlassEffect()
      let view = UIVisualEffectView()
      UIView.animate {
        view.effect = glassEffect
      }
      view.layer.cornerRadius = 12
      view.layer.shadowColor = UIColor.black.cgColor
      view.layer.shadowOpacity = 0.1
      view.layer.shadowOffset = CGSize(width: 0, height: 2)
      view.layer.shadowRadius = 8
      view.translatesAutoresizingMaskIntoConstraints = false
      return view
    } else {
      let effect = UIBlurEffect(style: .regular)
      let view = UIVisualEffectView(effect: effect)
      view.backgroundColor = ThemeManager.shared.selected.backgroundColor.withAlphaComponent(0.6)
      view.layer.cornerRadius = 12
      view.layer.shadowColor = UIColor.black.cgColor
      view.layer.shadowOpacity = 0.1
      view.layer.shadowOffset = CGSize(width: 0, height: 2)
      view.layer.shadowRadius = 8
      view.translatesAutoresizingMaskIntoConstraints = false
      return view
    }
  }()

  var isVisible: Bool {
    !isHidden && alpha > 0
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func setupView() {
    backgroundColor = .clear
    clipsToBounds = false
    isHidden = true
    alpha = 0
    translatesAutoresizingMaskIntoConstraints = false

    addSubview(backgroundView)
    addSubview(scrollView)
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
      stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
      stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])
  }

  func updateParticipants(_ participants: [UserInfo]) {
    self.participants = participants
    filterParticipants(with: "")
  }

  func filterParticipants(with query: String) {
    if query.isEmpty {
      filteredParticipants = participants
    } else {
      filteredParticipants = participants.filter { userInfo in
        userInfo.user.fullName.lowercased().contains(query.lowercased()) ||
          userInfo.user.username?.lowercased().contains(query.lowercased()) == true
      }
    }

    selectedIndex = 0
    updateRows()
    updateHeight()
  }

  func show() {
    guard !filteredParticipants.isEmpty else { return }

    isHidden = false
    updateHeight()

    UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
      self.alpha = 1.0
      self.transform = .identity
    }
  }

  func hide() {
    UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseIn]) {
      self.alpha = 0.0
      self.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
    } completion: { _ in
      self.isHidden = true
    }
  }

  func selectNext() {
    guard !filteredParticipants.isEmpty else { return }
    selectedIndex = (selectedIndex + 1) % filteredParticipants.count
    updateSelection()
  }

  func selectPrevious() {
    guard !filteredParticipants.isEmpty else { return }
    selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : filteredParticipants.count - 1
    updateSelection()
  }

  func selectCurrentItem() -> Bool {
    guard selectedIndex < filteredParticipants.count else { return false }
    let user = filteredParticipants[selectedIndex]
    selectUser(user)
    return true
  }

  private func selectUser(_ user: UserInfo) {
    // Use first name of user as mention text, like macOS version
    let firstName = user.user.fullName.components(separatedBy: " ").first ?? user.user.fullName
    let mentionText = "@\(firstName)"
    delegate?.mentionCompletion(self, didSelectUser: user, withText: mentionText, userId: user.user.id)
  }

  private func updateRows() {
    // Clear existing rows
    stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

    // Add new rows
    for (index, user) in filteredParticipants.enumerated() {
      let row = createUserRow(user: user, index: index)
      stackView.addArrangedSubview(row)
    }
  }

  private func createUserRow(user: UserInfo, index: Int) -> UIView {
    let containerView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.tag = index

    // Avatar
    let avatarView = UserAvatarView()
    avatarView.configure(with: user, size: 36)
    avatarView.translatesAutoresizingMaskIntoConstraints = false

    // Name label (like ComposeEmbedView's nameLabel)
    let nameLabel = UILabel()
    nameLabel.font = .systemFont(ofSize: 17, weight: .medium)
    nameLabel.textColor = .label
    nameLabel.numberOfLines = 1
    nameLabel.text = user.user.fullName.isEmpty ? (user.user.username ?? "Unknown") : user.user.fullName
    nameLabel.translatesAutoresizingMaskIntoConstraints = false

    // Username label (like ComposeEmbedView's messageLabel)
    let usernameLabel = UILabel()
    usernameLabel.font = .systemFont(ofSize: 17, weight: .regular)
    usernameLabel.textColor = .secondaryLabel
    usernameLabel.numberOfLines = 1
    usernameLabel.translatesAutoresizingMaskIntoConstraints = false

    if let username = user.user.username, !username.isEmpty, !user.user.fullName.isEmpty {
      usernameLabel.text = "@\(username)"
      usernameLabel.isHidden = false
    } else {
      usernameLabel.isHidden = true
    }

    // Labels stack (like ComposeEmbedView's labelsStackView)
    let labelsStackView = UIStackView(arrangedSubviews: [nameLabel, usernameLabel])
    labelsStackView.axis = .vertical
    labelsStackView.spacing = 4
    labelsStackView.alignment = .leading
    labelsStackView.translatesAutoresizingMaskIntoConstraints = false

    // Container stack (like ComposeEmbedView's containerStackView)
    let containerStackView = UIStackView(arrangedSubviews: [avatarView, labelsStackView])
    containerStackView.axis = .horizontal
    containerStackView.spacing = 12
    containerStackView.alignment = .center
    containerStackView.translatesAutoresizingMaskIntoConstraints = false

    containerView.addSubview(containerStackView)

    NSLayoutConstraint.activate([
      avatarView.widthAnchor.constraint(equalToConstant: 36),
      avatarView.heightAnchor.constraint(equalToConstant: 36),

      containerStackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
      containerStackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 6),
      // Match ComposeEmbedView internal margin
      containerStackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -6),
      // Match ComposeEmbedView internal margin
      containerStackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
      // Match ComposeEmbedView internal margin
      containerStackView.heightAnchor.constraint(equalToConstant: 36),

      containerView.heightAnchor.constraint(equalToConstant: Self.itemHeight),
    ])

    // Add tap gesture
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(rowTapped(_:)))
    containerView.addGestureRecognizer(tapGesture)

    return containerView
  }

  @objc private func rowTapped(_ gesture: UITapGestureRecognizer) {
    guard let view = gesture.view,
          view.tag < filteredParticipants.count else { return }

    let user = filteredParticipants[view.tag]
    selectUser(user)
  }

  private func updateSelection() {
    for (index, arrangedSubview) in stackView.arrangedSubviews.enumerated() {
      let isSelected = index == selectedIndex
      arrangedSubview.backgroundColor = isSelected ? UIColor.systemBlue.withAlphaComponent(0.1) : .clear

      if isSelected {
        // Scroll to selected item
        let yOffset = CGFloat(index) * Self.itemHeight
        let visibleHeight = scrollView.bounds.height
        let contentHeight = scrollView.contentSize.height

        if yOffset < scrollView.contentOffset.y {
          scrollView.setContentOffset(CGPoint(x: 0, y: yOffset), animated: true)
        } else if yOffset + Self.itemHeight > scrollView.contentOffset.y + visibleHeight {
          let newOffset = min(yOffset + Self.itemHeight - visibleHeight, contentHeight - visibleHeight)
          scrollView.setContentOffset(CGPoint(x: 0, y: max(0, newOffset)), animated: true)
        }
      }
    }
  }

  private func updateHeight() {
    let itemCount = min(filteredParticipants.count, 4) // Max 4 items visible
    let height = CGFloat(itemCount) * Self.itemHeight
    let constrainedHeight = min(height, Self.maxHeight)

    // Update height constraint if needed
    if let heightConstraint = constraints.first(where: { $0.firstAttribute == .height }) {
      heightConstraint.constant = constrainedHeight
    } else {
      heightAnchor.constraint(equalToConstant: constrainedHeight).isActive = true
    }
  }
}
