import AppKit
import Auth
import InlineKit
import InlineUI

/// Keeps both list implementations, the composer, and modal actions in one selection session.
@MainActor
final class MessageSelectionCoordinator {
  private weak var list: (any ChatMessageListController)?
  private weak var compose: ComposeAppKit?
  private let dependencies: AppDependencies
  private var eventMonitor: Any?
  private var removeKeyInterceptor: (() -> Void)?
  private var drag: DragSelection?
  private var autoscrollTimer: Timer?
  private var isDeleting = false
  private weak var previousFirstResponder: NSView?
  private var isShowingSelection = false
  private var keyboardSelectionRow: Int?
  private lazy var bar = ForwardMessageSelectionBar(
    surfaceStyle: compose?.surfaceStyle ?? .content,
    onForward: { [weak self] in self?.forward() },
    onDelete: { [weak self] in self?.confirmDelete() },
    onCancel: { [weak self] in self?.list?.clearMessageSelection() }
  )

  init(list: any ChatMessageListController, compose: ComposeAppKit, host: NSView, dependencies: AppDependencies) {
    self.list = list
    self.compose = compose
    self.dependencies = dependencies
    bar.isHidden = true
    bar.wantsLayer = true
    host.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: compose.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: compose.trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    list.onMessageSelectionChange = { [weak self] _ in self?.refresh() }
  }

  /// A click-and-drag across rows; like Telegram, it selects or deselects every row it passes,
  /// matching what the press did to the first row.
  private struct DragSelection {
    let anchorStableId: Int64
    let selects: Bool
    let baseline: Set<Int64>
  }

  static func beginSelection(from source: NSView) {
    var ancestor: NSView? = source
    while let current = ancestor {
      if let table = current as? NSTableView, let list = table.delegate as? any ChatMessageListController {
        list.beginMessageSelection(atRow: table.row(for: source))
        return
      }
      ancestor = current.superview
    }
  }

  private func refresh() {
    guard let list, let compose else { return }
    let active = list.isMessageSelectionActive
    if active, !isShowingSelection, !compose.prepareForMessageSelection() {
      list.clearMessageSelection()
      return
    }
    if active != isShowingSelection {
      isShowingSelection = active
      if active {
        previousFirstResponder = compose.window?.firstResponder as? NSView
        compose.window?.makeFirstResponder(list.messageSelectionTableView)
        installMonitor()
      } else {
        keyboardSelectionRow = nil
        endDrag()
        removeMonitor()
      }
      // The bar rises into the composer's place while the composer fades, and the reverse on exit.
      let selecting = { [weak self] in self?.isShowingSelection == true }
      let rise: CGFloat = bar.superview?.isFlipped == true ? 14 : -14
      SelectionMotion.fade(bar, in: active, slideY: rise, duration: 0.22) { !selecting() }
      SelectionMotion.fade(compose, in: !active, duration: 0.18) { selecting() }
      list.messageSelectionInset = active ? ForwardMessageSelectionBar.height : nil
      list.updateInsetForCompose(active ? ForwardMessageSelectionBar.height : compose.frame.height, animate: false)
      if !active, let previousFirstResponder,
         previousFirstResponder.window === compose.window, !previousFirstResponder.isHiddenOrHasHiddenAncestor {
        compose.window?.makeFirstResponder(previousFirstResponder)
      }
    }
    bar.update(count: list.selectedMessagesInLoadedOrder.count, isDeleting: isDeleting)
  }

  private func forward() {
    guard !isDeleting, let list,
          !list.selectedMessagesInLoadedOrder.isEmpty else { return }
    dependencies.forwardMessages?.present(
      messages: list.selectedMessagesInLoadedOrder,
      reviewBeforeSending: true,
      onComplete: { [weak list] in list?.clearMessageSelection() }
    )
  }

