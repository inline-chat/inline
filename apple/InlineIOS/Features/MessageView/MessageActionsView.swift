import Combine
import InlineKit
import struct InlineProtocol.MessageAction
import struct InlineProtocol.MessageActionRow
import UIKit

/// A bot message's buttons, under its bubble: rows of equal-width buttons with loading state.
/// They sit on the chat background, so they always take the minimal background style, taller and
/// not bold, whichever side the message is on.
final class MessageActionsView: UIView {
  static let rowSpacing: CGFloat = 4

  private let stack = UIStackView()
  private var buttons: [String: MessageActionButton] = [:]
  private var message: Message?
  private var loadingSubscription: AnyCancellable?
  private var answeredSubscription: AnyCancellable?
  private var grantsSubscription: AnyCancellable?

  override init(frame: CGRect) {
    super.init(frame: frame)
    stack.axis = .vertical
    stack.spacing = Self.rowSpacing
    stack.alignment = .fill
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Rows with at least one usable button, as the current view filters them.
  static func rows(for message: Message) -> [MessageActionRow] {
    guard let actions = message.actions else { return [] }
    return actions.rows.compactMap { row in
      let usable = row.actions.filter { action in
        !action.actionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && action.action != nil
      }
      guard !usable.isEmpty else { return nil }
      var cleaned = MessageActionRow()
      cleaned.actions = usable
      return cleaned
    }
  }

  /// Height of `rowCount` rows of buttons.
  @MainActor
  static func height(rowCount: Int, traits: UITraitCollection) -> CGFloat {
    guard rowCount > 0 else { return 0 }
    let button = MessageActionButton(type: .system)
    var action = MessageAction()
    action.actionID = "measure"
    action.text = "Measure"
    button.configure(action: action, outgoing: false)
    button.useMinimalPresentation()
    button.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
    let row = ceil(button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height)
    return CGFloat(rowCount) * row + CGFloat(rowCount - 1) * rowSpacing
  }

  func configure(message: Message) {
    let rows = Self.rows(for: message)
    let sameButtons = self.message?.id == message.id
      && rows.flatMap(\.actions).map(\.actionID) == stack.arrangedSubviews.flatMap { ($0 as? UIStackView)?.arrangedSubviews ?? [] }
      .compactMap { ($0 as? MessageActionButton)?.actionId }
    self.message = message
    if !sameButtons {
      buttons.removeAll()
      stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
      for row in rows {
        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = Self.rowSpacing
        rowStack.alignment = .fill
        rowStack.distribution = .fillEqually
        for action in row.actions {
          let button = MessageActionButton(type: .system)
          button.configure(
            action: action,
            outgoing: false,
            presentation: MessageActionPerformer.presentation(for: action, message: message)
          )
          button.useMinimalPresentation()
          button.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
          rowStack.addArrangedSubview(button)
          buttons[button.actionId] = button
        }
        stack.addArrangedSubview(rowStack)
      }
    }
    subscribe()
    updateLoading()
  }

  private func subscribe() {
    guard loadingSubscription == nil else { return }
    // Grants load once per bot; re-render so buttons the viewer cannot use
    // turn disabled with their reason.
    grantsSubscription = AgentGrantStore.shared.$accessByBotUserID
      .removeDuplicates()
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refreshPresentations() }
    loadingSubscription = MessageActionInteractionState.shared.loadingPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateLoading() }
    answeredSubscription = MessageActionInteractionState.shared.answeredPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] event in
        guard let message = self?.message,
              event.key.peerId == message.peerId,
              event.key.messageId == message.messageId,
              let self
        else { return }
        if let toastText = event.toastText {
          ToastManager.shared.showToast(toastText, type: .info)
        }
        if let alert = event.alert {
          MessageActionPerformer.presentAlert(alert, from: self)
        }
      }
  }

  private func refreshPresentations() {
    guard let message else { return }
    for row in Self.rows(for: message) {
      for action in row.actions {
        buttons[action.actionID]?.configure(
          action: action,
          outgoing: false,
          presentation: MessageActionPerformer.presentation(for: action, message: message)
        )
      }
    }
    updateLoading()
  }

  private func updateLoading() {
    guard let message else { return }
    for (actionId, button) in buttons {
      let key = MessageActionInteractionState.LoadingKey(
        peerId: message.peerId,
        messageId: message.messageId,
        rev: message.rev,
        actionId: actionId
      )
      button.refreshStyle()
      button.setLoading(MessageActionInteractionState.shared.isLoading(key: key))
    }
  }

  @objc private func handleTap(_ sender: MessageActionButton) {
    guard let action = sender.messageAction, let message else { return }
    let presentation = MessageActionPerformer.presentation(for: action, message: message)
    MessageActionPerformer.run(presentation, from: self) { [weak self] in
      if presentation.intent == .callback {
        self?.invokeCallback(action, on: message)
      } else {
        MessageActionPerformer.performLocal(presentation.intent)
      }
    }
  }

  private func invokeCallback(_ action: MessageAction, on message: Message) {
    let actionId = action.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !actionId.isEmpty else { return }
    let key = MessageActionInteractionState.LoadingKey(
      peerId: message.peerId,
      messageId: message.messageId,
      rev: message.rev,
      actionId: actionId
    )
    guard MessageActionInteractionState.shared.begin(key: key) else { return }
    updateLoading()
    Task {
      do {
        let result = try await Api.realtime.send(.invokeMessageAction(
          peerId: message.peerId,
          messageId: message.messageId,
          actionId: actionId
        ))
        guard case let .invokeMessageAction(response) = result else {
          throw MessageActionsError.invalidResponse
        }
        await MainActor.run {
          MessageActionInteractionState.shared.attachInteractionId(response.interactionID, for: key)
        }
      } catch {
        await MainActor.run {
          MessageActionInteractionState.shared.fail(key: key)
          ToastManager.shared.showToast("Action failed", type: .error, systemImage: "exclamationmark.triangle")
        }
      }
    }
  }
}

private enum MessageActionsError: Error {
  case invalidResponse
}
