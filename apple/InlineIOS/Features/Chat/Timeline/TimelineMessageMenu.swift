import InlineIOSUI
import InlineKit
import TextProcessing
import UIKit

/// The custom message menu on the timeline list: a hold on a bubble shrinks it under the finger,
/// then lifts it into `MessageContextMenuController` with the reaction bar and the actions from
/// `MessageMenuActions`, the same ones the collection view list offers.
///
/// As the collection view does, the list uses UIKit's menu instead (a `UIContextMenuInteraction`
/// with the same actions and reaction bar) when the custom menu is turned off, while VoiceOver runs
/// (`MessageContextMenuRollout.prefersSystemMenuNow`), and after two holds in a row failed to open it.
@MainActor
final class TimelineMessageMenu: NSObject {
  let actions: MessageMenuActions
  private weak var list: TimelineListView<ChatRowID>?
  /// The row a given id shows, from the host's snapshot.
  private let row: (ChatRowID) -> ChatRow?
  private let gesture: MessageContextMenuHoldGesture
  private var press: Press?
  private(set) var controller: MessageContextMenuController?
  private var sourceID: ChatRowID?
  private let feedback = UIImpactFeedbackGenerator(style: .medium)
  /// The menu this chat picked when it opened; `.system` after the custom one kept failing.
  private var implementation = MessageContextMenuRollout.implementation(isPreview: false)
  private var failures = 0
  private var systemInteraction: UIContextMenuInteraction?
  /// The open system menu: its configuration, the row it is for, and the preview taken when it
  /// was asked for (before UIKit hides the bubble).
  private var system: (configuration: UIContextMenuConfiguration, id: ChatRowID, preview: UITargetedPreview?)?
  private var systemPresented = false

  #if DEBUG
  /// The harness's stand-ins for the user's hold action and for VoiceOver, never stored.
  static var debugHoldAction: MessageGestureAction?
  static var debugPrefersSystemMenu = false
  #endif

  /// The hold action the user picked; anything but the menu shows the rows' actions button.
  static var holdAction: MessageGestureAction {
    #if DEBUG
    if let debugHoldAction { return debugHoldAction }
    #endif
    return INUserSettings.current.messageGestures.holdAction
  }

  /// A hold opens UIKit's menu instead of the custom one.
  var usesSystemMenu: Bool {
    #if DEBUG
    if Self.debugPrefersSystemMenu { return true }
    #endif
    return implementation == .system || MessageContextMenuRollout.prefersSystemMenuNow
  }

  /// The menu is about to show; the container notes whether the composer has focus.
  var onWillDisplay: (() -> Void)?
  /// The menu is gone; the container gives the composer its focus back.
  var onDidEnd: (() -> Void)?

  private struct Press {
    let id: ChatRowID
    weak var row: TimelineRowView?
    weak var view: UIView?
    /// A message view's bubble container is placed by frame, so it shrinks through its sublayers;
    /// the older view's bubble takes a transform.
    let shrinksSublayers: Bool
    var scale: CGFloat = 1
  }

