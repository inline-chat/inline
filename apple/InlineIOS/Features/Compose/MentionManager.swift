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
  // Feature flag: enable auto-picking an exact single mention match on whitespace/punctuation.
  // Toggle to false to disable the behavior without removing the code path.
  static let autoPickExactMatchEnabled = true
  // Feature flag: when editing (backspace) inside a mention, strip the mention styling first.
  static let removeMentionOnEditEnabled = true
  // Feature flag: suppress immediate re-detection after a mention is converted to plain text by a delete.
  static let suppressAfterDeleteEnabled = true

  weak var delegate: MentionManagerDelegate?

  // Dependencies
  private let database: AppDatabase
  private let chatId: Int64
  private let peerId: InlineKit.Peer

  // Mention detection
  private let mentionDetector = MentionDetector()
  private var currentMentionRange: MentionRange?
  private var suppressMentionDetection = false
  // Suppression currently clears only when user-entered text flows through handleIncomingText;
  // programmatic mutations that should re-enable mentions need to call into it or reset the flag explicitly.

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
      chatId: chatId,
      purpose: .mentionCandidates
    )

    // Subscribe to mention candidate updates
    chatParticipantsViewModel?.$mentionCandidates
      .sink { [weak self] candidates in
        Log.shared.trace("🔍 Mention candidates updated: \(candidates.count) candidates")
        guard let self else { return }
        mentionCompletionView?.updateCandidates(candidates)

        if let mentionCompletionView,
           mentionCompletionView.hasItems,
           mentionCompletionView.isVisible == false,
           let textView,
           let currentMentionRange
        {
          showMentionCompletion(for: currentMentionRange.query, textView: textView)
        }
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
    if let candidates = chatParticipantsViewModel?.mentionCandidates {
      completionView.updateCandidates(candidates)
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

  /// Notify the manager about incoming text to decide if suppression should be lifted.
  func handleIncomingText(_ text: String) {
    guard suppressMentionDetection else { return }
    guard !text.isEmpty else { return } // deletions keep suppression
    let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:"))
    let containsNonDelimiter = text.unicodeScalars.contains { !delimiters.contains($0) }
    if containsNonDelimiter {
      suppressMentionDetection = false
    }
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

  /// Attempts to auto-complete a mention when the user types a trailing space/punctuation.
  /// Returns true if the change was handled and should not be applied by the text view.
  func handleAutoPickIfNeeded(
    in textView: UITextView,
    changeRange: NSRange,
    replacementText text: String
  ) -> Bool {
    guard Self.autoPickExactMatchEnabled else { return false }
    guard let mentionCompletionView,
          mentionCompletionView.isVisible,
          let mentionRange = currentMentionRange else { return false }

    // Only react to a single delimiter character (space or limited punctuation) inserted exactly at the end of the mention.
    // Keep to 1 char so entity length math remains correct.
    guard text.count == 1,
          let scalar = text.unicodeScalars.first,
          CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,!?;:")).contains(scalar)
    else { return false }

    let insertionPoint = changeRange.location
    guard insertionPoint == mentionRange.range.location + mentionRange.range.length else { return false }
    guard let user = mentionCompletionView.singleFilteredParticipant() else { return false }
    guard MentionCompletionViewModel.query(mentionRange.query, exactlyMatches: user) else { return false }

    // Build the mention text (uses first name like existing selection path)
    let mentionText = MentionCompletionViewModel.mentionText(for: user)

    // Replace mention and append the typed character as trailing text.
    let currentAttributedText = textView.attributedText ?? NSAttributedString()
    let result = mentionDetector.replaceMention(
      in: currentAttributedText,
      range: mentionRange.range,
      with: mentionText,
      userId: user.user.id,
      trailingText: String(text),
      mentionAttributes: mentionAttributes(for: textView),
      trailingAttributes: baseTextAttributes(for: textView)
    )

    textView.attributedText = result.newAttributedText
    textView.selectedRange = NSRange(location: result.newCursorPosition, length: 0)
    (textView as? ComposeTextView)?.resetTypingAttributesToDefault()
    hideMentionCompletion()
    delegate?.mentionManager(self, didSelectMention: mentionText, userId: user.user.id, for: mentionRange.range)
    return true
  }

  /// When deleting inside a mention, first strip mention styling so the text becomes plain, then apply the delete.
  func handleMentionRemovalOnDelete(
    in textView: UITextView,
    changeRange: NSRange,
    replacementText text: String
  ) -> Bool {
    guard Self.removeMentionOnEditEnabled else { return false }
    // Only care about deletions (backspace or selection delete)
    guard text.isEmpty, changeRange.length > 0 else { return false }

    let attributed = textView.attributedText ?? NSAttributedString()
    guard changeRange.location < attributed.length else { return false }

    var effectiveRange = NSRange(location: 0, length: 0)
    let attributes = attributed.attributes(at: changeRange.location, effectiveRange: &effectiveRange)

    guard attributes[.mentionUserId] != nil else { return false }

    let mutable = attributed.mutableCopy() as! NSMutableAttributedString
    let mentionString = mutable.attributedSubstring(from: effectiveRange).string

    // Replace the whole mention run with plain styling before applying the deletion.
    let plain = NSAttributedString(
      string: mentionString,
      attributes: textView.defaultTypingAttributes
    )
    mutable.replaceCharacters(in: effectiveRange, with: plain)

    // Apply the user's deletion on the now-plain text.
    mutable.replaceCharacters(in: changeRange, with: "")

    if Self.suppressAfterDeleteEnabled {
      suppressMentionDetection = true
      currentMentionRange = nil
      hideMentionCompletion()
    }

    textView.attributedText = mutable.copy() as? NSAttributedString
    textView.selectedRange = NSRange(location: changeRange.location, length: 0)
    return true
  }

  func cleanup() {
    hideMentionCompletion()
    mentionCompletionView?.removeFromSuperview()
    mentionCompletionView = nil
    cancellables.removeAll()
  }

  func dismissCompletion() {
    hideMentionCompletion()
  }

  // MARK: - Mention Detection

  private func detectMentionAtCursor(in textView: UITextView) {
    let cursorPosition = textView.selectedRange.location
    let attributedText = textView.attributedText ?? NSAttributedString()

    Log.shared.debug("🔍 detectMentionAtCursor: cursor=\(cursorPosition), text='\(textView.text ?? "")'")

    if suppressMentionDetection {
      Log.shared.debug("🔍 Mention detection suppressed after delete")
      return
    }

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
    guard mentionCompletionView.hasItems else {
      hideMentionCompletion(clearCurrentRange: false)
      return
    }

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

  private func hideMentionCompletion(clearCurrentRange: Bool = true) {
    Log.shared.debug("🔍 hideMentionCompletion")
    if clearCurrentRange {
      currentMentionRange = nil
    }

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

    // Position using compose view margins and spacing above the input
    let horizontalMargin: CGFloat = 7.0 // ComposeView.textViewHorizantalMargin
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
      userId: userId,
      mentionAttributes: mentionAttributes(for: textView),
      trailingAttributes: baseTextAttributes(for: textView)
    )

    // Update attributed text and cursor position
    textView.attributedText = result.newAttributedText
    textView.selectedRange = NSRange(location: result.newCursorPosition, length: 0)
    (textView as? ComposeTextView)?.resetTypingAttributesToDefault()

    // Hide the menu
    hideMentionCompletion()

    // Notify delegate
    delegate?.mentionManager(self, didSelectMention: mentionText, userId: userId, for: mentionRange.range)
  }

  // MARK: - Utility

  func extractMentionEntities(from attributedText: NSAttributedString) -> [MessageEntity] {
    mentionDetector.extractMentionEntities(from: attributedText)
  }

  private func mentionAttributes(for textView: UITextView) -> [NSAttributedString.Key: Any] {
    var attributes = baseTextAttributes(for: textView)
    attributes[.foregroundColor] = linkColor(for: textView)
    return attributes
  }

  private func baseTextAttributes(for textView: UITextView) -> [NSAttributedString.Key: Any] {
    [
      .font: textView.font ?? UIFont.systemFont(ofSize: 17),
      .foregroundColor: UIColor.label,
    ]
  }

  private func linkColor(for textView: UITextView) -> UIColor {
    (textView as? ComposeTextView)?.composeView?.linkColor
      ?? textView.tintColor
      ?? UIColor.systemBlue
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

extension ComposeView {
  func setupMentionManager() {
    guard let peerId,
          let chatId,
          let window,
          let windowScene = window.windowScene,
          let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
          let rootView = keyWindow.rootViewController?.view
    else {
      return
    }

    mentionManager = MentionManager(database: AppDatabase.shared, chatId: chatId, peerId: peerId)
    mentionManager?.delegate = self
    mentionManager?.attachTo(textView: textView, parentView: rootView)
  }
}
