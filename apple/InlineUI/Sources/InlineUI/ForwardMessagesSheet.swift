import InlineKit
import Logger
import SwiftUI

#if os(macOS)
import AppKit
#endif

public struct ForwardMessagesSheet: View {
  public struct ForwardMessagesSelection: Sendable {
    public let fromPeerId: Peer
    public let sourceChatId: Int64
    public let messageIds: [Int64]
    public let previewMessageId: Int64

    public init(
      fromPeerId: Peer,
      sourceChatId: Int64,
      messageIds: [Int64],
      previewMessageId: Int64
    ) {
      self.fromPeerId = fromPeerId
      self.sourceChatId = sourceChatId
      self.messageIds = messageIds
      self.previewMessageId = previewMessageId
    }
  }

  public typealias ForwardMessagesSelectHandler = (_ destination: HomeChatItem, _ selection: ForwardMessagesSelection)
    -> Void
  public typealias ForwardMessagesSendHandler = @MainActor (
    _ destinations: [HomeChatItem],
    _ selection: ForwardMessagesSelection
  ) async -> Void

  @Environment(\.dismiss) private var dismiss

  private let onSelect: ForwardMessagesSelectHandler?
  private let onSend: ForwardMessagesSendHandler?
  private let onClose: (() -> Void)?
  private let log = Log.scoped("ForwardMessagesSheet")

  @State private var model: ForwardMessagesSheetModel

  #if os(macOS)
  @State private var macKeyMonitor: Any?

  private var filteredDestinationIds: [Int64] {
    model.filteredDestinations.map(\.id)
  }
  #endif

  public init(
    messages: [FullMessage],
    database: AppDatabase = AppDatabase.shared,
    onSelect: ForwardMessagesSelectHandler? = nil,
    onSend: ForwardMessagesSendHandler? = nil,
    onClose: (() -> Void)? = nil
  ) {
    self.onSelect = onSelect
    self.onSend = onSend
    self.onClose = onClose
    _model = State(wrappedValue: ForwardMessagesSheetModel(
      messages: messages,
      database: database,
      supportsMultiSelect: onSend != nil
    ))
  }

  public var body: some View {
    content
      .task {
        model.start()
      }
  }

  @ViewBuilder
  private var content: some View {
    #if os(macOS)
    MacForwardMessagesSheetView(
      model: model,
      onClose: closeSheet,
      onToggleSelectionMode: model.toggleSelectionMode,
      onSend: handleSend,
      onActivateDestination: handleMacRowActivation
    )
    .onExitCommand(perform: handleExitCommand)
    .frame(minWidth: 440, minHeight: 520)
    .onAppear {
      model.syncHighlightedDestination()
      focusSearchField()
      installMacKeyMonitor()
    }
    .onDisappear {
      removeMacKeyMonitor()
    }
    .onChange(of: filteredDestinationIds) {
      model.syncHighlightedDestination()
    }
    #else
    IOSForwardMessagesSheetView(
      model: model,
      onToggleSelectionMode: model.toggleSelectionMode,
      onSend: handleSend,
      onActivateDestination: handleSelection
    )
    #endif
  }

  #if os(macOS)
  private func installMacKeyMonitor() {
    guard macKeyMonitor == nil else { return }
    macKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handleMacKeyDown(event)
    }
  }

  private func removeMacKeyMonitor() {
    guard let macKeyMonitor else { return }
    NSEvent.removeMonitor(macKeyMonitor)
    self.macKeyMonitor = nil
  }

  private func handleMacKeyDown(_ event: NSEvent) -> NSEvent? {
    let textInputFocused = isTextInputFocused(in: event.window)

    if let action = ForwardMessagesMacKeyBindings.action(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      modifierFlags: event.modifierFlags,
      isTextInputFocused: textInputFocused,
      hasSearchText: !model.searchText.isEmpty
    ) {
      switch action {
        case let .moveHighlightedChat(offset):
          model.moveHighlightedDestination(by: offset)
          return nil
        case .toggleHighlightedSelection:
          return handleSpaceKey() ? nil : event
        case .activateHighlightedChat:
          return activateHighlightedDestination() ? nil : event
        case .backspaceSearch:
          focusSearchField()
          model.searchText.removeLast()
          return nil
      }
    }

    guard !textInputFocused,
          let characters = event.characters,
          characters.contains(where: { !$0.isWhitespace }),
          characters.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      return event
    }

    focusSearchField()
    model.searchText.append(characters)
    return nil
  }

  private func activateHighlightedDestination() -> Bool {
    guard let destination = model.highlightedDestination() else { return false }
    handleMacRowActivation(destination)
    return true
  }

  private func handleSpaceKey() -> Bool {
    guard let destination = model.highlightedDestination() else { return false }

    if !model.isSelecting {
      model.isSelecting = true
    }

    model.toggleSelection(for: destination)
    return true
  }

  private func focusSearchField() {
    DispatchQueue.main.async {
      model.isSearchFocused = true
    }
  }

  private func isTextInputFocused(in window: NSWindow?) -> Bool {
    guard let firstResponder = window?.firstResponder else { return false }
    return firstResponder is NSTextField
      || firstResponder is NSTextView
      || firstResponder is NSSecureTextField
      || (firstResponder is NSText && (firstResponder as? NSText)?.delegate is NSTextField)
  }

  private func handleMacRowActivation(_ destination: ForwardMessagesDestination) {
    model.highlightedDestinationId = destination.id
    handleSelection(destination)
  }
  #endif

  private func handleExitCommand() {
    if model.isSelecting {
      model.clearSelectionMode()
      return
    }
    closeSheet()
  }

  private func handleSelection(_ destination: ForwardMessagesDestination) {
    if model.supportsMultiSelect, model.isSelecting {
      model.toggleSelection(for: destination)
      return
    }

    guard let selection = model.selection else {
      log.error("Missing forward source metadata")
      return
    }

    onSelect?(destination.item, selection)
    closeSheet()
  }

  private func handleSend() {
    guard let selection = model.selection else {
      log.error("Missing forward source metadata")
      return
    }

    let destinations = model.selectedItems
    guard !destinations.isEmpty else { return }
    guard let onSend else {
      log.error("Missing onSend handler for multi-forward")
      return
    }

    model.isSending = true
    Task { @MainActor in
      defer {
        model.isSending = false
      }
      await onSend(destinations, selection)
      closeSheet()
    }
  }

  private func closeSheet() {
    if let onClose {
      onClose()
    } else {
      dismiss()
    }
  }
}
