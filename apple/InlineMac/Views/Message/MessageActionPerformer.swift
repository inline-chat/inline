import AppKit
import InlineKit
import InlineProtocol

/// macOS side of message actions: presentation (style, grant), confirmation,
/// client-side intents and the bot's `alert` response. The message views keep
/// owning callback invocation and loading state.
@MainActor
enum MessageActionPerformer {
  static func presentation(for action: MessageAction, message: InlineKit.Message) -> MessageActionPresentation {
    let botUserID = message.fromId
    let grants = AgentGrantStore.shared
    if action.requiredGrant != .none {
      grants.ensureLoaded(botUserID: botUserID)
    }
    let access = grants.access(botUserID: botUserID)
    return MessageActionPresentation(
      action: action,
      access: access,
      ownerName: access.flatMap { firstName(userID: $0.ownerUserID) },
      botName: firstName(userID: botUserID)
    )
  }

  /// Runs `perform` after the action's confirmation (and, for app links, the
  /// destination) is accepted. Disabled actions explain why instead.
  static func run(
    _ presentation: MessageActionPresentation,
    in window: NSWindow?,
    perform: @escaping () -> Void
  ) {
    if let reason = presentation.disabledReason {
      ToastCenter.shared.showInfo(reason)
      return
    }
    guard presentation.intent != .unavailable else { return }
    let confirmations = [presentation.confirmation, presentation.intent.destinationConfirmation()].compactMap { $0 }
    confirm(confirmations[...], destructive: presentation.style == .destructive, in: window, then: perform)
  }

  /// Client-side intents. Callbacks stay with the caller.
  /// `peer` is the message's chat, where compose text goes.
  static func performLocal(
    _ intent: MessageActionIntent,
    compose: (String) -> Void = { _ in },
    openChat: (InlineKit.Peer) -> Void
  ) {
    switch intent {
    case let .copyText(text):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      ToastCenter.shared.showSuccess("Copied")
    case let .openURL(url, _):
      if !InlineWebLinkOpener.open(url) {
        ToastCenter.shared.showError("No app can open this link")
      }
    case let .openLink(peer, _):
      openChat(peer)
    case let .compose(text):
      compose(text)
    case .callback, .unavailable:
      break
    }
  }

  /// A bot's answer to a press made on this device: toast, alert, or a URL to
  /// open in the default browser while the press is still fresh.
  static func presentResponse(_ ui: BotResponseUi, pressedAt: Date, in window: NSWindow?) {
    switch ui {
    case let .toast(text):
      ToastCenter.shared.showInfo(text)
    case let .alert(alert):
      presentAlert(alert, in: window)
    case let .openURL(open):
      openResponseURL(open, pressedAt: pressedAt, in: window)
    }
  }

  static func openResponseURL(_ open: BotResponseOpenURL, pressedAt: Date, in window: NSWindow?) {
    Task { @MainActor in
      switch await BotResponseURLResolver.decide(open, pressedAt: pressedAt) {
      case let .open(url):
        if !InlineWebLinkOpener.open(url) {
          ToastCenter.shared.showError(String(localized: "No app can open this link"))
        }
      case let .confirm(url, confirmation):
        confirm([confirmation][...], destructive: false, in: window) {
          if !NSWorkspace.shared.open(url) {
            ToastCenter.shared.showError(String(localized: "No app can open this link"))
          }
        }
      case let .unreachable(alert):
        presentAlert(alert, in: window)
      case .expired:
        ToastCenter.shared.showInfo(String(localized: "The link took too long to arrive. Try again."))
      }
    }
  }

  static func presentAlert(_ alert: MessageActionAlertContent, in window: NSWindow?) {
    let panel = NSAlert()
    panel.messageText = alert.title ?? alert.text
    if alert.title != nil { panel.informativeText = alert.text }
    panel.addButton(withTitle: String(localized: "OK"))
    if let window {
      panel.beginSheetModal(for: window)
    } else {
      panel.runModal()
    }
  }

  private static func confirm(
    _ remaining: ArraySlice<MessageActionConfirmation>,
    destructive: Bool,
    in window: NSWindow?,
    then perform: @escaping () -> Void
  ) {
    guard let confirmation = remaining.first else {
      perform()
      return
    }
    let alert = NSAlert()
    alert.messageText = confirmation.title
    if let text = confirmation.text { alert.informativeText = text }
    let confirmButton = alert.addButton(withTitle: confirmation.confirmTitle)
    confirmButton.hasDestructiveAction = destructive
    alert.addButton(withTitle: String(localized: "Cancel"))
    let next = remaining.dropFirst()
    let handle: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .alertFirstButtonReturn else { return }
      confirm(next, destructive: destructive, in: window, then: perform)
    }
    if let window {
      alert.beginSheetModal(for: window, completionHandler: handle)
    } else {
      handle(alert.runModal())
    }
  }

  private static func firstName(userID: Int64) -> String? {
    guard userID > 0, let user = ObjectCache.shared.getCachedUser(id: userID)?.user else { return nil }
    let first = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return first.isEmpty ? user.displayName : first
  }
}