  init(list: TimelineListView<ChatRowID>, actions: MessageMenuActions, row: @escaping (ChatRowID) -> ChatRow?) {
    self.list = list
    self.actions = actions
    self.row = row
    gesture = MessageContextMenuHoldGesture(target: nil, action: nil)
    super.init()
    gesture.addTarget(self, action: #selector(handleHold(_:)))
    gesture.acceptsTouch = { [weak self] point in
      guard let self, let list = self.list, controller == nil, !systemPresented, !usesSystemMenu,
            !list.isDecelerating, !list.isTracking, CACurrentMediaTime() - list.lastFlightCatch > 0.15
      else { return false }
      return target(at: point) != nil
    }
    gesture.onPressBegan = { [weak self] point in self?.beginPress(at: point) ?? false }
    gesture.onPressProgress = { [weak self] progress in self?.updatePress(progress: progress) }
    gesture.onPressCancelled = { [weak self] in self?.endPress(animated: true) }
    list.addGestureRecognizer(gesture)
    UIContextMenuInteraction.swizzle_delegate_getAccessoryViewsForConfigurationIfNeeded()
    updateSystemInteraction()
    // VoiceOver can start or stop while the chat is open.
    NotificationCenter.default.addObserver(
      self, selector: #selector(updateSystemInteraction), name: UIAccessibility.voiceOverStatusDidChangeNotification,
      object: nil
    )
  }

  var isActive: Bool { controller != nil || systemPresented }

  /// Whether a row view is the one the open menu lifted out, so it stays hidden when reconfigured.
  func isSource(_ id: ChatRowID) -> Bool { sourceID == id }

  func dismissImmediately() {
    endPress(animated: false)
    gesture.cancelPress()
    controller?.dismiss(animated: false)
    systemInteraction?.dismissMenu()
  }

  func dismiss() {
    controller?.dismiss()
    systemInteraction?.dismissMenu()
  }

  // MARK: - Targeting

  private struct Target {
    let id: ChatRowID
    let message: FullMessage
    let row: TimelineRowView
  }

  /// The message under `point` (in the list's coordinates) when a hold there should open its
  /// menu. Links, inner menus (reaction pills, attachments) keep their own long press.
  private func target(at point: CGPoint) -> Target? {
    guard let list else { return nil }
    for placement in list.layout.visible {
      guard let frame = list.presentedFrame(for: placement.id), frame.contains(point),
            case let .message(message, _)? = row(placement.id)?.content,
            let rowView = list.view(for: placement.id) as? TimelineRowView
      else { continue }
      // The actions button keeps its own touches.
      if rowView.isActionsButton(at: list.convert(point, to: rowView)) { return nil }
      let host: UIView
      if let messageView = rowView.shownMessageView {
        if messageView.linkURL(at: list.convert(point, to: messageView)) != nil { return nil }
        host = messageView
      } else if let legacy = rowView.shownLegacyView {
        if legacy.linkURL(atPointInMessageView: list.convert(point, to: legacy)) != nil { return nil }
        host = legacy
      } else {
        return nil
      }
      var view = host.hitTest(list.convert(point, to: host), with: nil)
      while let current = view, current !== host {
        if current.interactions.contains(where: { $0 is UIContextMenuInteraction }) { return nil }
        view = current.superview
      }
      return Target(id: placement.id, message: message, row: rowView)
    }
    return nil
  }

  /// The hold action the user picked instead of the menu, when there is one.
  private func customHoldAction(for message: FullMessage) -> MessageGestureAction? {
    Self.customHoldAction(for: message)
  }

  /// The hold action the user picked instead of the menu for a message, as `MessageCell` decides it.
  static func customHoldAction(for message: FullMessage) -> MessageGestureAction? {
    let action = holdAction
    guard action != .reactionsMenu, action != .none, message.canReply else { return nil }
    return action
  }

  // MARK: - Press

  private func sourceView(for row: TimelineRowView) -> (view: UIView, shrinksSublayers: Bool)? {
    if let messageView = row.shownMessageView { return (messageView.bubbleContentView, true) }
    guard let legacy = row.shownLegacyView else { return nil }
    let view: UIView = legacy.fullMessage.message.isServiceMessage ? legacy.serviceContainerView : legacy.bubbleView
    return (view, false)
  }

  private func beginPress(at point: CGPoint) -> Bool {
    guard controller == nil, let list, !list.isTracking, let target = target(at: point) else { return false }
    let source = customHoldAction(for: target.message) == nil ? sourceView(for: target.row) : nil
    press = Press(id: target.id, row: target.row, view: source?.view, shrinksSublayers: source?.shrinksSublayers ?? false)
    feedback.prepare()
    return true
  }

  private func updatePress(progress: CGFloat) {
    guard var press, let view = press.view else { return }
    let pressedScale = MessageContextMenuMotion.pressedScale(forWidth: view.bounds.width)
    press.scale = 1 - (1 - pressedScale) * progress
    self.press = press
    setScale(press.scale, on: view, sublayers: press.shrinksSublayers)
  }

  private func setScale(_ scale: CGFloat, on view: UIView, sublayers: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if sublayers {
      view.layer.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
    } else {
      view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
    CATransaction.commit()
  }

  /// Releases the press; an abandoned hold eases the bubble back to full size.
  private func endPress(animated: Bool) {
    guard let press else { return }
    self.press = nil
    guard let view = press.view else { return }
    if press.shrinksSublayers {
      let current = view.layer.presentation()?.sublayerTransform ?? view.layer.sublayerTransform
      view.layer.sublayerTransform = CATransform3DIdentity
      if animated {
        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: current)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer.add(animation, forKey: "contextMenu.press")
      }
    } else if animated {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
        view.transform = .identity
      }
    } else {
      view.transform = .identity
    }
  }

