import AppKit
import Auth
import InlineKit
import RealtimeV2

extension MessageDeletion {
  /// Asks before deleting `count` sent messages for everyone, as a sheet on `window`.
  /// Cancel is the default button, so Return (or a repeated Delete key) never deletes.
  @MainActor
  static func confirm(count: Int, in window: NSWindow?, onConfirm: @escaping @MainActor () -> Void) {
    let copy = confirmation(count: count)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = copy.title
    alert.informativeText = copy.message
    let delete = alert.addButton(withTitle: copy.confirmTitle)
    delete.hasDestructiveAction = true
    delete.keyEquivalent = ""
    alert.addButton(withTitle: copy.cancelTitle).keyEquivalent = "\r"

    guard let window else {
      if alert.runModal() == .alertFirstButtonReturn { onConfirm() }
      return
    }
    guard window.attachedSheet == nil else { return }
    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn else { return }
      onConfirm()
    }
  }

  /// Deletes once the server acknowledges; on failure the messages stay and a toast says why.
  /// Returns whether the deletion succeeded.
  @MainActor
  @discardableResult
  static func deleteShowingErrors(
    messageIds: [Int64],
    peerId: Peer,
    chatId: Int64,
    isGridTranscript: Bool = false,
    expectedAccount: AuthAccountMutationToken? = nil,
    realtime: RealtimeV2 = Api.realtime
  ) async -> Bool {
    do {
      try await delete(
        messageIds: messageIds,
        peerId: peerId,
        chatId: chatId,
        expectedAccount: expectedAccount,
        realtime: realtime
      )
      return true
    } catch is CancellationError {
      return false
    } catch {
      ToastCenter.shared.showError(
        failureMessage(for: error, count: messageIds.count, isGridTranscript: isGridTranscript)
      )
      return false
    }
  }
}
