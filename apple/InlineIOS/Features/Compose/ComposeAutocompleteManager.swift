import Combine
import InlineKit
import UIKit

@MainActor
protocol ComposeAutocompleteManagerDelegate: AnyObject {
  func composeAutocompleteManager(
    _ manager: ComposeAutocompleteManager,
    didInsert item: ComposeAutocompleteItem,
    for range: NSRange
  )
  func composeAutocompleteManagerDidDismiss(_ manager: ComposeAutocompleteManager)
}

@MainActor
final class ComposeAutocompleteManager: NSObject {
  weak var delegate: ComposeAutocompleteManagerDelegate?

  private let threadLinkDetector = ThreadLinkDetector()
  private let viewModel: ComposeAutocompleteViewModel
  private var completionConstraints: [NSLayoutConstraint] = []
  private var cancellables = Set<AnyCancellable>()

  private var completionView: ComposeAutocompleteCompletionView?
  private weak var textView: UITextView?
  private weak var parentView: UIView?

  init(database: AppDatabase, spaceId: Int64?) {
    viewModel = ComposeAutocompleteViewModel(
      db: database,
      spaceId: spaceId,
      recentThreadChatIds: { limit in
        Self.recentThreadChatIds(limit: limit)
      }
    )
    super.init()
    bindViewModel()
  }

  var isCompletionVisible: Bool {
    completionView?.isVisible == true
  }

  func configure(spaceId: Int64?) {
    viewModel.configure(spaceId: spaceId)
  }

  func attachTo(textView: UITextView, parentView: UIView) {
    self.textView = textView
    self.parentView = parentView
    setupCompletionView()
  }

  func handleTextChange(in textView: UITextView) -> Bool {
    detectThreadLinkAtCursor(in: textView)
  }

  func handleKeyPress(_ key: String) -> Bool {
    guard let completionView, completionView.isVisible else { return false }

    switch key {
      case "ArrowUp":
        viewModel.selectPrevious()
        return true
      case "ArrowDown":
        viewModel.selectNext()
        return true
      case "Enter", "Tab":
        return completionView.selectCurrentItem()
      case "Escape":
        dismissCompletion(suppressCurrentMatch: true)
        return true
      default:
        return false
    }
  }

  func dismissCompletion(suppressCurrentMatch: Bool = false) {
    viewModel.hide(suppressCurrentMatch: suppressCurrentMatch)
    completionView?.hide()
    delegate?.composeAutocompleteManagerDidDismiss(self)
  }

  func cleanup() {
    dismissCompletion()
    NSLayoutConstraint.deactivate(completionConstraints)
    completionConstraints.removeAll()
    completionView?.removeFromSuperview()
    completionView = nil
    cancellables.removeAll()
  }

  private func bindViewModel() {
    Publishers.CombineLatest3(
      viewModel.$items,
      viewModel.$selectedIndex,
      viewModel.$match
    )
    .sink { [weak self] items, selectedIndex, match in
      self?.renderCompletion(items: items, selectedIndex: selectedIndex, match: match)
    }
    .store(in: &cancellables)
  }

  private func setupCompletionView() {
    guard completionView == nil else { return }
    let view = ComposeAutocompleteCompletionView()
    view.delegate = self
    completionView = view
  }

  private static func recentThreadChatIds(limit: Int) -> [Int64] {
    var ids: [Int64] = []
    var seen = Set<Int64>()

    func append(_ destination: Navigation.Destination?) {
      guard let destination,
            ids.count < limit,
            case let .chat(peer) = destination,
            let chatId = peer.asThreadId(),
            seen.insert(chatId).inserted
      else {
        return
      }
      ids.append(chatId)
    }

    append(Navigation.shared.activeDestination)
    for destination in Navigation.shared.pathComponents.reversed() {
      append(destination)
    }

    return ids
  }

  @discardableResult
  private func detectThreadLinkAtCursor(in textView: UITextView) -> Bool {
    let cursorPosition = textView.selectedRange.location
    let attributedText = textView.attributedText ?? NSAttributedString()

    if let threadRange = threadLinkDetector.detectThreadLinkAt(cursorPosition: cursorPosition, in: attributedText) {
      viewModel.update(
        match: ComposeAutocompleteMatch(
          kind: .thread,
          range: threadRange.range,
          query: threadRange.query
        )
      )
      return true
    }

    dismissCompletion()
    return false
  }

  private func renderCompletion(
    items: [ComposeAutocompleteItem],
    selectedIndex: Int,
    match: ComposeAutocompleteMatch?
  ) {
    guard let completionView else { return }
    guard match != nil, !items.isEmpty else {
      completionView.hide()
      return
    }

    guard let parentView, let textView else { return }

    completionView.update(items: items, selectedIndex: selectedIndex)

    if completionView.superview == nil {
      parentView.addSubview(completionView)
    }

    positionCompletionView(above: textView)
    completionView.show()
  }

  private func positionCompletionView(above textView: UITextView) {
    guard let completionView else { return }

    NSLayoutConstraint.deactivate(completionConstraints)
    completionConstraints.removeAll()

    completionConstraints = [
      completionView.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
      completionView.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
      completionView.bottomAnchor.constraint(equalTo: textView.topAnchor, constant: -12),
      completionView.heightAnchor.constraint(lessThanOrEqualToConstant: ComposeAutocompleteCompletionView.maxHeight),
    ]

    NSLayoutConstraint.activate(completionConstraints)
  }

  private func replaceAutocomplete(in textView: UITextView, with item: ComposeAutocompleteItem) {
    guard let match = viewModel.match else { return }
    let replacedRange = match.range

    switch item.payload {
      case let .thread(chatId, _, title):
        let currentAttributedText = textView.attributedText ?? NSAttributedString()
        let result = threadLinkDetector.replaceThreadLink(
          in: currentAttributedText,
          range: match.range,
          with: title,
          chatId: chatId
        )

        textView.attributedText = result.newAttributedText
        textView.selectedRange = NSRange(location: result.newCursorPosition, length: 0)
        dismissCompletion()
        delegate?.composeAutocompleteManager(self, didInsert: item, for: replacedRange)

      case .emoji:
        dismissCompletion()
    }
  }
}

extension ComposeAutocompleteManager: ComposeAutocompleteCompletionDelegate {
  func autocompleteCompletion(_ view: ComposeAutocompleteCompletionView, didSelect item: ComposeAutocompleteItem) {
    guard let textView else { return }
    replaceAutocomplete(in: textView, with: item)
  }

  func autocompleteCompletionDidRequestClose(_ view: ComposeAutocompleteCompletionView) {
    dismissCompletion(suppressCurrentMatch: true)
  }
}

extension ComposeView {
  func setupAutocompleteManager() {
    if let autocompleteManager {
      autocompleteManager.configure(spaceId: spaceId)
      return
    }

    guard let window,
          let windowScene = window.windowScene,
          let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
          let rootView = keyWindow.rootViewController?.view
    else {
      return
    }

    autocompleteManager = ComposeAutocompleteManager(database: AppDatabase.shared, spaceId: spaceId)
    autocompleteManager?.delegate = self
    autocompleteManager?.attachTo(textView: textView, parentView: rootView)
  }
}

extension ComposeView: ComposeAutocompleteManagerDelegate {
  func composeAutocompleteManager(
    _ manager: ComposeAutocompleteManager,
    didInsert item: ComposeAutocompleteItem,
    for range: NSRange
  ) {
    updateHeight()
    draftManager.invalidateLoadedEntities()
  }

  func composeAutocompleteManagerDidDismiss(_ manager: ComposeAutocompleteManager) {}
}
