import Combine
import InlineKit
import Logger
import Observation

@MainActor
@Observable
final class ForwardMessagesSheetModel {
  let supportsMultiSelect: Bool
  let selection: ForwardMessagesSheet.ForwardMessagesSelection?

  var searchText = "" {
    didSet {
      guard searchText != oldValue else { return }
      applyFilter()
    }
  }

  var isSelecting = false
  var isSending = false
  var selectedPeers: Set<Peer> = []
  private(set) var destinations: [ForwardMessagesDestination] = []
  private(set) var filteredDestinations: [ForwardMessagesDestination] = []

  #if os(macOS)
  var isSearchFocused = false
  var highlightedDestinationId: Int64?
  #endif

  @ObservationIgnored private let database: AppDatabase
  @ObservationIgnored private let log = Log.scoped("ForwardMessagesSheetModel")
  @ObservationIgnored private var cancellable: AnyCancellable?
  @ObservationIgnored private var normalizedQuery = ""

  var selectedCount: Int {
    selectedPeers.count
  }

  var navigationTitle: String {
    selectedCount > 0 ? "\(selectedCount) Selected" : "Forward"
  }

  var shouldShowSendButton: Bool {
    supportsMultiSelect && isSelecting && selectedCount > 0
  }

  var selectedItems: [HomeChatItem] {
    guard !selectedPeers.isEmpty else { return [] }
    return destinations.compactMap { destination in
      selectedPeers.contains(destination.peerId) ? destination.item : nil
    }
  }

  init(
    messages: [FullMessage],
    database: AppDatabase,
    supportsMultiSelect: Bool
  ) {
    self.database = database
    self.supportsMultiSelect = supportsMultiSelect
    selection = Self.makeSelection(messages: messages)
  }

  func start() {
    guard cancellable == nil else { return }

    cancellable = database
      .homeChatListItemSnapshotsPublisher()
      .sink { [weak self] snapshots in
        self?.applySnapshots(snapshots)
      }
  }

  func toggleSelectionMode() {
    if isSelecting {
      clearSelectionMode()
      return
    }

    isSelecting = true
  }

  func clearSelectionMode() {
    selectedPeers.removeAll()
    isSelecting = false
  }

  func toggleSelection(for destination: ForwardMessagesDestination) {
    if selectedPeers.contains(destination.peerId) {
      selectedPeers.remove(destination.peerId)
    } else {
      selectedPeers.insert(destination.peerId)
    }
  }

  func isSelected(_ destination: ForwardMessagesDestination) -> Bool {
    selectedPeers.contains(destination.peerId)
  }

  #if os(macOS)
  func syncHighlightedDestination() {
    guard !filteredDestinations.isEmpty else {
      highlightedDestinationId = nil
      return
    }

    guard let highlightedDestinationId,
          filteredDestinations.contains(where: { $0.id == highlightedDestinationId })
    else {
      highlightedDestinationId = filteredDestinations[0].id
      return
    }
  }

  func moveHighlightedDestination(by offset: Int) {
    guard !filteredDestinations.isEmpty else {
      highlightedDestinationId = nil
      return
    }

    let currentIndex = filteredDestinations.firstIndex { $0.id == highlightedDestinationId } ?? -1
    let nextIndex = min(max(currentIndex + offset, 0), filteredDestinations.count - 1)
    highlightedDestinationId = filteredDestinations[nextIndex].id
  }

  func highlightedDestination() -> ForwardMessagesDestination? {
    if let highlightedDestinationId,
       let destination = filteredDestinations.first(where: { $0.id == highlightedDestinationId }) {
      return destination
    }

    guard let firstDestination = filteredDestinations.first else {
      return nil
    }

    highlightedDestinationId = firstDestination.id
    return firstDestination
  }

  func isHighlighted(_ destination: ForwardMessagesDestination) -> Bool {
    highlightedDestinationId == destination.id
  }
  #endif

  private func applySnapshots(_ snapshots: [HomeChatListItemSnapshot]) {
    let destinations = snapshots.map(ForwardMessagesDestination.init(snapshot:))
    var byPeer: [Peer: ForwardMessagesDestination] = [:]
    for destination in destinations where byPeer[destination.peerId] == nil {
      byPeer[destination.peerId] = destination
    }

    self.destinations = destinations
    selectedPeers.formIntersection(Set(byPeer.keys))
    applyFilter()
  }

  private func applyFilter() {
    normalizedQuery = HomeChatListItemSnapshot.normalizedSearchText(searchText)

    if normalizedQuery.isEmpty {
      filteredDestinations = destinations
    } else {
      filteredDestinations = destinations.filter { destination in
        destination.searchText.contains(normalizedQuery)
      }
    }

    #if os(macOS)
    syncHighlightedDestination()
    #endif
  }

  static func makeSelection(messages: [FullMessage]) -> ForwardMessagesSheet.ForwardMessagesSelection? {
    guard let sourceMessage = messages.first else {
      return nil
    }

    let sourceChatId = sourceMessage.chatId
    let messageIds = messages.map(\.message.messageId)
    guard let previewMessageId = messageIds.first else {
      return nil
    }

    guard !messages.contains(where: { $0.chatId != sourceChatId }) else {
      return nil
    }

    return ForwardMessagesSheet.ForwardMessagesSelection(
      fromPeerId: sourceMessage.peerId,
      sourceChatId: sourceChatId,
      messageIds: messageIds,
      previewMessageId: previewMessageId
    )
  }
}

struct ForwardMessagesDestination: Identifiable, Equatable {
  enum Avatar: Equatable {
    case user(UserInfo)
    case chat(title: String, emoji: String?)
    case fallback
  }

  let snapshot: HomeChatListItemSnapshot
  let avatar: Avatar

  var id: Int64 { snapshot.id }
  var item: HomeChatItem { snapshot.item }
  var peerId: Peer { snapshot.peerId }
  var title: String { snapshot.title }
  var parentTitle: String? { snapshot.parentTitle }
  var preview: String { snapshot.preview }
  var spaceTitle: String? { snapshot.spaceTitle }
  var unread: Bool { snapshot.unread }
  var pinned: Bool { snapshot.pinned }
  var searchText: String { snapshot.searchText }

  init(snapshot: HomeChatListItemSnapshot) {
    self.snapshot = snapshot

    if let userInfo = snapshot.item.displayUserInfo {
      avatar = .user(userInfo)
    } else if let chat = snapshot.item.chat {
      avatar = .chat(title: snapshot.title, emoji: chat.emoji)
    } else {
      avatar = .fallback
    }
  }
}
