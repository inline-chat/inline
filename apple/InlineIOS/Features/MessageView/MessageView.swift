import InlineKit
import InlineMessageLayout
import InlineTheme
import InlineUI
import UIKit

/// The next message view. It applies a planned `MessageLayout`: every child gets the frame the
/// planner chose, inside one animation, and the view never measures itself or touches its list.
///
/// Children are retained by node identity, so an edit, reaction or status change updates the
/// same views in place.
final class MessageView: UIView, UIGestureRecognizerDelegate {
  private(set) var content: MessageViewContent?
  private(set) var layout: MessageLayout?

  /// Everything drawn inside the bubble, in a container exactly the bubble's size. The context
  /// menu lifts, hides and restores it as a unit, like the current view's bubble; the name and
  /// avatar stay outside. Children use coordinates relative to it.
  let bubbleContentView = UIView()
  let bubbleView = MessageBubbleNodeView()
  let textView = MessageTextView()
  let nameView = MessageTextView()
  let timeView = MessageTimeView()
  private(set) var reactionViews: [String: MessageReactionPillView] = [:]
  /// Reactions fading out; reused if the same reaction comes back before they finish.
  private var leavingReactionViews: [String: MessageReactionPillView] = [:]
  /// Forward header, reply, media, file or voice, by block id.
  private(set) var blockViews: [String: MessageBlockHostView] = [:]
  private var acknowledgementView: MessageAcknowledgementView?
  private var avatarView: UserAvatarLayerView?
  private lazy var textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextTap(_:)))
  private lazy var bubbleDoubleTap: UITapGestureRecognizer = {
    let gesture = UITapGestureRecognizer(target: self, action: #selector(handleBubbleDoubleTap))
    gesture.numberOfTapsRequired = 2
    return gesture
  }()
  private lazy var linkLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLinkLongPress(_:)))

  var spaceId: Int64?
  var onReactionsMenu: ((FullMessage) -> Void)?
  var onAvatarTap: (() -> Void)?
  var onPhotoTap: ((FullMessage, UIView, UIImage?, URL) -> Void)?
  /// Local state that changes the layout, such as an opened disclosure, changed; the host
  /// replans the row.
  var onContentStateChange: ((FullMessage) -> Void)?
  /// A streaming message revealed into a new line, or finished; the host replans the row with
  /// the short line motion.
  var onRevealLineChange: ((FullMessage) -> Void)?
  /// The line count the pending replan was asked for, so each new line asks once.
  private var requestedRevealLine: Int?
  /// Rich bodies: lists, code, tables and the rest. Created on first use.
  private var richView: MessageRichView?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    addSubview(bubbleContentView)
    addSubview(nameView)
    bubbleContentView.addSubview(bubbleView)
    bubbleContentView.addSubview(textView)
    bubbleContentView.addSubview(timeView)
    for gesture in [textTap, bubbleDoubleTap, linkLongPress] {
      gesture.delegate = self
      addGestureRecognizer(gesture)
    }
    textView.isAccessibilityElement = true
    textView.accessibilityTraits = .staticText
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    layout?.size ?? .zero
  }

  /// Installs `layout`. With an animated `motion`, every node moves on one curve; when the
  /// caller is inside a matching animation block (the list resizing the row), the row moves too.
  func apply(_ content: MessageViewContent, layout: MessageLayout, motion: MessageMotion) {
    let isSameMessage = self.content?.message.id == content.message.id && self.layout != nil
    // A tail change swaps the bubble's mask; animating the frame across it stretches the body into
    // the old tail area. Grouping changes apply in place instead.
    let tailChanged = self.layout.map { $0.bubble.tail != layout.bubble.tail } ?? false
    let motion = isSameMessage && !tailChanged
      ? motion.resolved(reduceMotion: UIAccessibility.isReduceMotionEnabled)
      : .immediate
    let animated = motion != .immediate
    let previousText = self.layout?.text
    self.content = content
    self.layout = layout

    // Content and starting states change without animation; geometry moves below.
    var appearing: [UIView] = []
    var leaving: [(String, MessageReactionPillView)] = []
    UIView.performWithoutAnimation {
      bubbleView.configure(
        side: layout.bubble.tail.physical(isRightToLeft: content.context.isRightToLeft),
        color: content.bubbleColor,
        lighting: content.lighting
      )
      bubbleView.isHidden = !layout.bubble.isVisible
      if animated, let previousText, let text = layout.text, !text.string.hasPrefix(previousText.string) {
        crossfadeText(from: textView.frame)
      }
      textView.setLayout(layout.text ?? .empty)
      // A streaming message keeps drawing at the pacer's count, which runs ahead of the plan
      // within the planned line.
      let pacer = MessageStreamPacer.shared
      if pacer.isStreaming(content.message.id), layout.text != nil {
        pacer.attach(self, to: content.message.id)
        textView.revealedLength = pacer.revealedLength(for: content.message.id) ?? layout.revealedLength
      } else {
        textView.revealedLength = layout.revealedLength
      }
      requestedRevealLine = nil
      textView.accessibilityLabel = content.accessibilityLabel
      if let rich = layout.rich {
        let view = richView ?? makeRichView()
        view.isHidden = false
        view.apply(rich, palette: content.richPalette, photos: content.rich?.photos ?? [:], animated: animated)
        view.accessibilityLabel = content.accessibilityLabel
      } else {
        richView?.isHidden = true
      }
      nameView.setLayout(layout.name ?? .empty)
      nameView.isHidden = layout.name == nil
      timeView.configure(
        time: layout.time,
        status: content.status,
        statusSize: content.statusSize,
        statusColor: content.statusColor,
        pillPadding: layout.timePlacement == .overlay ? content.input.metrics.timeOverlayPadding : nil,
        animated: animated
      )

      let models = Dictionary(content.reactions.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })
      for id in layout.reactionOrder {
        guard let model = models[id], let frame = local(layout.frame(.reaction(id))) else { continue }
        let view: MessageReactionPillView
        if let existing = reactionViews[id] {
          view = existing
        } else if let returning = leavingReactionViews.removeValue(forKey: id) {
          view = returning
          reactionViews[id] = view
        } else {
          view = makeReactionView()
          reactionViews[id] = view
          view.untransformedFrame = frame
          if animated {
            view.alpha = 0
            let scale = MessageReactionPillView.Metrics.popScale
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
          }
          appearing.append(view)
        }
        view.configure(model, animated: animated)
      }
      for (id, view) in reactionViews where layout.frame(.reaction(id)) == nil {
        reactionViews[id] = nil
        leavingReactionViews[id] = view
        leaving.append((id, view))
      }

      // Blocks keep their content views while their kind stays the same.
      let blockIDs = Set(content.blocks.map(\.id))
      for (id, view) in blockViews where !blockIDs.contains(id) {
        view.removeFromSuperview()
        blockViews[id] = nil
      }
      for block in content.blocks {
        // Buttons sit under the bubble, outside its container.
        let isOutside = block.input.position == .belowBubble
        guard let frame = isOutside ? layout.frame(.block(block.id)) : local(layout.frame(.block(block.id))) else { continue }
        let view: MessageBlockHostView
        if let existing = blockViews[block.id], existing.kind == block.kind {
          view = existing
        } else {
          blockViews[block.id]?.removeFromSuperview()
          view = makeBlockView(block.kind, outside: isOutside)
          blockViews[block.id] = view
          view.untransformedFrame = frame
          if animated {
            view.alpha = 0
            appearing.append(view)
          }
        }
        view.configure(block, message: content.message, size: frame.size)
        roundToBubble(view, frame: layout.frame(.block(block.id)), isEdgeToEdge: layout.edgeToEdgeBlocks.contains(block.id))
      }

      if content.showsAcknowledgement {
        let view = acknowledgementView ?? makeAcknowledgementView()
        if acknowledgementView == nil, let frame = local(layout.frame(.acknowledgement)) {
          view.frame = frame
          if animated { view.alpha = 0 }
          appearing.append(view)
        }
        acknowledgementView = view
        view.configure(content.message)
        view.refreshAppearance(activeColor: content.context.theme.primary.uiColor)
      } else {
        acknowledgementView?.isHidden = true
      }

      if let frame = layout.frame(.avatar), let sender = content.message.senderInfo {
        let view: UserAvatarLayerView
        if let avatarView, !avatarView.isHidden {
          view = avatarView
        } else {
          view = avatarView ?? makeAvatarView()
          view.frame = frame
          if animated { view.alpha = 0 }
          appearing.append(view)
        }
        view.configure(with: sender, size: content.input.metrics.avatarSize)
        view.isHidden = false
      } else {
        avatarView?.isHidden = true
      }
    }

    let appearingViews = appearing
    let leavingViews = leaving
    // New pills keep their starting scale on the row's curve and settle with the pop's bounce.
    let poppingPills = animated ? appearing.compactMap { $0 as? MessageReactionPillView } : []
    motion.animate({ [self] in
      bubbleContentView.frame = layout.bubble.frame
      bubbleView.frame = bubbleContentView.bounds
      bubbleView.layoutFill()
      if layout.rich != nil, let richView {
        richView.untransformedFrame = local(layout.frame(.text)) ?? .zero
        richView.layoutNodes()
      } else {
        textView.textFrame = local(layout.frame(.text)) ?? .zero
      }
      textView.alpha = 1
      nameView.textFrame = layout.frame(.name) ?? .zero
      // Nodes with children lay them out inside this block, so their insides move on the same
      // curve instead of snapping at the next layout pass.
      timeView.frame = local(layout.frame(.time)) ?? .zero
      timeView.layoutIfNeeded()
      timeView.alpha = layout.hiddenNodes.contains(.time) ? 0 : 1
      for (id, view) in reactionViews {
        if let frame = local(layout.frame(.reaction(id))) {
          view.untransformedFrame = frame
        }
        view.layoutIfNeeded()
        view.alpha = 1
        if !poppingPills.contains(view) { view.transform = .identity }
      }
      for (id, view) in blockViews {
        let frame = view.superview === self ? layout.frame(.block(id)) : local(layout.frame(.block(id)))
        if let frame {
          view.untransformedFrame = frame
        }
        view.layoutIfNeeded()
      }
      for (_, view) in leavingViews {
        view.alpha = 0
        view.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
      }
      for view in appearingViews {
        view.alpha = 1
      }
      if let acknowledgementView, content.showsAcknowledgement {
        acknowledgementView.frame = local(layout.frame(.acknowledgement)) ?? acknowledgementView.frame
        acknowledgementView.isHidden = false
      }
      if let avatarView, let frame = layout.frame(.avatar) {
        avatarView.frame = frame
      }
    }, completion: { [weak self] _ in
      guard let self else { return }
      for (id, view) in leavingViews where leavingReactionViews[id] === view {
        leavingReactionViews[id] = nil
        view.removeFromSuperview()
      }
      for view in reactionViews.values {
        view.removeFinishedTransitions()
      }
    })
    if animated {
      let pills = Array(reactionViews.values)
      MessageReactionPillView.pop {
        for pill in poppingPills {
          pill.transform = .identity
        }
        for pill in pills {
          pill.popAppearing()
        }
      }
    }
  }

  /// Media drawn to the bubble's edges takes the bubble's corners where it touches them.
  private func roundToBubble(_ view: UIView, frame: CGRect?, isEdgeToEdge: Bool) {
    guard isEdgeToEdge, let frame, let layout else {
      view.layer.cornerRadius = 0
      view.clipsToBounds = false
      return
    }
    let body = layout.bubble.body
    var corners: CACornerMask = []
    if abs(frame.minY - body.minY) < 0.5 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
    if abs(frame.maxY - body.maxY) < 0.5 { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
    view.layer.cornerRadius = layout.bubble.cornerRadius
    view.layer.maskedCorners = corners
    view.clipsToBounds = !corners.isEmpty
  }

  /// A planned row frame in `bubbleContentView`'s coordinates.
  private func local(_ frame: CGRect?) -> CGRect? {
    guard let frame, let origin = layout?.bubble.frame.origin else { return frame }
    return frame.offsetBy(dx: -origin.x, dy: -origin.y)
  }

  /// Positions the continuous bubble gradient for the bubble's place in `viewport`.
  func updateContinuousBubbleGradient(in viewport: UIView) {
    guard content?.lighting != nil, !bubbleView.isHidden else { return }
    let frame = bubbleView.convert(bubbleView.bounds, to: viewport).standardized
    let bounds = viewport.bounds.standardized
    guard frame.height > 0, bounds.height > 0,
          let vector = ThemeCatalog.bubbleGradientVector(
            bubbleMinY: Double(frame.minY),
            bubbleHeight: Double(frame.height),
            viewportMinY: Double(bounds.minY),
            viewportHeight: Double(bounds.height)
          )
    else { return }
    bubbleView.updateLightingVector(startY: CGFloat(vector.startY), endY: CGFloat(vector.endY))
  }

  // MARK: - Streaming

  /// Draws the first `length` characters. Entering a line past the planned ones asks the host
  /// to replan, so the bubble and row grow a line at a time.
  func reveal(_ length: Int) {
    guard let layout, let text = layout.text, let message = content?.message else { return }
    textView.revealedLength = length
    let planned = Self.lineIndex(of: layout.revealedLength ?? text.length, in: text)
    let current = Self.lineIndex(of: length, in: text)
    guard current > planned, requestedRevealLine != current else { return }
    requestedRevealLine = current
    onRevealLineChange?(message)
  }

  /// The stream went idle: draw everything and let the host show the time.
  func finishStreaming() {
    textView.revealedLength = nil
    guard let message = content?.message else { return }
    onRevealLineChange?(message)
  }

  private static func lineIndex(of length: Int, in text: TextLayout) -> Int {
    text.lines.firstIndex { NSMaxRange($0.range) > length } ?? max(0, text.lineCount - 1)
  }

  func performMessageGestureAction(_ action: MessageGestureAction) {
    guard let content, !content.context.isThreadAnchor else { return }
    let message = content.message
    MessageViewActions.perform(action, on: message, onReactionsMenu: onReactionsMenu)
  }

  /// Where a sent message's flight lands, in this view's coordinates: the bubble, the drawn text
  /// with a little padding, and the first baseline.
  func sendAnimationTargetFrames() -> (bubble: CGRect, text: CGRect, textInTextView: CGRect, firstBaseline: CGFloat)? {
    guard let layout, let text = layout.text, text.lineCount > 0, layout.rich == nil else { return nil }
    let glyphs = text.lines.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    let padded = glyphs.insetBy(dx: -1.5, dy: -1.5).integral
    let textRect = textView.convert(textView.viewRect(forTextRect: padded), to: self)
    return (
      // Large emoji have no bubble; their landing area is the emoji itself.
      bubble: layout.bubble.isVisible ? layout.bubble.frame : layout.bubble.frame.union(textRect),
      text: textRect,
      textInTextView: textView.viewRect(forTextRect: padded),
      firstBaseline: textView.convert(CGPoint(x: 0, y: textView.viewRect(forTextRect: .zero).minY + text.firstBaseline), to: self).y
    )
  }

  /// A bitmap of everything inside the bubble, for the send animation's landing.
  func sendAnimationBubbleSnapshot() -> UIView? {
    guard let frames = sendAnimationTargetFrames() else { return nil }
    return bubbleContentView.sendAnimationLayerSnapshotView(
      in: convert(frames.bubble, to: bubbleContentView),
      debugName: "next-target-bubble"
    )
  }

  /// Whether a pan at `point` belongs to a code block or table that scrolls sideways.
  func scrollsHorizontally(at point: CGPoint) -> Bool {
    var view = hitTest(point, with: nil)
    while let current = view, current !== self {
      if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 0.5 { return true }
      view = current.superview
    }
    return false
  }

  /// The text and character under a point in this view's coordinates, in plain or rich bodies.
  private func textHit(at point: CGPoint) -> (NSAttributedString, Int)? {
    if let richView, !richView.isHidden {
      return richView.textHit(at: convert(point, to: richView))
    }
    guard let index = textView.characterIndex(at: convert(point, to: textView)) else { return nil }
    return (textView.layout.text.attributedString, index)
  }

  /// Link under a point in this view's coordinates.
  func linkURL(at point: CGPoint) -> URL? {
    guard let (text, index) = textHit(at: point) else { return nil }
    return MessageViewActions.linkURL(in: text, at: index)
  }

  // MARK: - Interaction

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === textTap {
      guard let (text, index) = textHit(at: gestureRecognizer.location(in: self)) else { return false }
      return MessageViewActions.isInteractive(text, at: index)
    }
    if gestureRecognizer === linkLongPress {
      return linkURL(at: gestureRecognizer.location(in: self)) != nil
    }
    if gestureRecognizer === bubbleDoubleTap {
      guard INUserSettings.current.messageGestures.doubleTapAction != .none,
            let bubble = layout?.bubble.frame
      else { return false }
      return bubble.contains(gestureRecognizer.location(in: self))
    }
    return super.gestureRecognizerShouldBegin(gestureRecognizer)
  }

  /// Reactions, Ack and blocks handle their own taps. The message's gestures would otherwise hold those
  /// touches through the double-tap wait, or take them.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var view = touch.view
    while let current = view, current !== self {
      // Pills, disclosures and copy buttons are controls.
      if current is UIControl || current is MessageAcknowledgementView || current is MessageBlockHostView {
        return false
      }
      view = current.superview
    }
    return true
  }

  @objc private func handleBubbleDoubleTap() {
    performMessageGestureAction(INUserSettings.current.messageGestures.doubleTapAction)
  }

  @objc private func handleLinkLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began, let url = linkURL(at: gesture.location(in: self)) else { return }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    let presenter = presentingViewController
    let sheet = UIAlertController(title: nil, message: url.absoluteString, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "Open", style: .default) { _ in
      InAppBrowser.shared.open(url, from: presenter)
    })
    sheet.addAction(UIAlertAction(title: "Copy Link", style: .default) { _ in
      UIPasteboard.general.string = url.absoluteString
      ToastManager.shared.showToast("Copied link", type: .success, systemImage: "doc.on.doc")
    })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = self
      popover.sourceRect = CGRect(origin: gesture.location(in: self), size: .zero)
    }
    presenter?.present(sheet, animated: true)
  }

  @objc private func handleTextTap(_ gesture: UITapGestureRecognizer) {
    guard let message = content?.message,
          let (text, index) = textHit(at: gesture.location(in: self))
    else { return }
    MessageViewActions.handleTap(
      in: text,
      at: index,
      message: message,
      spaceId: spaceId,
      presenter: presentingViewController
    )
  }

  @objc private func handleAcknowledgementTap() {
    guard let message = content?.message, content?.context.isThreadAnchor == false else { return }
    MessageViewActions.toggleAcknowledgement(on: message)
  }

  @objc private func handleAvatarTap() {
    onAvatarTap?()
  }

  // MARK: - Nodes

  private func makeReactionView() -> MessageReactionPillView {
    let view = MessageReactionPillView()
    view.onTap = { [weak self] emoji in
      guard let message = self?.content?.message else { return }
      MessageViewActions.toggleReaction(emoji, on: message)
    }
    bubbleContentView.addSubview(view)
    return view
  }

  private func makeRichView() -> MessageRichView {
    let view = MessageRichView()
    view.isAccessibilityElement = true
    view.accessibilityTraits = .staticText
    view.onDisclosureToggle = { [weak self] path, isExpanded in
      guard let message = self?.content?.message else { return }
      MessageRichState.shared.set(isExpanded, at: path, for: message.id)
      self?.onContentStateChange?(message)
    }
    bubbleContentView.insertSubview(view, aboveSubview: textView)
    richView = view
    return view
  }

  private func makeBlockView(_ kind: MessageBlock.Kind, outside: Bool) -> MessageBlockHostView {
    let view = MessageBlockHostView(kind: kind)
    view.onPhotoTap = { [weak self] message, sourceView, image, url in
      self?.onPhotoTap?(message, sourceView, image, url)
    }
    if outside {
      addSubview(view)
    } else {
      // Under the text and time, which overlays captionless media.
      bubbleContentView.insertSubview(view, aboveSubview: bubbleView)
    }
    return view
  }

  private func makeAcknowledgementView() -> MessageAcknowledgementView {
    let view = MessageAcknowledgementView()
    view.onToggle = { [weak self] in self?.handleAcknowledgementTap() }
    view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAcknowledgementTap)))
    bubbleContentView.addSubview(view)
    return view
  }

  private func makeAvatarView() -> UserAvatarLayerView {
    let view = UserAvatarLayerView()
    view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAvatarTap)))
    addSubview(view)
    avatarView = view
    return view
  }

  /// Fades the old text out over the new one when an edit replaces it.
  private func crossfadeText(from frame: CGRect) {
    guard let snapshot = textView.snapshotView(afterScreenUpdates: false) else { return }
    snapshot.frame = frame
    bubbleContentView.insertSubview(snapshot, aboveSubview: textView)
    textView.alpha = 0
    UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      snapshot.alpha = 0
    } completion: { _ in
      snapshot.removeFromSuperview()
    }
  }

  private var presentingViewController: UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let controller = next as? UIViewController { return controller }
      responder = next
    }
    return nil
  }
}

private extension TextLayout {
  var string: String { text.string }
}

extension UIView {
  /// The frame the view has with an identity transform. Setting `frame` while a view is scaled
  /// stores the scaled size in its bounds, so nodes that scale in or follow a swipe are placed
  /// through bounds and center instead.
  var untransformedFrame: CGRect {
    get {
      CGRect(
        x: center.x - bounds.width * layer.anchorPoint.x,
        y: center.y - bounds.height * layer.anchorPoint.y,
        width: bounds.width,
        height: bounds.height
      )
    }
    set {
      bounds.size = newValue.size
      center = CGPoint(
        x: newValue.minX + newValue.width * layer.anchorPoint.x,
        y: newValue.minY + newValue.height * layer.anchorPoint.y
      )
    }
  }
}
