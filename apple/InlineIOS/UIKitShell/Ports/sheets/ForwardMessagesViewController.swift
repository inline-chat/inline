import Combine
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import Logger
import UIKit

/// What forwarding does once destinations are picked, shared by the UIKit sheet and
/// `MessageMenuActions` (its `forwardMessages(destinations:selection:)` is this, verbatim).
@MainActor
enum ForwardMessagesPerformer {
  /// The forward source for `messages`, or nil when they are empty or span several chats.
  /// Same rules as `ForwardMessagesSheetModel.makeSelection` (iOS 17-gated in InlineUI).
  static func selection(for messages: [FullMessage]) -> InlineUI.ForwardMessagesSelection? {
    guard let sourceMessage = messages.first else { return nil }
    let sourceChatId = sourceMessage.chatId
    let messageIds = messages.map(\.message.messageId)
    guard let previewMessageId = messageIds.first else { return nil }
    guard !messages.contains(where: { $0.chatId != sourceChatId }) else { return nil }
    return InlineUI.ForwardMessagesSelection(
      fromPeerId: sourceMessage.peerId,
      sourceChatId: sourceChatId,
      messageIds: messageIds,
      previewMessageId: previewMessageId
    )
  }

  /// Single destination: put the forward into that chat's compose and open it
  /// (the `onSelect` of `presentForwardSheet`).
  static func stageForward(to destinationPeer: Peer, selection: InlineUI.ForwardMessagesSelection) {
    ChatState.shared.setForwardingMessages(
      peer: destinationPeer,
      fromPeerId: selection.fromPeerId,
      sourceChatId: selection.sourceChatId,
      messageIds: selection.messageIds
    )
    var userInfo: [AnyHashable: Any] = [:]
    if let userId = destinationPeer.asUserId() { userInfo["peerUserId"] = userId }
    if let threadId = destinationPeer.asThreadId() { userInfo["peerThreadId"] = threadId }
    NotificationCenter.default.post(
      name: Notification.Name("NavigateToForwardDestination"), object: nil, userInfo: userInfo
    )
  }

  /// Multi-destination send (the `onSend` of `presentForwardSheet`).
  static func forward(
    destinations: [HomeChatItem],
    selection: InlineUI.ForwardMessagesSelection
  ) async {
    guard !destinations.isEmpty else { return }
    guard !selection.messageIds.isEmpty else {
      Log.shared.error("Forward failed: empty message ids")
      return
    }
    for destination in destinations {
      let destinationPeer = destination.peerId
      do {
        let result = try await Api.realtime.send(.forwardMessages(
          fromPeerId: selection.fromPeerId,
          toPeerId: destinationPeer,
          messageIds: selection.messageIds
        ))
        if case let .forwardMessages(response) = result, response.updates.isEmpty {
          _ = await Api.realtime.sendQueued(.getChatHistory(peer: destinationPeer))
        }
      } catch {
        Log.shared.error("Forward failed", error: error)
      }
    }
    ToastManager.shared.showToast(
      "Forwarded to \(destinations.count) chats", type: .success, systemImage: "arrowshape.turn.up.right"
    )
  }
}

/// UIKit port of InlineUI's iOS `ForwardMessagesSheet`: searchable chat list; tapping a chat stages
/// the forward in it and opens it, Select turns on multi-select and Send forwards to all picked.
/// Destinations come from `AppDatabase.homeChatListItemSnapshotsPublisher()`, the same source as
/// `ForwardMessagesSheetModel`.
@MainActor
final class ForwardMessagesViewController: FormViewController, UISearchResultsUpdating {
  private unowned let shell: MainShellController
  private let selection: InlineUI.ForwardMessagesSelection?
  private let log = Log.scoped("ForwardMessagesViewController")

  private var destinations: [HomeChatListItemSnapshot] = [] { didSet { setNeedsFormUpdate() } }
  private var hasLoaded = false { didSet { setNeedsFormUpdate() } }
  private var query = "" { didSet { if query != oldValue { setNeedsFormUpdate() } } }
  private var isSelecting = false { didSet { updateNavigationItems(); setNeedsFormUpdate() } }
  private var selectedPeers: Set<Peer> = [] { didSet { updateNavigationItems(); setNeedsFormUpdate() } }
  private var isSending = false { didSet { updateNavigationItems(); setNeedsFormUpdate() } }
  private var cancellable: AnyCancellable?
  private let searchController = UISearchController(searchResultsController: nil)

