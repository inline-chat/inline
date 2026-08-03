import Combine
import InlineKit
import TextProcessing
import UIKit

@MainActor
protocol ComposeAutocompleteManagerDelegate: AnyObject {
  func composeAutocompleteManager(
    _ manager: ComposeAutocompleteManager,
    didInsert item: ComposeAutocompleteItem,
    for range: NSRange,
    activation: ComposeAutocompleteSelectionActivation
  )
}

@MainActor
final class ComposeAutocompleteManager: NSObject {
  private struct PresentationSession: Equatable {
    let kind: ComposeAutocompleteKind
    let triggerLocation: Int

    init(match: ComposeAutocompleteMatch) {
      kind = match.kind
      triggerLocation = match.range.location
    }
  }

  private static let autoPickExactMentionEnabled = true
  private static let removeMentionOnEditEnabled = true

  weak var delegate: ComposeAutocompleteManagerDelegate?

  private let mentionDetector = MentionDetector()
  private let slashCommandDetector = SlashCommandDetector()
  private let threadLinkDetector = ThreadLinkDetector()
  private let emojiDetector = EmojiAutocompleteDetector()
  private let mentionViewModel: MentionCompletionViewModel
  private let commandViewModel: PeerBotCommandsViewModel
  private let participantsViewModel: ChatParticipantsWithMembersViewModel
  private let viewModel: ComposeAutocompleteViewModel
  private var completionConstraints: [NSLayoutConstraint] = []
  private var cancellables = Set<AnyCancellable>()
  private var commandLoadTask: Task<Void, Never>?
  private var loadingPresentationTask: Task<Void, Never>?
  private var commandLoadStateOverride: ComposeAutocompleteLoadState?
  private var suppressMentionDetection = false
  private var presentationSession: PresentationSession?

  private var completionView: ComposeAutocompleteCompletionView?
  private weak var textView: UITextView?
  private weak var parentView: UIView?
  private weak var anchorView: UIView?

  init(database: AppDatabase, chatId: Int64, peerId: InlineKit.Peer, spaceId: Int64?) {
    let mentionViewModel = MentionCompletionViewModel()
    let commandViewModel = PeerBotCommandsViewModel(peer: peerId)
    self.mentionViewModel = mentionViewModel
    self.commandViewModel = commandViewModel
    participantsViewModel = ChatParticipantsWithMembersViewModel(
      db: database,
      chatId: chatId,
      purpose: .mentionCandidates
    )
    viewModel = ComposeAutocompleteViewModel(
      db: database,
      spaceId: spaceId,
      recentThreadChatIds: { limit in
        Self.recentThreadChatIds(limit: limit)
      },
      mentionItems: { query, limit in
        mentionViewModel.filter(with: query)
        return mentionViewModel.items.prefix(limit).map(Self.autocompleteItem(for:))
      },
      commandItems: { query, limit in
        commandViewModel.suggestions(matching: query).prefix(limit).map(Self.autocompleteItem(for:))
      },
      emojiItems: { query, limit in
        ComposeEmojiAutocompleteProvider.items(matching: query, limit: limit)
      }
    )
    super.init()
    bindViewModel()
    bindParticipants()
  }

  func configure(spaceId: Int64?) {
    viewModel.configure(spaceId: spaceId)
  }

  func attachTo(textView: UITextView, anchorView: UIView, parentView: UIView) {
    self.textView = textView
    self.anchorView = anchorView
    self.parentView = parentView
    setupCompletionView()
    installCompletionViewIfNeeded()
  }

  func handleTextChange(in textView: UITextView) -> Bool {
    completionView?.setKeyboardSelectionVisible(false)
    guard textView.isFirstResponder,
          let match = detectMatchAtCursor(in: textView)
    else {
      dismissCompletion()
      return false
    }

    viewModel.update(match: match)
    loadCommandsIfNeeded(for: match)
    return true
  }