  private func confirmDelete() {
    guard !isDeleting, let list,
          let window = bar.window, window.attachedSheet == nil else { return }
    // Freeze the exact set the user is about to confirm; live history updates may continue.
    let messages = list.selectedMessagesInLoadedOrder
    guard let source = messages.first else { return }
    let account: AuthAccountMutationToken
    do { account = try Auth.shared.handle.beginAccountMutation() } catch {
      ToastCenter.shared.showError(error.localizedDescription)
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = messages.count == 1 ? "Delete this message?" : "Delete \(messages.count) messages?"
    alert.informativeText = "These messages will be deleted for everyone in this chat. This cannot be undone."
    let delete = alert.addButton(withTitle: "Delete for Everyone")
    delete.hasDestructiveAction = true
    delete.keyEquivalent = ""
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      self.isDeleting = true
      self.refresh()
      Task { @MainActor [weak self, dependencies = self.dependencies] in
        do {
          // Keep messages and selection visible until the server confirms permission and deletion.
          try await dependencies.realtimeV2.send(DeleteMessageTransaction(
            messageIds: messages.map(\.message.messageId),
            peerId: source.peerId,
            chatId: source.chatId,
            deferLocalDeletion: true
          ), expectedAccount: account)
          self?.list?.clearMessageSelection()
        } catch {
          ToastCenter.shared.showError("Could not confirm deletion. \(error.localizedDescription)")
        }
        self?.isDeleting = false
        self?.refresh()
      }
    }
  }