  init(messages: [FullMessage], shell: MainShellController) {
    self.shell = shell
    selection = ForwardMessagesPerformer.selection(for: messages)
    super.init(style: .insetGrouped)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The sheet to present (page sheet with its own navigation bar).
  static func makeSheet(messages: [FullMessage], shell: MainShellController) -> UIViewController {
    ShellSheetSupport.wrap(ForwardMessagesViewController(messages: messages, shell: shell), shell: shell)
  }

  override func registerCells(in tableView: UITableView) {
    SheetPeerRowCell.register(in: tableView)
  }

  override func viewDidLoad() {
    // Destinations arrive synchronously (immediate scheduling) so the first frame has the list.
    cancellable = AppDatabase.shared
      .homeChatListItemSnapshotsPublisher()
      .sink { [weak self] snapshots in
        self?.apply(snapshots)
      }
    super.viewDidLoad()
    searchController.searchResultsUpdater = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchBar.placeholder = String(localized: "Search")
    searchController.searchBar.autocapitalizationType = .none
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
    navigationItem.largeTitleDisplayMode = .never
    definesPresentationContext = true
    updateNavigationItems()
  }

  private func apply(_ snapshots: [HomeChatListItemSnapshot]) {
    hasLoaded = true
    var seen = Set<Peer>()
    destinations = snapshots.filter { seen.insert($0.peerId).inserted }
    let available = Set(destinations.map(\.peerId))
    if !selectedPeers.isSubset(of: available) {
      selectedPeers.formIntersection(available)
    }
  }

  func updateSearchResults(for searchController: UISearchController) {
    query = searchController.searchBar.text ?? ""
  }

  // MARK: Navigation bar

  private func updateNavigationItems() {
    guard isViewLoaded else { return }
    title = selectedPeers.isEmpty ? String(localized: "Forward") : "\(selectedPeers.count) Selected"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .cancel,
      primaryAction: UIAction { [weak self] _ in self?.close() }
    )
    navigationItem.leftBarButtonItem?.isEnabled = !isSending

    var items: [UIBarButtonItem] = []
    let toggle = UIBarButtonItem(
      title: isSelecting ? String(localized: "Done") : String(localized: "Select"),
      primaryAction: UIAction { [weak self] _ in self?.toggleSelectionMode() }
    )
    toggle.isEnabled = !isSending
    if isSending {
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      items.append(UIBarButtonItem(customView: spinner))
    } else if isSelecting, !selectedPeers.isEmpty {
      let send = UIBarButtonItem(
        title: String(localized: "Send"),
        primaryAction: UIAction { [weak self] _ in self?.send() }
      )
      send.style = .done
      items.append(send)
    }
    items.append(toggle)
    navigationItem.rightBarButtonItems = items
    isModalInPresentation = isSending
    navigationController?.isModalInPresentation = isSending
  }

  private func toggleSelectionMode() {
    if isSelecting {
      selectedPeers.removeAll()
      isSelecting = false
    } else {
      isSelecting = true
    }
  }

  // MARK: Form

  private var filteredDestinations: [HomeChatListItemSnapshot] {
    let needle = HomeChatListItemSnapshot.normalizedSearchText(query)
    guard !needle.isEmpty else { return destinations }
    return destinations.filter { $0.searchText.contains(needle) }
  }

  @FormSectionsBuilder
  override func makeSections() -> [FormSection] {
    let filtered = filteredDestinations
    FormSection("chats") {
      if !hasLoaded {
        FormRow(
          "loading", title: String(localized: "Loading chats…"), accessory: .activity
        )
      } else if filtered.isEmpty {
        FormRow.note(
          "empty",
          query.isEmpty ? String(localized: "No chats available") : String(localized: "No chats found")
        )
      } else {
        for destination in filtered {
          FormRow.peer(
            "peer-\(destination.peerId)",
            content(for: destination)
          ) { [weak self] in
            self?.activate(destination)
          }
        }
      }
    }
  }

  private func content(for destination: HomeChatListItemSnapshot) -> SheetPeerRowCell.Content {
    let identity: SheetPeerRowCell.Identity
    if let userInfo = destination.item.displayUserInfo {
      identity = .user(userInfo)
    } else if let chat = destination.item.chat {
      identity = .thread(ThreadIconDescriptor(
        emoji: chat.emoji,
        title: destination.title,
        isReplyThread: chat.isReplyThread,
        accessibilityLabel: destination.title
      ))
    } else {
      identity = .thread(ThreadIconDescriptor(emoji: nil, title: "Chat", accessibilityLabel: "Chat"))
    }
    return SheetPeerRowCell.Content(
      identity: identity,
      title: destination.title,
      subtitle: Self.subtitle(for: destination),
      selection: isSelecting ? (selectedPeers.contains(destination.peerId) ? .selected : .unselected) : .none,
      showsPin: destination.pinned,
      showsUnread: destination.unread,
      isEnabled: !isSending
    )
  }

  /// Parent thread, else "Space · preview", else the preview (as the SwiftUI row).
  private static func subtitle(for destination: HomeChatListItemSnapshot) -> String? {
    if let parentTitle = destination.parentTitle, !parentTitle.isEmpty {
      return parentTitle
    }
    if let spaceTitle = destination.spaceTitle, !spaceTitle.isEmpty {
      return destination.preview.isEmpty ? spaceTitle : "\(spaceTitle) · \(destination.preview)"
    }
    return destination.preview.isEmpty ? nil : destination.preview
  }

  // MARK: Actions

  private func activate(_ destination: HomeChatListItemSnapshot) {
    guard !isSending else { return }
    if isSelecting {
      CompatHaptics.selection()
      if selectedPeers.contains(destination.peerId) {
        selectedPeers.remove(destination.peerId)
      } else {
        selectedPeers.insert(destination.peerId)
      }
      return
    }
    guard let selection else {
      log.error("Missing forward source metadata")
      return
    }
    ForwardMessagesPerformer.stageForward(to: destination.peerId, selection: selection)
    close()
  }

  private func send() {
    guard let selection else {
      log.error("Missing forward source metadata")
      return
    }
    let picked = destinations.filter { selectedPeers.contains($0.peerId) }.map(\.item)
    guard !picked.isEmpty, !isSending else { return }
    isSending = true
    Task { [weak self] in
      await ForwardMessagesPerformer.forward(destinations: picked, selection: selection)
      guard let self else { return }
      isSending = false
      close()
    }
  }

  private func close() {
    searchController.isActive = false
    closeShellSheet(shell)
  }
}
