#if DEBUG || DEBUG_BUILD
import InlineKit
import InlineMessageLayout
import SwiftUI
import UIKit

/// The custom context menu on real next-view bubbles, with the chat's menu shape and knobs for
/// style, preview, reactions, speed and the keyboard. Hold any bubble.
struct MessageContextMenuLabView: View {
  var body: some View {
    MessageContextMenuLabRepresentable()
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle("Context Menu")
      .navigationBarTitleDisplayMode(.inline)
  }
}

private struct MessageContextMenuLabRepresentable: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> MessageContextMenuLabController {
    MessageContextMenuLabController()
  }

  func updateUIViewController(_ controller: MessageContextMenuLabController, context: Context) {}
}

final class MessageContextMenuLabController: UIViewController, UIContextMenuInteractionDelegate {
  private struct Row {
    var message: FullMessage
    var isFirstInGroup = true
    var isLastInGroup = true
    let view = MessageView()
  }

  private let scrollView = UIScrollView()
  private let toolbar = UIToolbar()
  private let keyboardField = UITextField()
  private let statusLabel = UILabel()
  private var rows: [Row] = []
  private let cache = TextLayoutCache()
  private var laidOutWidth: CGFloat = 0

  private var configuration = MessageContextMenuConfiguration.standard
  private var usesLivePreview = true
  private var showsReactions = true
  private var isSlow = false
  /// Opens UIKit's own menu with the same actions, for side-by-side checks.
  private var usesSystemMenu = false
  private var menu: MessageContextMenuController?
  private var press: (index: Int, scale: CGFloat)?
  private let feedback = UIImpactFeedbackGenerator(style: .medium)
  private weak var holdGesture: MessageContextMenuHoldGesture?