  // MARK: - Hold

  @objc private func handleHold(_ gesture: MessageContextMenuHoldGesture) {
    switch gesture.state {
      case .began: activate(gesture)
      case .changed: controller?.trackHold(at: gesture.location(in: nil))
      case .ended: controller?.endHold(at: gesture.location(in: nil))
      default: break
    }
  }

  private func activate(_ gesture: MessageContextMenuHoldGesture) {
    guard let press, let list, let rowView = list.view(for: press.id) as? TimelineRowView, rowView === press.row,
          case let .message(message, _)? = row(press.id)?.content
    else {
      endPress(animated: true)
      return
    }
    // The hold owns the finger now: the list's drag and the row's own gestures let go.
    cancelGestures(in: rowView)
    for recognizer in list.gestureRecognizers ?? [] where recognizer !== gesture { cancel(recognizer) }
    if let action = customHoldAction(for: message) {
      endPress(animated: false)
      if let messageView = rowView.shownMessageView {
        messageView.performMessageGestureAction(action)
      } else {
        MessageViewActions.perform(action, on: message, onReactionsMenu: { [weak self] in
          self?.actions.showReactionEmojiPicker(for: $0)
        })
      }
      return
    }
    let pressedScale = press.scale
    // The frame and the bitmap are taken at full size.
    endPress(animated: false)
    guard present(id: press.id, message: message, rowView: rowView, pressedScale: pressedScale) else {
      failures += 1
      if failures >= 2 { fallBackToSystemMenu() }
      return
    }
    failures = 0
    controller?.beginHold(at: gesture.location(in: nil))
    feedback.impactOccurred()
  }

  /// The row's actions button: the menu a hold opens on the row's message, without the hold.
  func open(_ id: ChatRowID) {
    guard controller == nil, !systemPresented, let list, let rowView = list.view(for: id) as? TimelineRowView,
          case let .message(message, _)? = row(id)?.content
    else { return }
    endPress(animated: false)
    gesture.cancelPress()
    _ = present(id: id, message: message, rowView: rowView, pressedScale: 1)
  }

  /// UIKit's pull-down menu for the actions button while the list uses the system menu: the
  /// message's actions with a Reactions item, as the collection view's cells offer them.
  func pullDownMenu(_ id: ChatRowID) -> UIMenu {
    guard case let .message(message, _)? = row(id)?.content else { return UIMenu(children: []) }
    if message.message.isServiceMessage { return actions.serviceMenu(for: message.message) }
    return actions.actionsMenu(
      for: message,
      photo: { [weak self] in (self?.list?.view(for: id) as? TimelineRowView)?.shownMessageView?.contextMenuPhotoImage },
      openDocument: { [weak self] in
        (self?.list?.view(for: id) as? TimelineRowView)?.shownMessageView?.openContextMenuDocument()
      },
      includeReactionsAction: true
    )
  }

  /// Hands this chat to UIKit's menu after holds keep failing to open the custom one, so a hold
  /// always opens a menu.
  private func fallBackToSystemMenu() {
    guard implementation == .custom else { return }
    implementation = .system
    updateSystemInteraction()
    MessageContextMenuRollout.didFallBack(reason: "\(failures) holds in a row didn't open (timeline)")
  }

  private func cancel(_ recognizer: UIGestureRecognizer) {
    guard recognizer.isEnabled else { return }
    recognizer.isEnabled = false
    recognizer.isEnabled = true
  }

  private func cancelGestures(in view: UIView) {
    for recognizer in view.gestureRecognizers ?? [] where recognizer !== gesture { cancel(recognizer) }
    for subview in view.subviews { cancelGestures(in: subview) }
  }

  // MARK: - Presenting

