import InlineKit
import InlineProtocol
import UIKit

/// iOS side of message actions: presentation (style, grant), confirmation,
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
    from view: UIView,
    perform: @escaping () -> Void
  ) {
    if let reason = presentation.disabledReason {
      ToastManager.shared.showToast(reason, type: .info, systemImage: "lock")
      return
    }
    guard presentation.intent != .unavailable else { return }
    let confirmations = [presentation.confirmation, presentation.intent.destinationConfirmation()].compactMap { $0 }
    confirm(confirmations[...], destructive: presentation.style == .destructive, from: view, then: perform)
  }

  /// Compose text goes to the composer of `message`'s chat (or the thread it anchors), else
  /// to `peer`'s.
  static func performLocal(_ intent: MessageActionIntent, peer: InlineKit.Peer? = nil, message: InlineKit.Message? = nil) {
    switch intent {
    case let .copyText(text):
      UIPasteboard.general.string = text
      ToastManager.shared.showToast("Copied", type: .success, systemImage: "doc.on.doc")
    case let .openURL(url, _):
      UIApplication.shared.open(url) { opened in
        guard !opened else { return }
        Task { @MainActor in
          ToastManager.shared.showToast("No app can open this link", type: .error, systemImage: "exclamationmark.triangle")
        }
      }
    case let .openLink(peer, _):
      ThreadLinkNavigator.navigate(to: peer)
    case let .compose(text):
      if let message {
        MessageComposeRequests.shared.post(text, from: message)
      } else if let peer {
        MessageComposeRequests.shared.post(text, for: peer)
      }
    case .callback, .unavailable:
      break
    }
  }

  /// A bot's answer to a press made on this device: toast, alert, or a URL to
  /// open in the default browser while the press is still fresh.
  static func presentResponse(_ ui: BotResponseUi, pressedAt: Date, from view: UIView) {
    switch ui {
    case let .toast(text):
      ToastManager.shared.showToast(text, type: .info)
    case let .alert(alert):
      presentAlert(alert, from: view)
    case let .openURL(open):
      openResponseURL(open, pressedAt: pressedAt, from: view)
    }
  }

  /// For answers with no message view to anchor them (Agent Settings): uses the key window.
  static func presentResponse(_ ui: BotResponseUi, pressedAt: Date) {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
    guard let window else {
      if case .toast = ui { presentResponse(ui, pressedAt: pressedAt, from: UIView()) }
      return
    }
    presentResponse(ui, pressedAt: pressedAt, from: window)
  }

  static func openResponseURL(_ open: BotResponseOpenURL, pressedAt: Date, from view: UIView) {
    Task { @MainActor [weak view] in
      let decision = await BotResponseURLResolver.decide(open, pressedAt: pressedAt)
      switch decision {
      case let .open(url):
        openExternally(url)
      case let .confirm(url, confirmation):
        guard let view else { return }
        confirm([confirmation][...], destructive: false, from: view) { openExternally(url) }
      case let .unreachable(alert):
        guard let view else { return }
        presentAlert(alert, from: view)
      case .expired:
        ToastManager.shared.showToast(
          String(localized: "The link took too long to arrive. Try again."),
          type: .info
        )
      }
    }
  }

  private static func openExternally(_ url: URL) {
    UIApplication.shared.open(url) { opened in
      guard !opened else { return }
      Task { @MainActor in
        ToastManager.shared.showToast("No app can open this link", type: .error, systemImage: "exclamationmark.triangle")
      }
    }
  }

  static func presentAlert(_ alert: MessageActionAlertContent, from view: UIView) {
    guard let presenter = presenter(for: view) else { return }
    let controller = UIAlertController(
      title: alert.title ?? alert.text,
      message: alert.title == nil ? nil : alert.text,
      preferredStyle: .alert
    )
    controller.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
    presenter.present(controller, animated: true)
  }

  private static func confirm(
    _ remaining: ArraySlice<MessageActionConfirmation>,
    destructive: Bool,
    from view: UIView,
    then perform: @escaping () -> Void
  ) {
    guard let confirmation = remaining.first else {
      perform()
      return
    }
    guard let presenter = presenter(for: view) else { return }
    let controller = UIAlertController(title: confirmation.title, message: confirmation.text, preferredStyle: .alert)
    let next = remaining.dropFirst()
    controller.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
    controller.addAction(UIAlertAction(
      title: confirmation.confirmTitle,
      style: destructive ? .destructive : .default
    ) { [weak view] _ in
      guard let view else { return }
      confirm(next, destructive: destructive, from: view, then: perform)
    })
    presenter.present(controller, animated: true)
  }

  private static func presenter(for view: UIView) -> UIViewController? {
    var controller = view.window?.rootViewController
    while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
      controller = presented
    }
    return controller
  }

  private static func firstName(userID: Int64) -> String? {
    guard userID > 0, let user = ObjectCache.shared.getCachedUser(id: userID)?.user else { return nil }
    let first = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return first.isEmpty ? user.displayName : first
  }
}