  func handleIncomingText(_ text: String) {
    guard suppressMentionDetection, !text.isEmpty else { return }
    let delimiters = CharacterSet.whitespacesAndNewlines
      .union(CharacterSet(charactersIn: ".,!?;:"))
    if text.unicodeScalars.contains(where: { !delimiters.contains($0) }) {
      suppressMentionDetection = false
    }
  }

  func handleKeyPress(_ key: String) -> Bool {
    guard let completionView, completionView.isVisible else { return false }

    if key == "Escape" {
      dismissCompletion(suppressCurrentMatch: true)
      return true
    }

    guard completionView.canSelectItems else { return false }

    switch key {
    case "ArrowUp":
      completionView.setKeyboardSelectionVisible(true)
      viewModel.selectPrevious()
      return true
    case "ArrowDown":
      completionView.setKeyboardSelectionVisible(true)
      viewModel.selectNext()
      return true
    case "Enter":
      return completionView.selectCurrentItem(activation: .primary)
    case "Tab":
      return completionView.selectCurrentItem(activation: .completionOnly)
    default:
      return false
    }
  }

  func dismissCompletion(suppressCurrentMatch: Bool = false) {
    cancelLoadingPresentation()
    presentationSession = nil
    viewModel.hide(suppressCurrentMatch: suppressCurrentMatch)
    completionView?.hide()
  }

  func cleanup() {
    dismissCompletion()
    NSLayoutConstraint.deactivate(completionConstraints)
    completionConstraints.removeAll()
    completionView?.removeFromSuperview()
    completionView = nil
    commandLoadTask?.cancel()
    commandLoadTask = nil
    cancellables.removeAll()
  }

  private func bindViewModel() {
    Publishers.CombineLatest4(
      viewModel.$items,
      viewModel.$selectedIndex,
      viewModel.$match,
      viewModel.$loadState
    )
    .sink { [weak self] items, selectedIndex, match, loadState in
      guard let self else { return }
      Task { @MainActor [weak self] in
        self?.renderCompletion(
          items: items,
          selectedIndex: selectedIndex,
          match: match,
          loadState: loadState
        )
      }
    }
    .store(in: &cancellables)
  }

  private func bindParticipants() {
    participantsViewModel.$mentionCandidates
      .sink { [weak self] candidates in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.mentionViewModel.updateCandidates(candidates)
          if self.viewModel.match?.kind == .mention {
            self.viewModel.reloadCurrentMatch()
          }
        }
      }
      .store(in: &cancellables)

