// MessageView.swift
import AppKit
import InlineKit

class MessageViewAppKit: NSView {
  static let avatarSize: CGFloat = 28
  
  // MARK: - Properties
  private var fullMessage: FullMessage
  private var showsSender: Bool
  
  private var from: User {
    fullMessage.user ?? User.deletedInstance
  }
  
  private var showsAvatar: Bool { showsSender }
  private var showsName: Bool { showsSender }
  
  private var message: Message {
    fullMessage.message
  }
  
  // MARK: - UI Components
  private lazy var avatarView: UserAvatarView = {
    let view = UserAvatarView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
  
  private lazy var nameLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    return label
  }()
  
  private lazy var messageLabel: NSTextField = {
    let label = NSTextField(wrappingLabelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isSelectable = true
    label.allowsEditingTextAttributes = false
    return label
  }()
  
  private lazy var contentStackView: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.spacing = 2
    stack.alignment = .leading
    return stack
  }()
  
  private lazy var horizontalStackView: NSStackView = {
    let stack = NSStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.alignment = .top
    return stack
  }()
  
  // MARK: - Initialization
  init(fullMessage: FullMessage, showsSender: Bool = true) {
    self.fullMessage = fullMessage
    self.showsSender = showsSender
    super.init(frame: .zero)
    setupView()
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  // MARK: - Setup
  private func setupView() {
    addSubview(horizontalStackView)
    
    if showsAvatar {
      horizontalStackView.addArrangedSubview(avatarView)
      avatarView.user = from
    } else {
      let spacerView = NSView()
      spacerView.translatesAutoresizingMaskIntoConstraints = false
      horizontalStackView.addArrangedSubview(spacerView)
      NSLayoutConstraint.activate([
        spacerView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
        spacerView.heightAnchor.constraint(equalToConstant: 1)
      ])
    }
    
    horizontalStackView.addArrangedSubview(contentStackView)
    
    if showsName {
      contentStackView.addArrangedSubview(nameLabel)
      nameLabel.stringValue = from.firstName ?? from.username ?? ""
    }
    
    contentStackView.addArrangedSubview(messageLabel)
    messageLabel.stringValue = message.text ?? "empty"
    
    NSLayoutConstraint.activate([
      horizontalStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      horizontalStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      horizontalStackView.topAnchor.constraint(equalTo: topAnchor),
      horizontalStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
      
      avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
      avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
      
      contentStackView.widthAnchor.constraint(lessThanOrEqualTo: horizontalStackView.widthAnchor)
    ])
    
    setupContextMenu()
  }
  
  private func setupContextMenu() {
    let menu = NSMenu()
    
    let idItem = NSMenuItem(title: "ID: \(message.id)", action: nil, keyEquivalent: "")
    idItem.isEnabled = false
    menu.addItem(idItem)
    
    let copyItem = NSMenuItem(title: "Copy", action: #selector(copyMessage), keyEquivalent: "c")
    menu.addItem(copyItem)
    
    menu.delegate = self
    self.menu = menu
  }
  
  // MARK: - Actions
  @objc private func copyMessage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.text ?? "", forType: .string)
  }
}

// MARK: - NSMenuDelegate
extension MessageViewAppKit: NSMenuDelegate {
  func menuWillOpen(_ menu: NSMenu) {
    // Add any additional menu handling if needed
  }
}

// MARK: - UserAvatarView
class UserAvatarView: NSView {
  var user: User? {
    didSet {
      updateAvatar()
    }
  }
  
  private func updateAvatar() {
    // Implement avatar rendering logic here
    // This would depend on your UserAvatar SwiftUI implementation
  }
}