  /// The view the preview is drawn from, the bubble's rect in it rounded out to whole pixels, and
  /// the bubble's outline in that rect.
  private func geometry(for rowView: TimelineRowView) -> (view: UIView, rect: CGRect, path: UIBezierPath)? {
    let sourceView: UIView
    let path: UIBezierPath
    if let messageView = rowView.shownMessageView {
      sourceView = messageView.bubbleContentView
      path = messageView.bubbleView.visiblePath()
    } else if let legacy = rowView.shownLegacyView, legacy.fullMessage.message.isServiceMessage {
      sourceView = legacy.serviceContainerView
      path = UIBezierPath(roundedRect: sourceView.bounds, cornerRadius: sourceView.layer.cornerRadius)
    } else if let legacy = rowView.shownLegacyView {
      sourceView = legacy.bubbleView
      path = legacy.bubbleView.visiblePath()
    } else {
      return nil
    }
    // The tail can reach a fraction of a point outside the bubble's bounds.
    let extent = sourceView.bounds.union(path.bounds)
    let scale = sourceView.window?.screen.scale ?? sourceView.traitCollection.displayScale
    let rect = CGRect(
      x: floor(extent.minX * scale) / scale,
      y: floor(extent.minY * scale) / scale,
      width: (ceil(extent.maxX * scale) - floor(extent.minX * scale)) / scale,
      height: (ceil(extent.maxY * scale) - floor(extent.minY * scale)) / scale
    )
    path.apply(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    return (sourceView, rect, path)
  }

  private func snapshot(of view: UIView, in rect: CGRect) -> UIView? {
    let wasHidden = view.isHidden
    view.isHidden = false
    defer { view.isHidden = wasHidden }
    guard let snapshot = view.sendAnimationLayerSnapshotView(in: rect),
          let image = (snapshot as? UIImageView)?.image,
          let sample = image.sendAnimationVisibleAlphaSample(), sample.visible > 0
    else { return nil }
    return snapshot
  }

  private func present(id: ChatRowID, message fullMessage: FullMessage, rowView: TimelineRowView, pressedScale: CGFloat) -> Bool {
    guard let list, let window = list.window else {
      MessageContextMenuRollout.didFailToPresent(reason: "no window")
      return false
    }
    guard let geometry = geometry(for: rowView) else {
      MessageContextMenuRollout.didFailToPresent(reason: "no preview geometry")
      return false
    }
    let messageView = rowView.shownMessageView
    let livePreview = messageView?.makeContextMenuPreview(extent: geometry.rect)
    guard let preview = livePreview ?? snapshot(of: geometry.view, in: geometry.rect) else {
      MessageContextMenuRollout.didFailToPresent(reason: "empty preview timeline")
      return false
    }
    let frame = geometry.view.convert(geometry.rect, to: window)
    let message = fullMessage.message
    let selectableText = messageView?.contextMenuSelectableText(
      extent: geometry.rect,
      colors: .forBubble(outgoing: message.out == true, tint: actions.theme.primary.uiColor)
    )
    let actions = actions

    let controller = MessageContextMenuController(
      source: MessageContextMenuController.Source(
        preview: preview,
        frame: frame,
        pressedScale: pressedScale,
        alignment: frame.midX > window.bounds.midX ? .right : .left,
        selectableText: selectableText,
        currentFrame: { [weak self] in
          guard let self, let list = self.list, let window = list.window,
                let rowView = list.view(for: id) as? TimelineRowView,
                let geometry = self.geometry(for: rowView)
          else { return nil }
          let frame = geometry.view.convert(geometry.rect, to: window)
          return frame.intersects(list.convert(list.bounds, to: window)) ? frame : nil
        },
        setHidden: { [weak self] hidden in
          guard let self else { return }
          sourceID = hidden ? id : nil
          (self.list?.view(for: id) as? TimelineRowView)?.isMenuSourceHidden = hidden
        }
      ),
      content: MessageContextMenuController.Content(
        menu: { [weak rowView] hasTextSelection in
          if message.isServiceMessage { return actions.serviceMenu(for: message) }
          return actions.actionsMenu(
            for: fullMessage,
            photo: { [weak rowView] in rowView?.shownMessageView?.contextMenuPhotoImage },
            openDocument: { [weak rowView] in rowView?.shownMessageView?.openContextMenuDocument() },
            includesTextCopy: !hasTextSelection,
            offersSelectText: selectableText == nil
          )
        },
        accessory: message.isServiceMessage ? nil : actions.reactionPicker(for: fullMessage),
        quoteSelection: message.isServiceMessage || message.status == .sending || message.status == .failed
          ? nil
          : { text in
            ChatState.shared.quote(peer: message.peerId, id: message.messageId, markdown: MessageMarkdown.quoteLines(text))
          }
      )
    )
    controller.onDidDismiss = { [weak self, weak controller] in
      MessageContextMenuRollout.didDismiss()
      guard let self, self.controller === controller else { return }
      self.controller = nil
      onDidEnd?()
    }
    self.controller = controller
    onWillDisplay?()
    // With the keyboard up the menu draws inside the keyboard's window, over the keyboard, and the
    // composer keeps focus, as in Telegram. Without that window it puts the keyboard away, and the
    // container brings it back when the menu closes.
    let keyboardWindow = KeyboardHostWindow.find(covering: window)
    if keyboardWindow == nil { window.endEditing(true) }
    controller.present(from: window, overKeyboardIn: keyboardWindow)
    MessageContextMenuRollout.didPresent(
      overKeyboard: controller.isOverKeyboard,
      livePreview: livePreview != nil,
      selectableText: selectableText != nil
    )
    return true
  }

  // MARK: - Reactions from the open menu

  /// Picks a reaction from the open menu: the menu stays up a moment so the bubble flies back onto
  /// the reacted row instead of the reaction popping in after it lands.
  func react(_ toggle: () -> Void) {
    toggle()
    guard let controller else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak controller] in
      guard let self, let controller, self.controller === controller else { return }
      controller.dismiss()
    }
  }
}

