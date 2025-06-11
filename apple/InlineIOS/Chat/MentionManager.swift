import Combine
import InlineKit
import InlineProtocol
import Logger
import SwiftUI
import UIKit

protocol MentionManagerDelegate: AnyObject {
  func mentionManager(_ manager: MentionManager, didSelectMention text: String, userId: Int64, for range: NSRange)
  func mentionManagerDidDismiss(_ manager: MentionManager)
}

class MentionManager: NSObject {
  weak var delegate: MentionManagerDelegate?

  // Dependencies
  private let database: AppDatabase
  private let chatId: Int64
  private let peerId: InlineKit.Peer

  // Mention detection
  private let mentionDetector = MentionDetector()
  private var currentMentionRange: MentionRange?

  // Completion view
  private var mentionCompletionView: MentionCompletionView?
  private var mentionCompletionConstraints: [NSLayoutConstraint] = []

  // Participants
  private var chatParticipantsViewModel: ChatParticipantsWithMembersViewModel?
  private var cancellables = Set<AnyCancellable>()

  // Text view reference
  private weak var textView: UITextView?
  private weak var parentView: UIView?

  init(database: AppDatabase, chatId: Int64, peerId: InlineKit.Peer) {
    self.database = database
    self.chatId = chatId
    self.peerId = peerId
    super.init()
    setupParticipantsViewModel()
  }

  deinit {
    cleanup()
  }

  // MARK: - Setup

  private func setupParticipantsViewModel() {
    chatParticipantsViewModel = ChatParticipantsWithMembersViewModel(
      db: database,
      chatId: chatId
    )

    // Subscribe to participants updates
    chatParticipantsViewModel?.$participants
      .sink { [weak self] participants in
        Log.shared.trace("🔍 Participants updated: \(participants.count) participants")
        self?.mentionCompletionView?.updateParticipants(participants)
      }
      .store(in: &cancellables)

    // Fetch participants from server
    Task {
      Log.shared.trace("🔍 Fetching chat participants from server...")
      await chatParticipantsViewModel?.refetchParticipants()
    }
  }

  private func setupMentionCompletionView() {
    guard mentionCompletionView == nil else { return }

    let completionView = MentionCompletionView()
    completionView.delegate = self
    completionView.translatesAutoresizingMaskIntoConstraints = false

    mentionCompletionView = completionView

    // Update with current participants
    if let participants = chatParticipantsViewModel?.participants {
      completionView.updateParticipants(participants)
    }
  }

  // MARK: - Public Interface

  func attachTo(textView: UITextView, parentView: UIView) {
    self.textView = textView
    self.parentView = parentView
    setupMentionCompletionView()
  }

  func handleTextChange(in textView: UITextView) {
    detectMentionAtCursor(in: textView)
  }

  func handleKeyPress(_ key: String) -> Bool {
    guard let mentionCompletionView, mentionCompletionView.isVisible else { return false }

    switch key {
      case "ArrowUp":
        mentionCompletionView.selectPrevious()
        return true
      case "ArrowDown":
        mentionCompletionView.selectNext()
        return true
      case "Enter", "Tab":
        return mentionCompletionView.selectCurrentItem()
      case "Escape":
        hideMentionCompletion()
        return true
      default:
        return false
    }
  }

  func cleanup() {
    hideMentionCompletion()
    mentionCompletionView?.removeFromSuperview()
    mentionCompletionView = nil
    cancellables.removeAll()
  }

  // MARK: - Mention Detection

  private func detectMentionAtCursor(in textView: UITextView) {
    let cursorPosition = textView.selectedRange.location
    let attributedText = textView.attributedText ?? NSAttributedString()

    Log.shared.debug("🔍 detectMentionAtCursor: cursor=\(cursorPosition), text='\(textView.text ?? "")'")

    if let mentionRange = mentionDetector.detectMentionAt(cursorPosition: cursorPosition, in: attributedText) {
      currentMentionRange = mentionRange
      Log.shared.debug("🔍 Mention detected: '\(mentionRange.query)' at \(mentionRange.range)")
      showMentionCompletion(for: mentionRange.query, textView: textView)
    } else {
      Log.shared.debug("🔍 No mention detected")
      hideMentionCompletion()
    }
  }

