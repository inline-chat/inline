import InlineKit
import UIKit

@MainActor
final class SlashCommandManager: NSObject {
  weak var delegate: SlashCommandManagerDelegate?

  private let peerId: InlineKit.Peer
  private let slashCommandDetector = SlashCommandDetector()
  private let peerBotCommandsViewModel: PeerBotCommandsViewModel
  private var currentSlashRange: SlashCommandRange?
  private var currentQuery = ""
  private var completionConstraints: [NSLayoutConstraint] = []

  private var completionView: SlashCommandCompletionView?
  private weak var textView: UITextView?
  private weak var parentView: UIView?

  init(peerId: InlineKit.Peer) {
    self.peerId = peerId
    peerBotCommandsViewModel = PeerBotCommandsViewModel(peer: peerId)
    super.init()
  }

  var isCompletionVisible: Bool {
    completionView?.isVisible == true
  }

  func attachTo(textView: UITextView, parentView: UIView) {
    self.textView = textView
    self.parentView = parentView
    setupCompletionView()
  }

  func handleTextChange(in textView: UITextView) -> Bool {
    detectSlashCommandAtCursor(in: textView)
  }

  func handleKeyPress(_ key: String) -> Bool {
    guard let completionView, completionView.isVisible else { return false }

    switch key {
      case "ArrowUp":
        completionView.selectPrevious()
        return true
      case "ArrowDown":
        completionView.selectNext()
        return true
      case "Enter", "Tab":
        return completionView.selectCurrentItem()
      case "Escape":
        hideCompletion()
        return true
      default:
        return false
    }
  }

  func cleanup() {
    hideCompletion()
    completionView?.removeFromSuperview()
    completionView = nil
  }

  private func setupCompletionView() {
    guard completionView == nil else { return }
    let view = SlashCommandCompletionView()
    view.delegate = self
    completionView = view
  }

  @discardableResult
  private func detectSlashCommandAtCursor(in textView: UITextView) -> Bool {
    let cursorPosition = textView.selectedRange.location
    let attributedText = textView.attributedText ?? NSAttributedString()

    if let slashRange = slashCommandDetector.detectSlashCommandAt(cursorPosition: cursorPosition, in: attributedText) {
      currentSlashRange = slashRange
      showCompletion(for: slashRange.query, textView: textView)
      return true
    }

    hideCompletion()
    return false
  }

  private func showCompletion(for query: String, textView: UITextView) {
    currentQuery = query
    guard let completionView, let parentView else { return }

    let suggestions = peerBotCommandsViewModel.suggestions(matching: query)
    completionView.updateSuggestions(suggestions)

    if completionView.superview == nil {
      parentView.addSubview(completionView)
    }
    positionCompletionView(above: textView)
    if suggestions.isEmpty {
      completionView.hide()
    } else {
      completionView.show()
    }

    if peerBotCommandsViewModel.shouldAttemptLoad {
      Task { @MainActor [weak self] in
        guard let self else { return }
        await self.peerBotCommandsViewModel.ensureLoaded()
        guard self.currentQuery == query, let textView = self.textView else { return }
        self.showCompletion(for: query, textView: textView)
      }
    }
  }

  private func hideCompletion() {
    currentSlashRange = nil
    currentQuery = ""
    completionView?.hide()

    delegate?.slashCommandManagerDidDismiss(self)
  }

  private func positionCompletionView(above textView: UITextView) {
    guard let completionView, let parentView else { return }

    NSLayoutConstraint.deactivate(completionConstraints)
    completionConstraints.removeAll()

    completionConstraints = [
      completionView.leadingAnchor.constraint(equalTo: parentView.leadingAnchor, constant: 7),
      completionView.trailingAnchor.constraint(equalTo: parentView.trailingAnchor, constant: -7),
      completionView.bottomAnchor.constraint(equalTo: textView.topAnchor, constant: -12),
      completionView.heightAnchor.constraint(lessThanOrEqualToConstant: SlashCommandCompletionView.maxHeight),
    ]

    NSLayoutConstraint.activate(completionConstraints)
  }

  private func replaceSlashCommand(in textView: UITextView, with suggestion: PeerBotCommandSuggestion) {
    guard let currentSlashRange else { return }
    let replacedRange = currentSlashRange.range

    let currentAttributedText = textView.attributedText ?? NSAttributedString()
    let commandText = suggestion.insertionText.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = slashCommandDetector.replaceSlashCommand(
      in: currentAttributedText,
      range: currentSlashRange.range,
      with: commandText
    )

    textView.attributedText = result.newAttributedText
    textView.selectedRange = NSRange(location: result.newCursorPosition, length: 0)
    hideCompletion()
    delegate?.slashCommandManager(self, didInsertCommand: suggestion.insertionText, for: replacedRange)
  }
}

extension SlashCommandManager: SlashCommandCompletionDelegate {
  func slashCommandCompletion(_ view: SlashCommandCompletionView, didSelect suggestion: PeerBotCommandSuggestion) {
    guard let textView else { return }
    replaceSlashCommand(in: textView, with: suggestion)
  }

  func slashCommandCompletionDidRequestClose(_ view: SlashCommandCompletionView) {
    hideCompletion()
  }
}

extension ComposeView {
  func setupSlashCommandManager() {
    guard let peerId,
          let window,
          let windowScene = window.windowScene,
          let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
          let rootView = keyWindow.rootViewController?.view
    else {
      return
    }

    slashCommandManager = SlashCommandManager(peerId: peerId)
    slashCommandManager?.delegate = self
    slashCommandManager?.attachTo(textView: textView, parentView: rootView)
  }
}
