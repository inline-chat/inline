import AppKit
import Foundation
import InlineKit
import InlineMacUI
import Logger

class ExternalTaskAttachmentView: NSView, AttachmentView {
  let fullAttachment: FullAttachment
  let message: Message
  private let usesOutgoingBubbleStyle: Bool

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

  /// Space between the two lines (the creator over the task).
  private static let lineSpacing: CGFloat = 2

  private lazy var titleLabel = {
    let label = NSTextField()
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.isBordered = false
    label.drawsBackground = false
    label.font = .systemFont(ofSize: 13)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
  }()

  private var userAvatarView: UserAvatarView?

  private lazy var taskSquareView = TaskSquareView(isOutgoing: usesOutgoingBubbleStyle)

  private lazy var taskCreatorLabel = {
    let label = NSTextField()
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.isBordered = false
    label.drawsBackground = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    return label
  }()

  // MARK: - Initialization

  init(fullAttachment: FullAttachment, message: Message, usesOutgoingBubbleStyle: Bool) {
    self.fullAttachment = fullAttachment
    self.message = message
    self.usesOutgoingBubbleStyle = usesOutgoingBubbleStyle

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
    // Placed by frame (`MessageAttachmentsView`, at the plan's height, at least `Theme.externalTaskViewHeight`), and
    // places its parts by frame (`layoutParts`).
    translatesAutoresizingMaskIntoConstraints = true

    // The creator (after the creator's avatar when there is one), then the task square and title.
    addSubview(taskCreatorLabel)
    addSubview(taskSquareView)
    addSubview(titleLabel)

    // Click
    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
    addGestureRecognizer(clickGesture)
    MessageGestureTrace.debug("ExternalTaskAttachmentView.setupGestures added=click")

    // Right click for context menu
    let rightClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleRightClick))
    rightClickGesture.buttonMask = 2 // Right mouse button
    addGestureRecognizer(rightClickGesture)
    MessageGestureTrace.debug("ExternalTaskAttachmentView.setupGestures added=rightClick")
  }

  private func configure() {
    guard let externalTask = fullAttachment.externalTask else {
      return
    }

    taskSquareView.configure(isOutgoing: usesOutgoingBubbleStyle)

    // Configure User Avatar and insert if we have a task creator
    if let taskCreator = fullAttachment.userInfo {
      // Remove existing avatar if any
      userAvatarView?.removeFromSuperview()

      // Create and add new avatar
      let avatarView = UserAvatarView(userInfo: taskCreator, size: ExternalTaskAttachmentView.avatarSize)
      addSubview(avatarView)
      userAvatarView = avatarView

      // Update task creator label
      if externalTask.application == "linear" {
        taskCreatorLabel.stringValue = taskCreator.user.displayName + " created a Linear issue"
      } else {
        taskCreatorLabel.stringValue = taskCreator.user.displayName + " will do"
      }
    } else {
      // No avatar, just update label
      taskCreatorLabel.stringValue = "Unassigned"
    }

    // Title
    titleLabel.stringValue = externalTask.title ?? "Untitled"
    needsLayout = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { needsLayout = true }
  }

  override func layout() {
    super.layout()
    layoutParts()
  }

  /// The stacks' geometry, by frame: from the top leading corner inside the padding, a line with the creator's avatar
  /// and the creator, then a line with the task square and title; items vertically centered on their line, labels
  /// truncated at the trailing padding.
  private func layoutParts() {
    let size = bounds.size
    guard size.width > 0, size.height > 0 else { return }
    let mirrored = userInterfaceLayoutDirection == .rightToLeft
    let maxX = size.width - Self.padding
    func place(_ view: NSView, x: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat) {
      let width = max(0, min(width, maxX - x))
      let alignmentRect = NSRect(
        x: mirrored ? size.width - x - width : x,
        y: size.height - centerY - height / 2,
        width: width,
        height: height
      )
      let frame = backingAlignedRect(view.frame(forAlignmentRect: alignmentRect), options: .alignAllEdgesNearest)
      if view.frame != frame { view.frame = frame }
    }
    func line(_ items: [(NSView, NSSize)], top: CGFloat) -> CGFloat {
      let height = items.map(\.1.height).max() ?? 0
      var x = Self.padding
      for (view, itemSize) in items {
        place(view, x: x, centerY: top + height / 2, width: itemSize.width, height: itemSize.height)
        x += itemSize.width + Self.spacing
      }
      return height
    }
    let avatar = NSSize(width: Self.avatarSize, height: Self.avatarSize)
    let square = NSSize(width: TaskSquareView.size, height: TaskSquareView.size)
    let firstLine = (userAvatarView.map { [($0 as NSView, avatar)] } ?? [])
      + [(taskCreatorLabel as NSView, taskCreatorLabel.intrinsicContentSize)]
    let firstHeight = line(firstLine, top: Self.padding)
    _ = line(
      [(taskSquareView, square), (titleLabel, titleLabel.intrinsicContentSize)],
      top: Self.padding + firstHeight + Self.lineSpacing
    )
  }

  // MARK: - Computed Properties

  private var backgroundColor: NSColor {
    usesOutgoingBubbleStyle ? .white.withAlphaComponent(0.1) : .labelColor.withAlphaComponent(0.09)
  }

  private var textColor: NSColor {
    usesOutgoingBubbleStyle ? .white : .labelColor
  }

  private var secondaryTextColor: NSColor {
    usesOutgoingBubbleStyle ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
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
    guard let task, let urlString = task.url, let url = URL(string: urlString) else {
      MessageGestureTrace.debug("ExternalTaskAttachmentView.handleClick result=noURL")
      return
    }
    MessageGestureTrace.debug("ExternalTaskAttachmentView.handleClick action=openURL url=\(MessageGestureTrace.url(url))")
    NSWorkspace.shared.open(url)
  }

  @objc private func handleRightClick() {
    guard let task, let urlString = task.url, let url = URL(string: urlString) else {
      MessageGestureTrace.debug("ExternalTaskAttachmentView.handleRightClick result=noURL")
      return
    }
    MessageGestureTrace.debug("ExternalTaskAttachmentView.handleRightClick action=showMenu url=\(MessageGestureTrace.url(url))")

    let menu = ContextMenu()

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
    deleteAction.contextMenuStyle = .destructive
    menu.addItem(deleteAction)

    ContextMenu.popUp(menu, with: NSApp.currentEvent!, for: self)
  }

  @objc private func openURL() {
    guard let task, let urlString = task.url, let url = URL(string: urlString) else {
      MessageGestureTrace.debug("ExternalTaskAttachmentView.openURL result=noURL")
      return
    }
    MessageGestureTrace.debug("ExternalTaskAttachmentView.openURL url=\(MessageGestureTrace.url(url))")
    NSWorkspace.shared.open(url)
  }

  @objc private func copyURL() {
    guard let task, let urlString = task.url else {
      MessageGestureTrace.debug("ExternalTaskAttachmentView.copyURL result=noURL")
      return
    }
    MessageGestureTrace.debug("ExternalTaskAttachmentView.copyURL")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(urlString, forType: .string)
  }

  @objc private func showDeleteConfirmation() {
    MessageGestureTrace.debug("ExternalTaskAttachmentView.showDeleteConfirmation")
    let alert = NSAlert()
    alert.messageText = "Delete Task"
    if task?.application == "linear" {
      alert.informativeText = "This will delete the task from both Inline and Linear. This action cannot be undone."
    } else {
      alert.informativeText = "This will delete the task from both Inline and Notion. This action cannot be undone."
    }
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
    // Placed by frame at `size` × `size` (`ExternalTaskAttachmentView.layoutParts`).
    frame.size = NSSize(width: Self.size, height: Self.size)
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
