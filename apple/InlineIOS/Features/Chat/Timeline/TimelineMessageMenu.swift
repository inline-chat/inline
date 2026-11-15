import InlineIOSUI
import InlineKit
import TextProcessing
import UIKit

/// The custom message menu on the timeline list: a hold on a bubble shrinks it under the finger,
/// then lifts it into `MessageContextMenuController` with the reaction bar and the actions from
/// `MessageMenuActions`, the same ones the collection view list offers.
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
      guard let self, let list = self.list, controller == nil, !list.isDecelerating, !list.isTracking,
            CACurrentMediaTime() - list.lastFlightCatch > 0.15
      else { return false }
      return target(at: point) != nil
    }
    gesture.onPressBegan = { [weak self] point in self?.beginPress(at: point) ?? false }
    gesture.onPressProgress = { [weak self] progress in self?.updatePress(progress: progress) }
    gesture.onPressCancelled = { [weak self] in self?.endPress(animated: true) }
    list.addGestureRecognizer(gesture)
  }

  var isActive: Bool { controller != nil }

  /// Whether a row view is the one the open menu lifted out, so it stays hidden when reconfigured.
  func isSource(_ id: ChatRowID) -> Bool { sourceID == id }

  func dismissImmediately() {
    endPress(animated: false)
    gesture.cancelPress()
    controller?.dismiss(animated: false)
  }

  func dismiss() {
    controller?.dismiss()
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
    let action = INUserSettings.current.messageGestures.holdAction
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
    guard present(id: press.id, message: message, rowView: rowView, pressedScale: pressedScale) else { return }
    controller?.beginHold(at: gesture.location(in: nil))
    feedback.impactOccurred()
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
