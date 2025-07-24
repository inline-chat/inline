import AppKit
import Foundation
import InlineKit
import Logger

class ExternalTaskAttachmentView: NSView, AttachmentView {
  let fullAttachment: FullAttachment
  let message: Message

  // Required by AttachmentView protocol
  var attachment: Attachment {
    fullAttachment.attachment
  }

  // MARK: - Theme

  static let cornerRadius: CGFloat = 6
  static let spacing: CGFloat = 4
  static let avatarSize: CGFloat = 16
  static let padding: CGFloat = 6

  // MARK: - UI

  private lazy var contentStackView = {
    let stackView = NSStackView()
    stackView.orientation = .vertical
    stackView.spacing = 2
    stackView.alignment = .leading
    return stackView
  }()

  private lazy var firstLineStackView = {
    let stackView = NSStackView()
    stackView.orientation = .horizontal
    stackView.spacing = Self.spacing
    return stackView
  }()

  private lazy var secondLineStackView = {
    let stackView = NSStackView()
    stackView.orientation = .horizontal
    stackView.spacing = Self.spacing

    return stackView
  }()

  private lazy var titleLabel = {
    let label = NSTextField()
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.isBordered = false
    label.font = .systemFont(ofSize: 13)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
  }()

  private var userAvatarView: UserAvatarView?

  private lazy var taskSquareView = {
    let view = TaskSquareView(isOutgoing: message.outgoing)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var taskCreatorLabel = {
    let label = NSTextField()
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.isBordered = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
  }()

  // MARK: - Initialization

  init(fullAttachment: FullAttachment, message: Message) {
    self.fullAttachment = fullAttachment
    self.message = message

    super.init(frame: .zero)

    // Only setup if there's an external task
    guard fullAttachment.externalTask != nil else {
      return
    }

    setup()
    configure()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setup() {
    // background view
    wantsLayer = true
    layer?.cornerRadius = Self.cornerRadius
    translatesAutoresizingMaskIntoConstraints = false

    // content stack view
    addSubview(contentStackView)
    contentStackView.addArrangedSubview(firstLineStackView)
    contentStackView.addArrangedSubview(secondLineStackView)

    // Task Creator (will be added conditionally)
    firstLineStackView.addArrangedSubview(taskCreatorLabel)

    // Task Square
    secondLineStackView.addArrangedSubview(taskSquareView)

    // Title
    secondLineStackView.addArrangedSubview(titleLabel)

    // Setup constraints
    contentStackView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      // View
      heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.externalTaskViewHeight),

      // Content stack view
      contentStackView.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
      contentStackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
      contentStackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding),
      contentStackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.padding),
    ])

    // Click
    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
    addGestureRecognizer(clickGesture)

    // Right click for context menu
    let rightClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleRightClick))
    rightClickGesture.buttonMask = 2 // Right mouse button
    addGestureRecognizer(rightClickGesture)
  }

  private func configure() {
    guard let externalTask = fullAttachment.externalTask else {
      return
    }

    taskSquareView.configure(isOutgoing: message.outgoing)

    // Configure User Avatar and insert if we have a task creator
    if let taskCreator = fullAttachment.userInfo {
      // Remove existing avatar if any
      userAvatarView?.removeFromSuperview()

      // Create and add new avatar
      let avatarView = UserAvatarView(userInfo: taskCreator, size: ExternalTaskAttachmentView.avatarSize)
      avatarView.translatesAutoresizingMaskIntoConstraints = false
      firstLineStackView.insertArrangedSubview(avatarView, at: 0)
      userAvatarView = avatarView

      // Update task creator label
      taskCreatorLabel.stringValue = taskCreator.user.displayName + " will do"
    } else {
      // No avatar, just update label
      taskCreatorLabel.stringValue = "Unassigned"
    }

    // Title
    titleLabel.stringValue = externalTask.title ?? "Untitled"
  }

  // MARK: - Computed Properties

  private var backgroundColor: NSColor {
    message.outgoing ? .white.withAlphaComponent(0.1) : .labelColor.withAlphaComponent(0.09)
  }

  private var textColor: NSColor {
    message.outgoing ? .white : .labelColor
  }

  private var secondaryTextColor: NSColor {
    message.outgoing ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
  }

  private var task: ExternalTask? {
    fullAttachment.externalTask
  }

  // MARK: - Appearance Updates

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateColors()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    layer?.backgroundColor = backgroundColor.cgColor
    titleLabel.textColor = textColor
    taskCreatorLabel.textColor = secondaryTextColor
  }

  // MARK: - Actions

  @objc private func handleClick() {
    guard let task, let urlString = task.url, let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func handleRightClick() {
    guard let task, let urlString = task.url, let url = URL(string: urlString) else { return }

    let menu = NSMenu()

    let openAction = NSMenuItem(title: "Open URL", action: #selector(openURL), keyEquivalent: "")
    openAction.target = self
    openAction.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
    menu.addItem(openAction)

    let copyAction = NSMenuItem(title: "Copy URL", action: #selector(copyURL), keyEquivalent: "")
    copyAction.target = self
    copyAction.image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: nil)
    menu.addItem(copyAction)

    menu.addItem(NSMenuItem.separator())

    let deleteAction = NSMenuItem(title: "Delete", action: #selector(showDeleteConfirmation), keyEquivalent: "")
    deleteAction.target = self
    deleteAction.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    menu.addItem(deleteAction)

    NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: self)
  }

  @objc private func openURL() {
    guard let task, let urlString = task.url, let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func copyURL() {
    guard let task, let urlString = task.url else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(urlString, forType: .string)
  }

  @objc private func showDeleteConfirmation() {
    let alert = NSAlert()
    alert.messageText = "Delete Task"
    alert.informativeText = "This will delete the task from both Inline and Notion. This action cannot be undone."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      deleteAttachment()
    }
  }

  private func deleteAttachment() {
    guard let externalTask = task else {
      Log.shared.error("Missing external task for deletion")
      return
    }

    Task {
      do {
        try await DataManager.shared.deleteAttachment(
          externalTask: externalTask,
          messageId: message.messageId,
          chatId: message.chatId
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
    let alert = NSAlert()
    alert.messageText = "Delete Failed"
    alert.informativeText = "Failed to delete the task: \(error.localizedDescription)"
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

// MARK: - TaskSquareView

class TaskSquareView: NSView {
  private var isOutgoing: Bool

  static let size: CGFloat = ExternalTaskAttachmentView.avatarSize

  init(isOutgoing: Bool) {
    self.isOutgoing = isOutgoing
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    // Set the fixed size for the checkbox
    widthAnchor.constraint(equalToConstant: Self.size).isActive = true
    heightAnchor.constraint(equalToConstant: Self.size).isActive = true
  }

  public func configure(isOutgoing: Bool) {
    self.isOutgoing = isOutgoing
    setNeedsDisplay(bounds)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Create the rounded rectangle path
    let rect = CGRect(
      x: 1,
      y: 1,
      width: Self.size - 2,
      height: Self.size - 2
    ) // Inset by 1px for stroke
    let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)

    // Set stroke properties
    context.setStrokeColor(strokeColor.cgColor)
    context.setLineWidth(2.0)

    // Convert NSBezierPath to CGPath and draw
    let cgPath = path.cgPath
    context.addPath(cgPath)
    context.strokePath()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    setNeedsDisplay(bounds)
  }

  private var strokeColor: NSColor {
    isOutgoing ? .white : .labelColor
  }
}
