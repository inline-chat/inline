import Combine
import GRDB
import InlineKit
import SwiftUI
import UIKit

extension Notification.Name {
  /// An agent DM's folder as Compose knows it, including a choice made in
  /// Compose before the first turn. `userInfo`: "peer" and "title".
  static let composeAgentFolderDidChange = Notification.Name("composeAgentFolderDidChange")
}

/// The agent card.
///
/// While the draft would reach an Agent in Detailed mode, Compose becomes a
/// card: the plus moves inside, the text spans the card, and a row under it
/// shows the Agent, its folder before the first turn, model, reasoning,
/// context and a stop or resume circle. Chats with people, Friendly mode and
/// hidden controls keep the bar, with a stop circle beside it while a turn
/// runs. The shared `ComposeAgentChainModel` decides all of it, as on the Mac.
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

  /// Inside the card the row has its own circle.
  var showsAgentRunCircle: Bool {
    agentRunWork != nil && !isAgentLayout && !isVoiceActive
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
    // One model per peer: the chat ID arrives separately and is not needed,
    // since only Agent threads write a preset and their peer carries the ID.
    if let agentChain, agentChain.peer == peerId { return }
    tearDownAgentChain()

    let threadID = peerId.asThreadId()
    let model = ComposeAgentChainModel(
      peer: peerId,
      chatID: chatId,
      peerUser: peerId.asUserId().flatMap(Self.localUser(id:)),
      database: AppDatabase.shared,
      updateAgentContext: { context in
        guard let threadID else { return }
        _ = try await Api.realtime.send(.updateChatInfo(
          chatID: threadID,
          title: nil,
          emoji: nil,
          agentContext: context
        ))
      }
    )
    agentChain = model
    agentRowState.model = model
    // Both publishers fire before the model stores the new value, so only
    // the delivered value is read. Applied in place so an agent DM or thread
    // opens as a card on its first frame.
    model.$isAvailable
      .removeDuplicates()
      .sink { [weak self] available in
        guard let self else { return }
        agentRowState.isAvailable = available
        applyAgentLayout(agentLayoutIsWanted, animated: window != nil)
      }
      .store(in: &agentCancellables)
    model.$runWork
      .removeDuplicates()
      .sink { [weak self] work in
        guard let self else { return }
        agentRunWork = work
        updateAgentRunCircle(animated: window != nil)
      }
      .store(in: &agentCancellables)
    model.objectWillChange
      .sink { [weak self] in
        Task { @MainActor [weak self] in self?.agentModelDidChange() }
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
    agentRunWork = nil
    agentFolderTitle = nil
    applyAgentLayout(false, animated: false)
    updateAgentRunCircle(animated: false)
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

  /// The memory cache first, then the local database, so a DM whose user is
  /// not warmed yet still resolves its Agent on the first frame.
  private static func localUser(id: Int64) -> User? {
    if let cached = ObjectCache.shared.getCachedUser(id: id)?.user { return cached }
    return try? AppDatabase.shared.reader.read { db in try User.fetchOne(db, id: id) }
  }

  /// Settings, grants and controlling state changed: refresh what reads them
  /// outside SwiftUI.
  private func agentModelDidChange() {
    updateAgentRunCircle(animated: window != nil)
    publishAgentFolder()
  }

  /// The header shows an agent DM's folder; Compose knows a choice made here
  /// before the header's own settings copy does.
  private func publishAgentFolder() {
    guard let agentChain, let peerId,
          agentChain.target?.reason == .directMessage,
          let title = agentChain.projectTitle,
          title != agentFolderTitle
    else { return }
    agentFolderTitle = title
    NotificationCenter.default.post(
      name: .composeAgentFolderDidChange,
      object: nil,
      userInfo: ["peer": peerId, "title": title]
    )
  }

  // MARK: Layout

  func applyAgentLayout(_ shown: Bool, animated: Bool) {
    guard shown != isAgentLayout else { return }
    isAgentLayout = shown

    // The side circles first; each flushes layout before its own change.
    updateComposeWidth(showsSideButton: showsOutsidePlusButton, animated: animated)
    updateAgentRunCircle(animated: animated)

    // Then the text, the row and the card height in one pass, so the text
    // never squeezes against a row the card has not grown for yet.
    if shown { agentRowView.isHidden = false }
    let change = {
      if shown {
        self.textViewBottomToContentConstraint?.isActive = false
        self.textViewTrailingToSendConstraint?.isActive = false
        self.textViewBottomToAgentRowConstraint?.isActive = true
        self.textViewTrailingToContentConstraint?.isActive = true
      } else {
        self.textViewBottomToAgentRowConstraint?.isActive = false
        self.textViewTrailingToContentConstraint?.isActive = false
        self.textViewBottomToContentConstraint?.isActive = true
        self.textViewTrailingToSendConstraint?.isActive = true
      }
      self.agentRowView.alpha = shown ? 1 : 0
      // Measure the text at its new width before sizing the card.
      self.layoutIfNeeded()
      self.updateHeight(animated: animated)
    }
    let finish = { [weak self] in
      guard let self else { return }
      agentRowView.isHidden = !isAgentLayout
    }
    guard animated else {
      change()
      finish()
      return
    }
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
      animations: change
    ) { _ in
      finish()
    }
  }

  /// The glass stop or resume circle beside the bar, mirroring the plus.
  func updateAgentRunCircle(animated: Bool) {
    let shown = showsAgentRunCircle
    var isEnabled = false
    if let work = agentRunWork, let agentChain {
      let paused = work.runState == .paused
      let name = agentChain.runWorkName(work)
      agentRunButton.setSymbol(
        paused ? "play.fill" : "stop.fill",
        pointSize: 13,
        accessibilityLabel: paused ? "Resume \(name)" : "Stop \(name)"
      )
      isEnabled = agentChain.controlDisabledReason(work) == nil
        && !agentChain.isControlling
        && work.runState != .stopping
    }
    let visibleAlpha: CGFloat = isEnabled ? 1 : 0.45
    agentRunButton.isUserInteractionEnabled = shown && isEnabled

    let isShowing = composeTrailingToRunConstraint?.isActive == true
    guard shown != isShowing else {
      if shown { agentRunButton.alpha = visibleAlpha }
      return
    }

    layoutIfNeeded()
    if shown {
      agentRunButton.isHidden = false
      agentRunButton.alpha = 0
      composeTrailingToEdgeConstraint?.isActive = false
      composeTrailingToRunConstraint?.isActive = true
    } else {
      composeTrailingToRunConstraint?.isActive = false
      composeTrailingToEdgeConstraint?.isActive = true
    }

    let finish = { [weak self] in
      guard let self else { return }
      agentRunButton.isHidden = composeTrailingToRunConstraint?.isActive != true
    }
    guard animated else {
      agentRunButton.alpha = shown ? visibleAlpha : 0
      layoutIfNeeded()
      finish()
      return
    }
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
    ) {
      self.agentRunButton.alpha = shown ? visibleAlpha : 0
      self.layoutIfNeeded()
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