  private func showMentionCompletion(for query: String, textView: UITextView) {
    Log.shared.debug("🔍 showMentionCompletion: query='\(query)'")

    guard let mentionCompletionView,
          let parentView else { return }

    // Filter participants first
    mentionCompletionView.filterParticipants(with: query)

    // Use ChatContainerView's method if available
    if let chatContainer = parentView as? ChatContainerView {
      chatContainer.showMentionCompletion(mentionCompletionView, with: MentionCompletionView.maxHeight)
    } else {
      // Fallback to direct positioning
      if mentionCompletionView.superview == nil {
        parentView.addSubview(mentionCompletionView)
      }
      positionMentionMenu(above: textView)
      mentionCompletionView.show()
    }
  }

  private func hideMentionCompletion() {
    Log.shared.debug("🔍 hideMentionCompletion")
    currentMentionRange = nil

    // Use ChatContainerView's method if available
    if let chatContainer = parentView as? ChatContainerView {
      chatContainer.hideMentionCompletion()
    } else {
      mentionCompletionView?.hide()
    }

    delegate?.mentionManagerDidDismiss(self)
  }

  private func positionMentionMenu(above textView: UITextView) {
    guard let mentionCompletionView,
          let parentView else { return }

    // Remove existing constraints
    NSLayoutConstraint.deactivate(mentionCompletionConstraints)
    mentionCompletionConstraints.removeAll()

    // Position like composeEmbedViewWrapper - same horizontal margins and positioning above compose view
    let horizontalMargin: CGFloat = 7.0 // ComposeView.textViewHorizantalMargin (same as composeEmbedViewWrapper)
    let verticalSpacing: CGFloat = 12.0 // Add spacing above compose view
    mentionCompletionConstraints = [
      mentionCompletionView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor, constant: horizontalMargin),
      mentionCompletionView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor, constant: -horizontalMargin),
      mentionCompletionView.bottomAnchor.constraint(equalTo: textView.topAnchor, constant: -verticalSpacing),
      mentionCompletionView.heightAnchor.constraint(lessThanOrEqualToConstant: MentionCompletionView.maxHeight),
    ]

    NSLayoutConstraint.activate(mentionCompletionConstraints)
  }

  // MARK: - Mention Replacement

  func replaceMention(in textView: UITextView, with mentionText: String, userId: Int64) {
    guard let mentionRange = currentMentionRange else { return }

    let currentAttributedText = textView.attributedText ?? NSAttributedString()
    let result = mentionDetector.replaceMention(
      in: currentAttributedText,
      range: mentionRange.range,
      with: mentionText,
      userId: userId
    )

    // Update attributed text and cursor position
    textView.attributedText = result.newAttributedText
    textView.selectedRange = NSRange(location: result.newCursorPosition, length: 0)

    // Hide the menu
    hideMentionCompletion()

    // Notify delegate
    delegate?.mentionManager(self, didSelectMention: mentionText, userId: userId, for: mentionRange.range)
  }

  // MARK: - Utility

  func extractMentionEntities(from attributedText: NSAttributedString) -> [MessageEntity] {
    mentionDetector.extractMentionEntities(from: attributedText)
  }
}

// MARK: - MentionCompletionDelegate

extension MentionManager: MentionCompletionDelegate {
  func mentionCompletion(
    _ view: MentionCompletionView,
    didSelectUser user: UserInfo,
    withText text: String,
    userId: Int64
  ) {
    guard let textView else { return }
    replaceMention(in: textView, with: text, userId: userId)
  }

  func mentionCompletionDidRequestClose(_ view: MentionCompletionView) {
    hideMentionCompletion()
  }
}
