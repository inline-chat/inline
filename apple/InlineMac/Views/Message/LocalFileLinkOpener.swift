import AppKit
import Auth
import InlineKit
import TextProcessing
import UniformTypeIdentifiers

/// Senders the current account always allows to open local file links.
@MainActor
enum LocalFileLinkTrust {
  struct Sender: Identifiable, Equatable {
    let id: Int64
    let name: String
  }

  private static var key: String? {
    Auth.shared.getCurrentUserId().map { "localFileLinkTrustedSenders.\($0)" }
  }

  private static var stored: [String: String] {
    key.flatMap { UserDefaults.standard.dictionary(forKey: $0) as? [String: String] } ?? [:]
  }

  static var senders: [Sender] {
    stored.compactMap { id, name in Int64(id).map { Sender(id: $0, name: name) } }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  static func contains(_ id: Int64) -> Bool {
    stored[String(id)] != nil
  }

  static func allow(id: Int64, name: String) {
    guard let key else { return }
    var senders = stored
    senders[String(id)] = name
    UserDefaults.standard.set(senders, forKey: key)
  }

  static func remove(id: Int64) {
    guard let key else { return }
    var senders = stored
    senders[String(id)] = nil
    UserDefaults.standard.set(senders, forKey: key)
  }
}

/// Opens local file links. Your own messages, your own agents and senders you've
/// allowed open directly; anyone else gets a confirmation first.
@MainActor
enum LocalFileLinkOpener {
  private static var ownedBots: (accountId: Int64, ids: Set<Int64>)?

  static func open(_ link: LocalFileLink, from sender: User?) async {
    guard let disposition = link.disposition() else {
      showUnavailable(link)
      return
    }
    if await isTrusted(sender) {
      perform(disposition, on: link)
    } else {
      confirm(disposition, on: link, from: sender)
    }
  }

  private static func isTrusted(_ sender: User?) async -> Bool {
    guard let sender else { return false }
    if sender.id == Auth.shared.getCurrentUserId() || LocalFileLinkTrust.contains(sender.id) { return true }
    guard sender.bot == true else { return false }
    return await isOwnedBot(sender.id)
  }

  private static func isOwnedBot(_ id: Int64) async -> Bool {
    guard let accountId = Auth.shared.getCurrentUserId() else { return false }
    if let ownedBots, ownedBots.accountId == accountId, ownedBots.ids.contains(id) { return true }
    guard let ids = await fetchOwnedBotIDs() else { return false }
    ownedBots = (accountId, ids)
    return ids.contains(id)
  }

  /// Gives up after two seconds, since a request made offline can wait in the queue. The sender then gets a confirmation.
  private static func fetchOwnedBotIDs() async -> Set<Int64>? {
    await withCheckedContinuation { continuation in
      let result = OwnedBotsResult(continuation)
      Task { @MainActor in
        let response = try? await Api.realtime.send(.listBots())
        if case let .listBots(bots)? = response {
          result.finish(Set(bots.bots.map(\.id)))
        } else {
          result.finish(nil)
        }
      }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        result.finish(nil)
      }
    }
  }

  private static func perform(_ disposition: LocalFileLink.Disposition, on link: LocalFileLink) {
    let url = link.fileURL
    switch disposition {
      case .openInEditor:
        let workspace = NSWorkspace.shared
        guard let editor = workspace.urlForApplication(toOpen: UTType.sourceCode)
          ?? workspace.urlForApplication(toOpen: UTType.plainText)
        else {
          workspace.activateFileViewerSelecting([url])
          return
        }
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
      case .openInViewer:
        NSWorkspace.shared.open(url)
      case .revealInFinder:
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  private static func confirm(
    _ disposition: LocalFileLink.Disposition,
    on link: LocalFileLink,
    from sender: User?
  ) {
    let name = sender?.displayName ?? "someone"
    let canOpen = disposition != .revealInFinder

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = canOpen ? "Open a file from \(name)?" : "Show a file from \(name) in Finder?"
    alert.informativeText = "\(link.path)\n\nThis link points to a file on your Mac. Continue only if you expected it."
    if canOpen {
      alert.addButton(withTitle: "Open")
    }
    alert.addButton(withTitle: "Show in Finder")
    alert.addButton(withTitle: "Cancel")
    if sender != nil {
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Always allow file links from \(name)"
    }

    let response = alert.runModal()
    let action: LocalFileLink.Disposition
    switch (response, canOpen) {
      case (.alertFirstButtonReturn, true): action = disposition
      case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true): action = .revealInFinder
      default: return
    }
    if let sender, alert.suppressionButton?.state == .on {
      LocalFileLinkTrust.allow(id: sender.id, name: name)
    }
    perform(action, on: link)
  }

  private static func showUnavailable(_ link: LocalFileLink) {
    let alert = NSAlert()
    alert.messageText = "Inline can't access this file"
    alert.informativeText = "\(link.path)\n\nIt may be on another computer, or it may have been moved or deleted."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

@MainActor
private final class OwnedBotsResult {
  private var continuation: CheckedContinuation<Set<Int64>?, Never>?

  init(_ continuation: CheckedContinuation<Set<Int64>?, Never>) {
    self.continuation = continuation
  }

  func finish(_ ids: Set<Int64>?) {
    continuation?.resume(returning: ids)
    continuation = nil
  }
}