// MARK: - UIKit's menu

extension TimelineMessageMenu: UIContextMenuInteractionDelegate {
  /// The interaction is on the list only while the system menu is in use, so it never competes
  /// with the custom menu's hold.
  @objc private func updateSystemInteraction() {
    guard let list else { return }
    if usesSystemMenu, systemInteraction == nil {
      let interaction = UIContextMenuInteraction(delegate: self)
      list.addInteraction(interaction)
      systemInteraction = interaction
    } else if !usesSystemMenu, let interaction = systemInteraction, !systemPresented {
      list.removeInteraction(interaction)
      systemInteraction = nil
    }
  }

  private static func photo(in rowView: TimelineRowView?) -> UIImage? {
    rowView?.shownMessageView?.contextMenuPhotoImage ?? rowView?.shownLegacyView?.newPhotoView.getCurrentImage()
  }

  private static func openDocument(in rowView: TimelineRowView?) {
    if let messageView = rowView?.shownMessageView {
      messageView.openContextMenuDocument()
    } else {
      rowView?.shownLegacyView?.documentView.openFile()
    }
  }

  func contextMenuInteraction(
    _: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    // A configuration UIKit asked for but never showed (the finger moved off) is let go.
    if let stale = system, !systemPresented {
      (stale.configuration.identifier as? ContextMenuIdentifierUIView)?.removeFromSuperview()
      system = nil
    }
    guard usesSystemMenu, controller == nil, system == nil, let list, !list.isTracking, !list.isDecelerating,
          let target = target(at: location)
    else { return nil }
    if let action = customHoldAction(for: target.message) {
      if let messageView = target.row.shownMessageView {
        messageView.performMessageGestureAction(action)
      } else {
        MessageViewActions.perform(action, on: target.message, onReactionsMenu: { [weak self] in
          self?.actions.showReactionEmojiPicker(for: $0)
        })
      }
      return nil
    }
    let id = target.id
    let fullMessage = target.message
    let message = fullMessage.message
    let menu: UIMenu
    var identifier: ContextMenuIdentifierUIView?
    if message.isServiceMessage {
      menu = actions.serviceMenu(for: message)
    } else {
      menu = actions.actionsMenu(
        for: fullMessage,
        photo: { [weak self] in Self.photo(in: self?.list?.view(for: id) as? TimelineRowView) },
        openDocument: { [weak self] in Self.openDocument(in: self?.list?.view(for: id) as? TimelineRowView) }
      )
      // The reaction bar under the preview, as the collection view's system menu shows it.
      let view = ContextMenuIdentifierUIView(
        accessoryView: actions.reactionPicker(for: fullMessage),
        configuration: ContextMenuAccessoryConfiguration(
          location: .below, trackingAxis: .vertical, attachment: .center,
          alignment: message.out == true ? .trailing : .leading,
          attachmentOffset: -16, alignmentOffset: 0, gravity: 0
        )
      )
      list.addSubview(view)
      identifier = view
    }
    // The bitmap is taken now, before UIKit starts hiding the bubble; a late capture can be empty.
    let preview = bitmapPreview(for: target.row)
    let image = (preview?.view as? UIImageView)?.image
    let visiblePath = preview?.parameters.visiblePath
    let configuration = UIContextMenuConfiguration(identifier: identifier, previewProvider: {
      guard let image, let visiblePath else { return nil }
      let controller = UIViewController()
      controller.view = MessageContextMenuPreviewView(image: image, visiblePath: visiblePath)
      controller.preferredContentSize = image.size
      return controller
    }, actionProvider: { _ in menu })
    system = (configuration, id, preview)
    systemPresented = false
    return configuration
  }