  private lazy var styleItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(toggleStyle))
  private lazy var previewItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(togglePreview))
  private lazy var reactionsItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(toggleReactions))
  private lazy var speedItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(toggleSpeed))
  private lazy var systemItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(toggleSystemMenu))
  private lazy var keyboardItem = UIBarButtonItem(
    image: UIImage(systemName: "keyboard"), style: .plain, target: self, action: #selector(toggleKeyboard)
  )

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    scrollView.alwaysBounceVertical = true
    view.addSubview(scrollView)
    view.addSubview(toolbar)

    statusLabel.font = .preferredFont(forTextStyle: .footnote)
    statusLabel.textColor = .secondaryLabel
    statusLabel.textAlignment = .center
    statusLabel.text = "Hold a message"
    view.addSubview(statusLabel)

    // Off screen; it only brings the keyboard up so the menu's layout above it can be checked.
    keyboardField.frame = CGRect(x: -100, y: -100, width: 10, height: 10)
    view.addSubview(keyboardField)

    toolbar.items = [
      systemItem, .flexibleSpace(), styleItem, .flexibleSpace(), previewItem, .flexibleSpace(),
      reactionsItem, .flexibleSpace(), speedItem, .flexibleSpace(), keyboardItem,
    ]
    updateItems()

    rows = Self.catalog()
    for row in rows {
      row.view.isUserInteractionEnabled = false
      scrollView.addSubview(row.view)
    }

    let hold = MessageContextMenuHoldGesture(target: self, action: #selector(handleHold(_:)))
    hold.acceptsTouch = { [weak self] point in
      guard let self, menu == nil, !usesSystemMenu else { return false }
      return rowIndex(at: point) != nil
    }
    hold.onPressBegan = { [weak self] point in
      guard let self, let index = rowIndex(at: point) else { return false }
      press = (index, 1)
      feedback.prepare()
      return true
    }
    hold.onPressProgress = { [weak self] progress in
      self?.updatePress(progress: progress)
    }
    hold.onPressCancelled = { [weak self] in
      self?.releasePress(animated: true)
    }
    scrollView.addGestureRecognizer(hold)
    holdGesture = hold
    scrollView.addInteraction(UIContextMenuInteraction(delegate: self))
    let traits: [UITrait] = [UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]
    registerForTraitChanges(traits) { (controller: MessageContextMenuLabController, _: UITraitCollection) in
      controller.layoutRows()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let toolbarHeight = toolbar.sizeThatFits(view.bounds.size).height + view.safeAreaInsets.bottom
    toolbar.frame = CGRect(x: 0, y: view.bounds.height - toolbarHeight, width: view.bounds.width, height: toolbarHeight)
    statusLabel.frame = CGRect(x: 16, y: toolbar.frame.minY - 28, width: view.bounds.width - 32, height: 24)
    scrollView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: statusLabel.frame.minY)
    if scrollView.bounds.width != laidOutWidth {
      laidOutWidth = scrollView.bounds.width
      layoutRows()
    }
  }

  private func layoutRows() {
    let width = scrollView.bounds.width
    guard width > 0 else { return }
    let theme = ThemeManager.shared.snapshot(variant: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
    var y: CGFloat = 12
    for row in rows {
      let context = MessageRowContext(
        rowWidth: width,
        isFirstInGroup: row.isFirstInGroup,
        isLastInGroup: row.isLastInGroup,
        showsName: false,
        avatar: .none,
        theme: theme,
        traits: traitCollection
      )
      guard let content = MessageViewContent.make(row.message, context: context, footer: .visible) else { continue }
      let layout = MessageLayoutPlanner.layout(content.input, cache: cache)
      row.view.apply(content, layout: layout, motion: .immediate)
      row.view.frame = CGRect(x: 0, y: y, width: width, height: layout.size.height)
      y += layout.size.height
    }
    scrollView.contentSize = CGSize(width: width, height: y + 12)
  }

  private func rowIndex(at point: CGPoint) -> Int? {
    rows.firstIndex { row in
      row.view.bubbleContentView.bounds.contains(row.view.bubbleContentView.convert(point, from: scrollView))
    }
  }

  // MARK: - Press

  private func updatePress(progress: CGFloat) {
    guard var press else { return }
    let bubble = rows[press.index].view.bubbleContentView
    let pressedScale = MessageContextMenuMotion.pressedScale(forWidth: bubble.bounds.width)
    press.scale = 1 - (1 - pressedScale) * progress
    self.press = press
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bubble.layer.sublayerTransform = CATransform3DMakeScale(press.scale, press.scale, 1)
    CATransaction.commit()
  }

  private func releasePress(animated: Bool) {
    guard let press else { return }
    self.press = nil
    let layer = rows[press.index].view.bubbleContentView.layer
    let current = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
    layer.sublayerTransform = CATransform3DIdentity
    guard animated else { return }
    let animation = CABasicAnimation(keyPath: "sublayerTransform")
    animation.fromValue = NSValue(caTransform3D: current)
    animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    animation.duration = 0.2
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(animation, forKey: "contextMenu.press")
  }

  @objc private func handleHold(_ gesture: MessageContextMenuHoldGesture) {
    switch gesture.state {
    case .began:
      guard let press else { return }
      releasePress(animated: false)
      presentMenu(for: press.index, pressedScale: press.scale)
      menu?.beginHold(at: gesture.location(in: nil))
      feedback.impactOccurred()
    case .changed:
      menu?.trackHold(at: gesture.location(in: nil))
    case .ended:
      menu?.endHold(at: gesture.location(in: nil))
    default:
      break
    }
  }

  // MARK: - Menu

  private func presentMenu(for index: Int, pressedScale: CGFloat) {
    let row = rows[index]
    let messageView = row.view
    guard let window = view.window else { return }
    let bubble = messageView.bubbleContentView
    let extent = messageView.contextMenuBubbleExtent
    let livePreview = usesLivePreview ? messageView.makeContextMenuPreview(extent: extent) : nil
    guard let preview = livePreview ?? bubble.sendAnimationLayerSnapshotView(in: extent) else { return }
    let frame = bubble.convert(extent, to: window)
    let outgoing = row.message.message.out == true
    let tint = ThemeManager.shared.snapshot(variant: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
      .primary.uiColor

    let controller = MessageContextMenuController(
      source: MessageContextMenuController.Source(
        preview: preview,
        frame: frame,
        pressedScale: pressedScale,
        alignment: frame.midX > window.bounds.midX ? .right : .left,
        selectableText: messageView.contextMenuSelectableText(
          extent: extent,
          colors: .forBubble(outgoing: outgoing, tint: tint)
        ),
        currentFrame: { [weak bubble, weak window] in
          guard let bubble, let window else { return nil }
          return bubble.convert(extent, to: window)
        },
        setHidden: { [weak bubble] hidden in
          bubble?.isHidden = hidden
        }
      ),
      content: MessageContextMenuController.Content(
        menu: { [weak self] hasTextSelection in
          self?.makeMenu(for: row.message, includesTextCopy: !hasTextSelection) ?? UIMenu(children: [])
        },
        accessory: showsReactions ? makeReactionBar() : nil,
        copySelection: { [weak self] text in
          UIPasteboard.general.string = text
          self?.show("Copied “\(text)”")
        }
      ),
      configuration: configuration
    )
    // As in the chat: over the keyboard when its window is reachable, else the keyboard goes away
    // while the menu is open and comes back after.
    let keyboardWindow = keyboardField.isFirstResponder ? KeyboardHostWindow.find(covering: window) : nil
    let restoresKeyboard = keyboardField.isFirstResponder && keyboardWindow == nil
    controller.onDidDismiss = { [weak self, weak controller] in
      guard let self, menu === controller else { return }
      menu = nil
      if restoresKeyboard { keyboardField.becomeFirstResponder() }
    }
    menu = controller
    if restoresKeyboard { keyboardField.resignFirstResponder() }
    controller.present(from: window, overKeyboardIn: keyboardWindow)
  }

  // MARK: - System menu

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard usesSystemMenu, let index = rowIndex(at: location) else { return nil }
    let message = rows[index].message
    return UIContextMenuConfiguration(identifier: index as NSNumber, previewProvider: nil) { [weak self] _ in
      self?.makeMenu(for: message, includesTextCopy: true)
    }
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    guard let index = identifier as? Int, rows.indices.contains(index) else { return nil }
    let bubble = rows[index].view.bubbleContentView
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
    return UITargetedPreview(view: bubble, parameters: parameters)
  }

  /// The chat's menu shape with handlers that only report the pick.
  private func makeMenu(for message: FullMessage, includesTextCopy: Bool) -> UIMenu {
    func action(_ title: String, _ image: String, attributes: UIMenuElement.Attributes = []) -> UIAction {
      UIAction(title: title, image: UIImage(systemName: image), attributes: attributes) { [weak self] _ in
        self?.show("Picked \(title)")
      }
    }
    var basic: [UIAction] = []
    if includesTextCopy { basic.append(action("Copy", "square.on.square")) }
    basic += [
      action("Reply", "arrowshape.turn.up.left"),
      action("Reply in Thread", "arrowshape.turn.up.left.circle"),
      action("Forward", "arrowshape.turn.up.right"),
    ]
    if message.message.out == true { basic.append(action("Edit", "bubble.and.pencil")) }
    basic.append(action("Pin", "pin"))
    let integrations = UIMenu(
      title: "Actions",
      image: UIImage(systemName: "ellipsis.circle"),
      children: [action("Will Do", "checkmark.circle"), action("Create Linear Issue", "plus.square.dashed")]
    )
    let attribution = UIAction(title: "Ack by Ava and Sam", image: UIImage(systemName: "person.2"), attributes: .disabled) { _ in }
    return UIMenu(children: [
      UIMenu(options: .displayInline, children: basic),
      integrations,
      UIMenu(options: .displayInline, children: [action("Delete", "trash", attributes: .destructive)]),
      UIMenu(options: .displayInline, children: [attribution]),
    ])
  }

  private func makeReactionBar() -> UIView {
    let height: CGFloat = 52
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    let effect: UIVisualEffectView
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      effect = UIVisualEffectView(effect: glass)
    } else {
      effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    }
    effect.translatesAutoresizingMaskIntoConstraints = false
    effect.layer.cornerRadius = height / 2
    effect.layer.cornerCurve = .continuous
    effect.clipsToBounds = true
    container.addSubview(effect)

    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    effect.contentView.addSubview(stack)
    for emoji in ["👍", "❤️", "😂", "🔥", "🎉", "👀"] {
      var configuration = UIButton.Configuration.plain()
      configuration.title = emoji
      configuration.contentInsets = .zero
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = .systemFont(ofSize: 26)
        return outgoing
      }
      let button = UIButton(configuration: configuration)
      button.addAction(UIAction { [weak self] _ in
        self?.menu?.dismiss { self?.show("Reacted \(emoji)") }
      }, for: .touchUpInside)
      button.widthAnchor.constraint(equalToConstant: 44).isActive = true
      stack.addArrangedSubview(button)
    }
    NSLayoutConstraint.activate([
      container.heightAnchor.constraint(equalToConstant: height),
      effect.topAnchor.constraint(equalTo: container.topAnchor),
      effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: effect.contentView.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: effect.contentView.bottomAnchor, constant: -4),
      stack.leadingAnchor.constraint(equalTo: effect.contentView.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(equalTo: effect.contentView.trailingAnchor, constant: -6),
    ])
    return container
  }

  private func show(_ status: String) {
    statusLabel.text = status
  }

  // MARK: - Knobs

  private func updateItems() {
    systemItem.title = usesSystemMenu ? "System" : "Custom"
    styleItem.title = configuration.style.platter == .glass ? "Glass" : "Material"
    previewItem.title = usesLivePreview ? "Live" : "Bitmap"
    reactionsItem.title = showsReactions ? "Reactions" : "No Reactions"
    speedItem.title = isSlow ? "Slow" : "Normal"
  }

  @objc private func toggleSystemMenu() {
    usesSystemMenu.toggle()
    updateItems()
  }

  @objc private func toggleStyle() {
    configuration.style = configuration.style.platter == .glass ? .material : .glass
    updateItems()
  }

  @objc private func togglePreview() {
    usesLivePreview.toggle()
    updateItems()
  }

  @objc private func toggleReactions() {
    showsReactions.toggle()
    updateItems()
  }

  @objc private func toggleSpeed() {
    isSlow.toggle()
    let factor = isSlow ? 4.0 : 1.0
    let standard = MessageContextMenuMotion.standard
    configuration.motion.pressDelay = standard.pressDelay * factor
    configuration.motion.pressDuration = standard.pressDuration * factor
    configuration.motion.springDuration = standard.springDuration * factor
    configuration.motion.backgroundDuration = standard.backgroundDuration * factor
    configuration.motion.dismissDuration = standard.dismissDuration * factor
    configuration.motion.pageSpringDuration = standard.pageSpringDuration * factor
    // The hold times the press itself, so it needs the slowed motion too.
    holdGesture?.motion = configuration.motion
    updateItems()
  }

  @objc private func toggleKeyboard() {
    if keyboardField.isFirstResponder {
      keyboardField.resignFirstResponder()
    } else {
      keyboardField.becomeFirstResponder()
    }
  }

  #if DEBUG
  /// Opens the custom menu on a catalog row from device tests, as a finished hold would.
  @discardableResult
  func openMenuForTesting(row index: Int) -> MessageContextMenuController? {
    guard rows.indices.contains(index) else { return nil }
    presentMenu(for: index, pressedScale: 1)
    return menu
  }

  var catalogCountForTesting: Int { rows.count }

  func focusKeyboardForTesting() -> Bool {
    keyboardField.becomeFirstResponder()
  }

  var isKeyboardFocusedForTesting: Bool { keyboardField.isFirstResponder }

  /// Stretches every timing by `factor`, so screenshots catch transitions mid-flight.
  func slowDownForTesting(by factor: Double) {
    let standard = MessageContextMenuMotion.standard
    configuration.motion.springDuration = standard.springDuration * factor
    configuration.motion.backgroundDuration = standard.backgroundDuration * factor
    configuration.motion.dismissDuration = standard.dismissDuration * factor
    configuration.motion.pageSpringDuration = standard.pageSpringDuration * factor
  }
  #endif

  // MARK: - Catalog

  private static let date = Date(timeIntervalSince1970: 1_787_816_400)
  private static let chatID: Int64 = 9_201
  private static let ava = User(id: 7_201, email: "ava@example.com", firstName: "Ava", lastName: "Lin")
  private static let me = User(id: 7_203, email: "mo@example.com", firstName: "Mo")

  private static func catalog() -> [Row] {
    let essay = (1 ... 14).map { index in
      "Paragraph \(index): a long agent answer keeps going so the bubble is taller than the screen, "
        + "and the menu has to scroll with it the way Telegram does."
    }.joined(separator: "\n\n")
    return [
      Row(message: message(1, "Near the top: the menu should push this down to make room for reactions.", from: ava)),
      Row(message: message(2, "Short", from: me, out: true)),
      Row(message: message(3, "Hold, then slide onto an action and lift to pick it.", from: ava)),
      Row(message: message(4, essay, from: ava)),
      Row(message: message(5, "سلام! این پیام فارسی است و باید از راست به چپ نمایش داده شود.", from: ava)),
      Row(message: message(6, "Long-press a word in the preview to select it, then drag the handles.", from: me, out: true)),
      Row(message: message(7, "😀", from: me, out: true)),
      Row(message: message(8, "Near the bottom: this moves up so its menu fits.", from: ava)),
    ]
  }

  private static func message(_ id: Int64, _ text: String, from user: User, out: Bool = false) -> FullMessage {
    var message = Message(
      messageId: id,
      fromId: user.id,
      date: date.addingTimeInterval(Double(id) * 60),
      text: text,
      peerUserId: nil,
      peerThreadId: chatID,
      chatId: chatID,
      out: out,
      status: out ? .sent : nil,
      entities: nil
    )
    message.globalId = 920_000 + id
    return FullMessage(
      senderInfo: UserInfo(user: user),
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }
}
#endif
