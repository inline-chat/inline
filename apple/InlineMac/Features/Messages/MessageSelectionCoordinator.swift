import AppKit
import Auth
import Combine
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
  private var defaultsObserver: AnyCancellable?
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
    host.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: compose.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: compose.trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    list.onMessageSelectionChange = { [weak self] _ in self?.refresh() }
    defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        if !ExperimentalFeatureFlags.macMessageSelectionEnabled { self?.list?.clearMessageSelection() }
      }
  }

  static func beginSelection(from source: NSView) {
    guard ExperimentalFeatureFlags.macMessageSelectionEnabled else { return }
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
        removeMonitor()
      }
      compose.isHidden = active
      bar.isHidden = !active
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
    guard !isDeleting, ExperimentalFeatureFlags.macMessageSelectionEnabled, let list,
          !list.selectedMessagesInLoadedOrder.isEmpty else { return }
    dependencies.forwardMessages?.present(
      messages: list.selectedMessagesInLoadedOrder,
      reviewBeforeSending: true,
      onComplete: { [weak list] in list?.clearMessageSelection() }
    )
  }

  private func confirmDelete() {
    guard !isDeleting, ExperimentalFeatureFlags.macMessageSelectionEnabled, let list,
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
    var mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .rightMouseUp]
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
    if event.type != .keyDown {
      guard let scrollView = table.enclosingScrollView,
            scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)),
            let hit = scrollView.hitTest(scrollView.superview?.convert(event.locationInWindow, from: nil)
              ?? event.locationInWindow),
            hit === table || hit.isDescendant(of: table) else { return event }
      guard event.type == .leftMouseDown, !isDeleting else { return nil }
      let row = table.row(at: table.convert(event.locationInWindow, from: nil))
      keyboardSelectionRow = row
      if event.modifierFlags.contains(.shift) { list.extendMessageSelection(toRow: row) } else { list.toggleMessageSelection(atRow: row) }
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

  private func removeMonitor() {
    removeKeyInterceptor?()
    removeKeyInterceptor = nil
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
  }

  func dispose() {
    removeMonitor()
    defaultsObserver = nil
    list?.onMessageSelectionChange = nil
    bar.removeFromSuperview()
  }
}