    Task { [weak self] in
      await self?.participantsViewModel.refetchParticipants()
    }
  }

  private func setupCompletionView() {
    guard completionView == nil else { return }
    let view = ComposeAutocompleteCompletionView()
    view.delegate = self
    completionView = view
  }

  private func installCompletionViewIfNeeded() {
    guard let completionView, let parentView, let anchorView else { return }
    guard completionView.superview == nil else {
      parentView.bringSubviewToFront(completionView)
      return
    }

    parentView.addSubview(completionView)
    let topLimit = completionView.topAnchor.constraint(
      greaterThanOrEqualTo: parentView.safeAreaLayoutGuide.topAnchor,
      constant: 8
    )
    completionConstraints = [
      completionView.leadingAnchor.constraint(equalTo: anchorView.leadingAnchor),
      completionView.trailingAnchor.constraint(equalTo: anchorView.trailingAnchor),
      completionView.bottomAnchor.constraint(equalTo: anchorView.topAnchor, constant: -8),
      topLimit,
    ]
    NSLayoutConstraint.activate(completionConstraints)
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

  private func detectMatchAtCursor(in textView: UITextView) -> ComposeAutocompleteMatch? {
    guard textView.markedTextRange == nil,
          textView.selectedRange.length == 0,
          (textView as? ComposeTextView)?.isCursorInCodeBlock != true
    else {
      return nil
    }

    let cursorPosition = textView.selectedRange.location
    let attributedText = textView.attributedText ?? NSAttributedString()

    if let range = slashCommandDetector.detectSlashCommandAt(
      cursorPosition: cursorPosition,
      in: attributedText
    ), NSMaxRange(range.range) == cursorPosition,
       !hasEntityAttribute(in: range.range, attributedText: attributedText) {
      return ComposeAutocompleteMatch(kind: .command, range: range.range, query: range.query)
    }

    if let threadRange = threadLinkDetector.detectThreadLinkAt(cursorPosition: cursorPosition, in: attributedText),
       isThreadCursorAtTokenEnd(cursorPosition, in: attributedText.string),
       !hasEntityAttribute(in: threadRange.range, attributedText: attributedText) {
      return ComposeAutocompleteMatch(kind: .thread, range: threadRange.range, query: threadRange.query)
    }

    if !suppressMentionDetection,
       let range = mentionDetector.detectMentionAt(cursorPosition: cursorPosition, in: attributedText),
       NSMaxRange(range.range) == cursorPosition,
       !hasEntityAttribute(in: range.range, attributedText: attributedText) {
      return ComposeAutocompleteMatch(kind: .mention, range: range.range, query: range.query)
    }

    if let range = emojiDetector.detectEmojiAutocompleteAt(
      cursorPosition: cursorPosition,
      in: attributedText
    ), NSMaxRange(range.range) == cursorPosition,
       !hasEntityAttribute(in: range.range, attributedText: attributedText) {
      return ComposeAutocompleteMatch(kind: .emoji, range: range.range, query: range.query)
    }

    return nil
  }

  private func isThreadCursorAtTokenEnd(_ cursorPosition: Int, in text: String) -> Bool {
    let text = text as NSString
    guard cursorPosition < text.length else { return true }
    let nextCharacter = text.character(at: cursorPosition)
    if nextCharacter == 10 || nextCharacter == 13 {
      return true
    }
    return nextCharacter == 93 &&
      cursorPosition + 1 < text.length &&
      text.character(at: cursorPosition + 1) == 93
  }

  private func hasEntityAttribute(in range: NSRange, attributedText: NSAttributedString) -> Bool {
    guard range.location != NSNotFound,
          range.length > 0,
          NSMaxRange(range) <= attributedText.length
    else {
      return false
    }

    var found = false
    attributedText.enumerateAttributes(in: range) { attributes, _, stop in
      found = attributes[.mentionUserId] != nil ||
        attributes[.mentionGroupId] != nil ||
        attributes[.botCommand] != nil ||
        attributes[.threadLink] != nil
      stop.pointee = ObjCBool(found)
    }
    return found
  }

  private func loadCommandsIfNeeded(for match: ComposeAutocompleteMatch) {
    guard match.kind == .command,
          commandViewModel.loadState != .loaded,
          commandLoadTask == nil
    else {
      return
    }

    commandLoadStateOverride = .loading
    renderCurrentState()
    let commandViewModel = commandViewModel
    commandLoadTask = Task { @MainActor [weak self] in
      await commandViewModel.ensureLoaded()
      guard let self else { return }
      commandLoadTask = nil
      commandLoadStateOverride = nil
      guard !Task.isCancelled, viewModel.match?.kind == .command else { return }
      viewModel.reloadCurrentMatch()
    }
  }

  private func renderCurrentState() {
    renderCompletion(
      items: viewModel.items,
      selectedIndex: viewModel.selectedIndex,
      match: viewModel.match,
      loadState: viewModel.loadState
    )
  }

  private func renderCompletion(
    items: [ComposeAutocompleteItem],
    selectedIndex: Int,
    match: ComposeAutocompleteMatch?,
    loadState: ComposeAutocompleteLoadState
  ) {
    guard let completionView else { return }
    guard match == viewModel.match,
          items == viewModel.items,
          selectedIndex == viewModel.selectedIndex,
          loadState == viewModel.loadState
    else {
      return
    }
    guard let match else {
      cancelLoadingPresentation()
      presentationSession = nil
      completionView.hide()
      return
    }
    let effectiveLoadState = effectiveLoadState(for: match, fallback: loadState)
    if items.isEmpty, effectiveLoadState == .loading {
      handleLoadingPresentation(for: match, in: completionView)
      return
    }

    cancelLoadingPresentation()
    if items.isEmpty, effectiveLoadState == .failed {
      let session = PresentationSession(match: match)
      let shouldAnimatePresentation = session != presentationSession
      presentationSession = session
      completionView.update(
        items: [],
        selectedIndex: 0,
        placeholder: .failed
      )
      installCompletionViewIfNeeded()
      parentView?.bringSubviewToFront(completionView)
      completionView.show(animated: shouldAnimatePresentation)
      return
    }

    guard !items.isEmpty, items.allSatisfy({ $0.kind == match.kind }) else {
      completionView.hide()
      return
    }

    let session = PresentationSession(match: match)
    let shouldAnimatePresentation = session != presentationSession
    presentationSession = session
    completionView.update(items: items, selectedIndex: selectedIndex, placeholder: nil)
    installCompletionViewIfNeeded()
    if let parentView {
      parentView.bringSubviewToFront(completionView)
    }
    completionView.show(animated: shouldAnimatePresentation)
  }

  private func handleLoadingPresentation(
    for match: ComposeAutocompleteMatch,
    in completionView: ComposeAutocompleteCompletionView
  ) {
    let session = PresentationSession(match: match)
    if completionView.isVisible, session == presentationSession {
      cancelLoadingPresentation()
      completionView.setContentInteractionEnabled(false)
      return
    }

    completionView.hide()
    scheduleLoadingPresentation(for: match, session: session)
  }

  private func scheduleLoadingPresentation(
    for match: ComposeAutocompleteMatch,
    session: PresentationSession
  ) {
    cancelLoadingPresentation()
    loadingPresentationTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(180))
      } catch {
        return
      }

      guard let self,
            !Task.isCancelled,
            viewModel.match == match,
            viewModel.items.isEmpty,
            effectiveLoadState(for: match, fallback: viewModel.loadState) == .loading,
            let completionView
      else {
        return
      }

      loadingPresentationTask = nil
      let shouldAnimatePresentation = session != presentationSession
      presentationSession = session
      completionView.update(items: [], selectedIndex: 0, placeholder: .loading)
      installCompletionViewIfNeeded()
      parentView?.bringSubviewToFront(completionView)
      completionView.show(animated: shouldAnimatePresentation)
    }
  }

  private func cancelLoadingPresentation() {
    loadingPresentationTask?.cancel()
    loadingPresentationTask = nil
  }

  private func effectiveLoadState(
    for match: ComposeAutocompleteMatch,
    fallback: ComposeAutocompleteLoadState
  ) -> ComposeAutocompleteLoadState {
    guard match.kind == .command else { return fallback }
    if let commandLoadStateOverride {
      return commandLoadStateOverride
    }
    switch commandViewModel.loadState {
    case .loading:
      return .loading
    case .failed:
      return .failed
    case .idle, .loaded:
      return .idle
    }
  }

  private func replaceAutocomplete(
    in textView: UITextView,
    with item: ComposeAutocompleteItem,
    activation: ComposeAutocompleteSelectionActivation
  ) {
    guard textView.isFirstResponder,
          let match = viewModel.match,
          match.kind == item.kind,
          detectMatchAtCursor(in: textView) == match
    else {
      _ = handleTextChange(in: textView)
      return
    }
    let replacedRange = match.range
    let currentAttributedText = textView.attributedText ?? NSAttributedString()

    switch item.payload {
    case let .mention(mention):
      let mentionText = mentionViewModel.mentionText(for: mention)
      let result = replaceMentionResult(
        mention,
        in: currentAttributedText,
        range: match.range,
        mentionText: mentionText
      )
      apply(result.newAttributedText, cursorPosition: result.newCursorPosition, to: textView)

    case let .command(suggestion):
      let commandText = suggestion.insertionText.trimmingCharacters(in: .whitespacesAndNewlines)
      let result = slashCommandDetector.replaceSlashCommand(
        in: currentAttributedText,
        range: match.range,
        with: commandText,
        targetBotUserId: suggestion.botId
      )
      apply(result.newAttributedText, cursorPosition: result.newCursorPosition, to: textView)

    case let .thread(chatId, _, title):
      let result = threadLinkDetector.replaceThreadLink(
        in: currentAttributedText,
        range: match.range,
        with: title,
        chatId: chatId,
        linkAttributes: threadLinkAttributes(for: textView),
        trailingAttributes: baseTextAttributes(for: textView)
      )

      apply(result.newAttributedText, cursorPosition: result.newCursorPosition, to: textView)

    case let .emoji(value, _):
      let preferredValue = EmojiSkinTonePreferenceStore.current().applying(to: value)
      let result = emojiDetector.replaceEmojiAutocomplete(
        in: currentAttributedText,
        range: match.range,
        with: preferredValue
      )
      apply(result.attributedText, cursorPosition: result.cursorPosition, to: textView)
    }

    dismissCompletion()
    delegate?.composeAutocompleteManager(
      self,
      didInsert: item,
      for: replacedRange,
      activation: activation
    )
  }

  private func apply(_ attributedText: NSAttributedString, cursorPosition: Int, to textView: UITextView) {
    textView.attributedText = attributedText
    textView.selectedRange = NSRange(location: cursorPosition, length: 0)
    textView.resetTypingAttributesToDefault()
  }

  private func replaceMentionResult(
    _ item: MentionCompletionItem,
    in attributedText: NSAttributedString,
    range: NSRange,
    mentionText: String,
    trailingText: String = " "
  ) -> (newAttributedText: NSAttributedString, newCursorPosition: Int) {
    switch item {
    case let .user(user):
      mentionDetector.replaceMention(
        in: attributedText,
        range: range,
        with: mentionText,
        userId: user.userInfo.user.id,
        trailingText: trailingText,
        mentionAttributes: mentionAttributes(for: textView),
        trailingAttributes: baseTextAttributes(for: textView)
      )
    case let .group(group):
      mentionDetector.replaceGroupMention(
        in: attributedText,
        range: range,
        with: mentionText,
        groupId: group.id,
        trailingText: trailingText,
        mentionAttributes: mentionAttributes(for: textView),
        trailingAttributes: baseTextAttributes(for: textView)
      )
    }
  }

  func prepareSemanticEntitiesForEdit(
    in textView: UITextView,
    changeRange: NSRange
  ) -> Bool {
    let attributedText = textView.attributedText ?? NSAttributedString()
    let mentionRanges = Self.removeMentionOnEditEnabled
      ? ComposeEntityEditing.affectedMentionRanges(in: attributedText, changeRange: changeRange)
      : []
    let commandRanges = ComposeEntityEditing.affectedBotCommandRanges(
      in: attributedText,
      changeRange: changeRange
    )
    guard !mentionRanges.isEmpty || !commandRanges.isEmpty else { return false }

    textView.textStorage.beginEditing()
    ComposeEntityEditing.stripMentions(
      in: textView.textStorage,
      ranges: mentionRanges,
      textColor: UIColor.label
    )
    ComposeEntityEditing.stripBotCommands(
      in: textView.textStorage,
      ranges: commandRanges,
      textColor: UIColor.label
    )
    textView.textStorage.endEditing()
    textView.resetTypingAttributesToDefault()

    suppressMentionDetection = !mentionRanges.isEmpty
    dismissCompletion()
    return true
  }

  func handleAutoPickIfNeeded(
    in textView: UITextView,
    changeRange: NSRange,
    replacementText text: String
  ) -> Bool {
    guard Self.autoPickExactMentionEnabled,
          let match = viewModel.match,
          match.kind == .mention,
          viewModel.items.count == 1,
          let item = viewModel.items.first,
          case let .mention(mention) = item.payload,
          text.count == 1,
          let scalar = text.unicodeScalars.first,
          CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,!?;:")).contains(scalar),
          changeRange.location == NSMaxRange(match.range),
          MentionCompletionViewModel.query(match.query, exactlyMatches: mention),
          detectMatchAtCursor(in: textView) == match
    else {
      return false
    }

    let currentAttributedText = textView.attributedText ?? NSAttributedString()
    let result = replaceMentionResult(
      mention,
      in: currentAttributedText,
      range: match.range,
      mentionText: mentionViewModel.mentionText(for: mention),
      trailingText: text
    )
    apply(result.newAttributedText, cursorPosition: result.newCursorPosition, to: textView)
    dismissCompletion()
    delegate?.composeAutocompleteManager(
      self,
      didInsert: item,
      for: match.range,
      activation: .completionOnly
    )
    return true
  }

  private func threadLinkAttributes(for textView: UITextView) -> [NSAttributedString.Key: Any] {
    var attributes = baseTextAttributes(for: textView)
    attributes[.foregroundColor] = linkColor(for: textView)
    return attributes
  }

  private func mentionAttributes(for textView: UITextView?) -> [NSAttributedString.Key: Any] {
    guard let textView else { return [:] }
    var attributes = baseTextAttributes(for: textView)
    attributes[.foregroundColor] = linkColor(for: textView)
    return attributes
  }

  private func baseTextAttributes(for textView: UITextView?) -> [NSAttributedString.Key: Any] {
    [
      .font: textView?.font ?? UIFont.systemFont(ofSize: 17),
      .foregroundColor: UIColor.label,
    ]
  }

  private func linkColor(for textView: UITextView) -> UIColor {
    (textView as? ComposeTextView)?.composeView?.linkColor
      ?? textView.tintColor
      ?? ThemeManager.shared.selected.accent
  }

  private static func autocompleteItem(for mention: MentionCompletionItem) -> ComposeAutocompleteItem {
    ComposeAutocompleteItem(
      id: "mention-\(mention.id)",
      kind: .mention,
      title: mention.title,
      subtitle: mention.subtitle,
      symbol: mention.group == nil ? nil : "person.2.fill",
      avatarUserInfo: mention.userInfo,
      payload: .mention(mention)
    )
  }

  private static func autocompleteItem(for command: PeerBotCommandSuggestion) -> ComposeAutocompleteItem {
    let botLabel = command.isAmbiguous ? (command.botLabel ?? command.botDisplayName) : nil
    let subtitle = [botLabel, command.description]
      .compactMap { value in value?.isEmpty == false ? value : nil }
      .joined(separator: " · ")
    return ComposeAutocompleteItem(
      id: "command-\(command.id)",
      kind: .command,
      title: "/\(command.command)",
      subtitle: subtitle,
      avatarUserInfo: command.botUserInfo,
      payload: .command(command)
    )
  }
}