  func contextMenuInteraction(
    _: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier _: any NSCopying
  ) -> UITargetedPreview? {
    guard let system, system.configuration === configuration else { return nil }
    // The press and lift animate the bubble itself while it is on screen.
    return livePreview(for: system.id) ?? system.preview
  }

  func contextMenuInteraction(
    _: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier _: any NSCopying
  ) -> UITargetedPreview? {
    guard let system, system.configuration === configuration else { return nil }
    // The menu returns to the row's bubble where it is now; never to another row.
    setSourceHidden(false, id: system.id)
    return livePreview(for: system.id)
  }

  func contextMenuInteraction(
    _: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator _: (any UIContextMenuInteractionAnimating)?
  ) {
    guard let system, system.configuration === configuration else { return }
    systemPresented = true
    // The menu draws its own preview from here on.
    setSourceHidden(true, id: system.id)
    onWillDisplay?()
  }

  func contextMenuInteraction(
    _: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
    animator: (any UIContextMenuInteractionAnimating)?
  ) {
    (configuration.identifier as? ContextMenuIdentifierUIView)?.removeFromSuperview()
    guard let system, system.configuration === configuration else { return }
    let id = system.id
    let presented = systemPresented
    let finish = { [weak self] in
      guard let self, self.system?.configuration === configuration else { return }
      setSourceHidden(false, id: id)
      self.system = nil
      systemPresented = false
      updateSystemInteraction()
      if presented { onDidEnd?() }
    }
    if let animator {
      animator.addAnimations { [weak self] in self?.setSourceHidden(false, id: id) }
      animator.addCompletion(finish)
    } else {
      finish()
    }
  }

  private func setSourceHidden(_ hidden: Bool, id: ChatRowID) {
    sourceID = hidden ? id : nil
    (list?.view(for: id) as? TimelineRowView)?.isMenuSourceHidden = hidden
  }

  /// The row's bubble itself, shaped by its outline, for the lift and the return.
  private func livePreview(for id: ChatRowID) -> UITargetedPreview? {
    guard let rowView = list?.view(for: id) as? TimelineRowView, let geometry = geometry(for: rowView),
          let window = geometry.view.window else { return nil }
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
    let path = geometry.path
    path.apply(CGAffineTransform(translationX: geometry.rect.minX, y: geometry.rect.minY))
    parameters.visiblePath = path
    parameters.shadowPath = path
    let target = UIPreviewTarget(
      container: window,
      center: geometry.view.convert(CGPoint(x: geometry.view.bounds.midX, y: geometry.view.bounds.midY), to: window)
    )
    return Self.unmasked(UITargetedPreview(view: geometry.view, parameters: parameters, target: target))
  }

  /// A bitmap of the bubble, independent of the row, for when the row is gone or reused.
  private func bitmapPreview(for rowView: TimelineRowView) -> UITargetedPreview? {
    guard let geometry = geometry(for: rowView), let window = geometry.view.window,
          let snapshot = snapshot(of: geometry.view, in: geometry.rect) else { return nil }
    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
    parameters.visiblePath = geometry.path
    parameters.shadowPath = geometry.path
    let target = UIPreviewTarget(
      container: window,
      center: geometry.view.convert(CGPoint(x: geometry.rect.midX, y: geometry.rect.midY), to: window)
    )
    return Self.unmasked(UITargetedPreview(view: snapshot, parameters: parameters, target: target))
  }

  /// The unmasked platter style used for chat bubbles' irregular outlines (UIKit's KVC key).
  private static func unmasked(_ preview: UITargetedPreview) -> UITargetedPreview {
    preview.setValue(true, forKey: "prefersUnmaskedPlatterStyle")
    return preview
  }
}
