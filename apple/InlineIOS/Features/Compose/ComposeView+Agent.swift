import Combine
import InlineKit
import SwiftUI
import UIKit

/// The agent card.
///
/// While the draft would reach an Agent in Detailed mode, Compose becomes a
/// card: the plus moves inside, the text spans the card, and a row under it
/// shows the Agent, its folder before the first turn, model, reasoning,
/// context and a stop or resume circle. Chats with people, Friendly mode and
/// hidden controls keep the bar. The shared `ComposeAgentChainModel` decides
/// all of it, as on the Mac.
extension ComposeView {
  /// Height the agent row adds under the text.
  static let agentRowExtraHeight: CGFloat = 34
  static let agentRowHeight: CGFloat = 32

  var showsOutsidePlusButton: Bool {
    !isVoiceActive && !isAgentLayout
  }

  var agentLayoutIsWanted: Bool {
    agentRowState.isAvailable && !isVoiceActive
  }

  func makeAgentRowHostingController() -> UIHostingController<ComposeAgentRowHost> {
    let controller = UIHostingController(rootView: ComposeAgentRowHost(
      state: agentRowState,
      onAttach: { [weak self] in self?.plusTapped() },
      onUsage: { [weak self] frame in self?.presentAgentUsage(from: frame) }
    ))
    controller.safeAreaRegions = []
    controller.sizingOptions = []
    let view = controller.view!
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    view.isHidden = true
    view.alpha = 0
    return controller
  }

  // MARK: Model

  func configureAgentChain() {
    guard let peerId else {
      tearDownAgentChain()
      return
    }
    if let agentChain, agentChain.peer == peerId, agentChain.chatID == chatId { return }
    tearDownAgentChain()

    let chatID = chatId
    let peerUser = peerId.asUserId().flatMap { ObjectCache.shared.getCachedUser(id: $0)?.user }
    let model = ComposeAgentChainModel(
      peer: peerId,
      chatID: chatID,
      peerUser: peerUser,
      database: AppDatabase.shared,
      updateAgentContext: { context in
        guard let chatID else { return }
        _ = try await Api.realtime.send(.updateChatInfo(
          chatID: chatID,
          title: nil,
          emoji: nil,
          agentContext: context
        ))
      }
    )
    agentChain = model
    agentRowState.model = model
    model.$isAvailable
      .removeDuplicates()
      .sink { [weak self] available in
        // Applied in place so an agent DM or thread opens as a card on its
        // first frame. Only the delivered value is read: the publisher
        // fires before the model stores it.
        guard let self else { return }
        agentRowState.isAvailable = available
        applyAgentLayout(agentLayoutIsWanted, animated: window != nil)
      }
      .store(in: &agentCancellables)
    model.start()
    updateAgentDraftTarget()
    updateAgentReplyTarget()
  }

  func tearDownAgentChain() {
    agentCancellables.removeAll()
    agentChain?.stop()
    agentChain = nil
    agentRowState.model = nil
    agentRowState.isAvailable = false
    applyAgentLayout(false, animated: false)
  }

  /// Leading mentions decide the addressee; only the start of the draft is read.
  func updateAgentDraftTarget() {
    guard let agentChain else { return }
    agentChain.updateDraft(textView.attributedText ?? NSAttributedString())
  }

  func updateAgentReplyTarget() {
    guard let agentChain, let peerId else { return }
    let replyID = ChatState.shared.getState(peer: peerId).replyingMessageId
    let fromID = replyID.flatMap { messageID in
      try? FullMessage.get(messageId: messageID, chatId: chatId ?? 0)?.message.fromId
    }
    agentChain.updateReply(toUserID: fromID)
  }

  // MARK: Layout

  func applyAgentLayout(_ shown: Bool, animated: Bool) {
    guard shown != isAgentLayout else { return }
    isAgentLayout = shown

    layoutIfNeeded()
    if shown {
      textViewBottomToContentConstraint?.isActive = false
      textViewTrailingToSendConstraint?.isActive = false
      textViewBottomToAgentRowConstraint?.isActive = true
      textViewTrailingToContentConstraint?.isActive = true
      agentRowView.isHidden = false
    } else {
      textViewBottomToAgentRowConstraint?.isActive = false
      textViewTrailingToContentConstraint?.isActive = false
      textViewBottomToContentConstraint?.isActive = true
      textViewTrailingToSendConstraint?.isActive = true
    }

    updateComposeWidth(showsSideButton: showsOutsidePlusButton, animated: animated)
    // Measure the text at its new width before sizing the card.
    layoutIfNeeded()
    updateHeight(animated: animated)

    let finish = { [weak self] in
      guard let self else { return }
      agentRowView.isHidden = !isAgentLayout
    }
    guard animated else {
      agentRowView.alpha = shown ? 1 : 0
      finish()
      return
    }
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
    ) {
      self.agentRowView.alpha = shown ? 1 : 0
    } completion: { _ in
      finish()
    }
  }

  // MARK: Usage

  /// The ring's popover: 5-hour and weekly limits, then this thread's context.
  func presentAgentUsage(from globalFrame: CGRect) {
    guard let agentChain, let presenter = attachmentPickerPresenter() else { return }
    agentChain.prepareUsage()
    let controller = UIHostingController(rootView: ComposeAgentUsageView(model: agentChain))
    controller.modalPresentationStyle = .popover
    controller.preferredContentSize = CGSize(width: 300, height: 200)
    controller.sizingOptions = .preferredContentSize
    if let popover = controller.popoverPresentationController {
      popover.sourceView = agentRowView
      popover.sourceRect = agentRowView.convert(globalFrame, from: nil)
      popover.permittedArrowDirections = [.down]
      popover.delegate = agentPopoverDelegate
    }
    presenter.present(controller, animated: true)
  }
}

/// Keeps the usage popover a popover on iPhone instead of a sheet.
final class ComposeAgentPopoverDelegate: NSObject, UIPopoverPresentationControllerDelegate {
  func adaptivePresentationStyle(
    for controller: UIPresentationController,
    traitCollection: UITraitCollection
  ) -> UIModalPresentationStyle {
    .none
  }
}