extension ComposeAutocompleteManager: ComposeAutocompleteCompletionDelegate {
  func autocompleteCompletion(
    _ view: ComposeAutocompleteCompletionView,
    didSelect item: ComposeAutocompleteItem,
    activation: ComposeAutocompleteSelectionActivation
  ) {
    guard let textView else { return }
    replaceAutocomplete(in: textView, with: item, activation: activation)
  }
}

extension ComposeView {
  func setupAutocompleteManager() {
    if let autocompleteManager {
      autocompleteManager.configure(spaceId: spaceId)
      return
    }

    guard let peerId,
          let chatId,
          let parentView = superview
    else {
      return
    }

    autocompleteManager = ComposeAutocompleteManager(
      database: AppDatabase.shared,
      chatId: chatId,
      peerId: peerId,
      spaceId: spaceId
    )
    autocompleteManager?.delegate = self
    autocompleteManager?.attachTo(
      textView: textView,
      anchorView: composeAndButtonContainer,
      parentView: parentView
    )
  }
}

extension ComposeView: ComposeAutocompleteManagerDelegate {
  func composeAutocompleteManager(
    _ manager: ComposeAutocompleteManager,
    didInsert item: ComposeAutocompleteItem,
    for range: NSRange,
    activation: ComposeAutocompleteSelectionActivation
  ) {
    switch item.payload {
    case .command where activation == .primary:
      sendMessage()
    case .command, .mention, .thread, .emoji:
      updateHeight()
      draftManager.invalidateLoadedEntities()
    }
  }
}