  private func installMonitor() {
    guard eventMonitor == nil else { return }
    removeKeyInterceptor = dependencies.keyMonitor?.addEventInterceptor(key: "message_selection_\(UUID())") { [weak self] event in
      guard let self else { return false }
      return self.handle(event) == nil
    }
    var mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp]
    if removeKeyInterceptor == nil { mask.insert(.keyDown) }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      guard let self else { return event }
      return self.handle(event)
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let list, list.isMessageSelectionActive, let window = list.view.window,
          event.window === window, window.attachedSheet == nil,
          !list.view.isHiddenOrHasHiddenAncestor else { return event }
    let table = list.messageSelectionTableView
    // A drag owns the mouse until release, even outside the list, so it can autoscroll.
    if drag != nil, event.type == .leftMouseDragged || event.type == .leftMouseUp {
      if event.type == .leftMouseUp { endDrag() } else { continueDrag(at: event.locationInWindow) }
      return nil
    }
    if event.type == .leftMouseDragged || event.type == .leftMouseUp { return event }
    if event.type != .keyDown {
      guard let scrollView = table.enclosingScrollView,
            scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)),
            let hit = scrollView.hitTest(scrollView.superview?.convert(event.locationInWindow, from: nil)
              ?? event.locationInWindow),
            hit === table || hit.isDescendant(of: table) else { return event }
      guard event.type == .leftMouseDown, !isDeleting else { return nil }
      let row = table.row(at: table.convert(event.locationInWindow, from: nil))
      keyboardSelectionRow = row
      if event.modifierFlags.contains(.shift) {
        list.extendMessageSelection(toRow: row)
      } else if list.toggleMessageSelection(atRow: row), list.isMessageSelectionActive,
                let stableId = list.messageSelectionStableId(atRow: row)
      {
        drag = DragSelection(
          anchorStableId: stableId,
          selects: list.isMessageSelected(atRow: row),
          baseline: list.selectedMessageStableIds
        )
      }
      if list.isMessageSelectionActive { window.makeFirstResponder(table) }
      return nil
    }
    guard let responder = window.firstResponder as? NSView,
          responder === table || responder.isDescendant(of: table) || responder.isDescendant(of: bar)
    else { return event }
    guard !isDeleting else { return nil }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if event.keyCode == 53 { list.clearMessageSelection(); return nil }
    if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
      list.selectAllMessages()
      return nil
    }
    if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
      copySelection()
      return nil
    }
    if modifiers.isEmpty {
      if event.keyCode == 36 || event.keyCode == 76 { forward(); return nil }
      if event.keyCode == 51 || event.keyCode == 117 { confirmDelete(); return nil }
    }
    if modifiers.isEmpty || modifiers == .shift, event.keyCode == 125 || event.keyCode == 126 {
      let rows = (0 ..< table.numberOfRows).filter { list.canSelectMessage(atRow: $0) }
      let selected = rows.filter { list.isMessageSelected(atRow: $0) }
      let down = event.keyCode == 125
      if let edge = keyboardSelectionRow ?? (down ? selected.last : selected.first), let index = rows.firstIndex(of: edge) {
        let next = rows[min(max(index + (down ? 1 : -1), 0), rows.count - 1)]
        keyboardSelectionRow = next
        if modifiers == .shift { list.extendMessageSelection(toRow: next) } else { list.beginMessageSelection(atRow: next) }
        table.scrollRowToVisible(next)
      }
      return nil
    }
    return event
  }

  // MARK: Drag selection

  private func continueDrag(at windowPoint: NSPoint) {
    guard let drag, let list, list.isMessageSelectionActive else { return endDrag() }
    let table = list.messageSelectionTableView
    guard table.numberOfRows > 0,
          let anchorRow = list.messageSelectionRow(forStableId: drag.anchorStableId) else { return }
    let point = table.convert(windowPoint, from: nil)
    var row = table.row(at: NSPoint(x: table.bounds.midX, y: point.y))
    if row < 0 {
      // Past either end of the content: clamp to the nearest row. A gap between rows changes nothing.
      guard point.y < table.bounds.minY || point.y > table.bounds.maxY else { return }
      row = (point.y < table.bounds.minY) == table.isFlipped ? 0 : table.numberOfRows - 1
    }
    let range = Set((min(anchorRow, row) ... max(anchorRow, row)).compactMap { list.messageSelectionStableId(atRow: $0) })
    list.setSelectedMessageStableIds(drag.selects ? drag.baseline.union(range) : drag.baseline.subtracting(range))
    keyboardSelectionRow = row
    updateAutoscroll(windowPoint: windowPoint)
  }

  /// Keeps scrolling while the pointer rests past the top or bottom edge, extending the drag.
  private func updateAutoscroll(windowPoint: NSPoint) {
    guard drag != nil, let scrollView = list?.messageSelectionTableView.enclosingScrollView else { return }
    let visible = scrollView.convert(scrollView.bounds, to: nil)
    let outside = windowPoint.y < visible.minY + 8 || windowPoint.y > visible.maxY - 8
    guard outside else {
      autoscrollTimer?.invalidate()
      autoscrollTimer = nil
      return
    }
    guard autoscrollTimer == nil else { return }
    autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.autoscrollTick() }
    }
  }

  private func autoscrollTick() {
    guard drag != nil, let list, let window = list.view.window,
          let scrollView = list.messageSelectionTableView.enclosingScrollView else { return endDrag() }
    let point = window.mouseLocationOutsideOfEventStream
    let visible = scrollView.convert(scrollView.bounds, to: nil)
    let edge: CGFloat = 8
    let distance = point.y < visible.minY + edge ? point.y - (visible.minY + edge)
      : point.y > visible.maxY - edge ? point.y - (visible.maxY - edge) : 0
    guard distance != 0 else {
      autoscrollTimer?.invalidate()
      autoscrollTimer = nil
      return
    }
    // Faster the further past the edge, like Telegram and Finder.
    let step = min(max(abs(distance) * 0.6, 6), 40) * (distance > 0 ? 1 : -1)
    let clip = scrollView.contentView
    var proposed = clip.bounds
    proposed.origin.y += clip.isFlipped ? -step : step
    // The clip view knows the list's content insets; let it clamp to the scrollable range.
    let origin = clip.constrainBoundsRect(proposed).origin
    guard origin.y != clip.bounds.origin.y else { return }
    clip.scroll(to: origin)
    scrollView.reflectScrolledClipView(clip)
    continueDrag(at: point)
  }

  private func endDrag() {
    drag = nil
    autoscrollTimer?.invalidate()
    autoscrollTimer = nil
  }

  // MARK: Copy

  /// Copies the selected messages as plain text in chat order, naming the sender whenever it changes.
  private func copySelection() {
    guard let list else { return }
    let messages = list.selectedMessagesInLoadedOrder
    let showsSenders = Set(messages.map(\.message.fromId)).count > 1
    var blocks: [String] = []
    var lastSender: Int64?
    for message in messages {
      guard let text = message.displayText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
      if showsSenders, message.message.fromId != lastSender {
        blocks.append("\(message.from?.displayName ?? "Unknown"):\n\(text)")
      } else {
        blocks.append(text)
      }
      lastSender = message.message.fromId
    }
    guard !blocks.isEmpty else {
      NSSound.beep()
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(blocks.joined(separator: "\n\n"), forType: .string)
    ToastCenter.shared.showSuccess(blocks.count == 1 ? "Copied message" : "Copied \(blocks.count) messages")
  }

  private func removeMonitor() {
    removeKeyInterceptor?()
    removeKeyInterceptor = nil
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
  }

  func dispose() {
    endDrag()
    removeMonitor()
    list?.onMessageSelectionChange = nil
    bar.removeFromSuperview()
  }
}
