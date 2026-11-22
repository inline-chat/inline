import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineSearch
import UIKit

/// The Search tab: chats, people on Inline and messages, from `InlineSearchViewModel`.
///
/// iOS 26+: the tab is a `UISearchTab`, so the system places the field in the tab bar.
/// Earlier: a navigation-bar search field that stays visible.
@MainActor
final class HomeSearchViewController: FormViewController, UISearchResultsUpdating, UISearchBarDelegate {
  private unowned let shell: MainShellController
  private let model: InlineSearchViewModel
  private let searchController = UISearchController(searchResultsController: nil)

  private var scope: InlineSearchScope {
    InlineSearchScope(
      spaceId: shell.home.activeSpaceId,
      includeArchived: false,
      includeSpaceChatsInHome: true,
      includeGlobalUsers: true,
      messageSort: .relevance
    )
  }

  init(shell: MainShellController) {
    self.shell = shell
    model = InlineSearchViewModel(
      db: AppDatabase.shared,
      limits: InlineSearchLimits(chatLimit: 24, messageBatchSize: 20, globalUserLimit: 20, globalDebounceNanoseconds: 220_000_000)
    )
    super.init(style: .insetGrouped)
    title = String(localized: "Search")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.largeTitleDisplayMode = .always
    navigationController?.navigationBar.prefersLargeTitles = true
    searchController.searchResultsUpdater = self
    searchController.searchBar.delegate = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchBar.placeholder = String(localized: "Chats, people and messages")
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
    definesPresentationContext = true
  }

  func updateSearchResults(for searchController: UISearchController) {
    let query = searchController.searchBar.text ?? ""
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      model.clear()
    } else {
      model.search(query, scope: scope)
    }
  }

  override func makeSections() -> [FormSection] {
    let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    var sections: [FormSection] = []
    guard !query.isEmpty else {
      return [FormSection("hint", footer: String(localized: "Type to find existing chats or search for people to start new conversations."), rows: [])]
    }
    if !model.chats.isEmpty {
      sections.append(FormSection("chats", header: String(localized: "Chats"), rows: model.chats.map { result in
        FormRow.navigation(
          "chat-\(result.id)",
          result.title,
          subtitle: result.subtitle ?? (result.preview.isEmpty ? nil : result.preview),
          icon: FormIcon(systemName: result.peer.isThread ? "number" : "person.crop.circle")
        ) { [weak self] in self?.open(.chat(peer: result.peer)) }
      }))
    }
    if !model.globalUsers.isEmpty {
      sections.append(FormSection("people", header: String(localized: "People"), rows: model.globalUsers.map { result in
        FormRow.navigation(
          "user-\(result.id)",
          result.title,
          subtitle: result.subtitle,
          icon: FormIcon(systemName: "person.crop.circle.badge.plus")
        ) { [weak self] in self?.open(.chat(peer: .user(id: result.user.id))) }
      }))
    }
    if !model.messages.isEmpty {
      var rows = model.messages.map { result in
        FormRow.navigation(
          "message-\(result.id)",
          result.chat?.humanReadableTitle ?? result.peerUser?.displayName ?? String(localized: "Message"),
          subtitle: result.snippet,
          icon: FormIcon(systemName: "text.bubble")
        ) { [weak self] in
          self?.open(.chatMessage(peer: result.peer, messageID: result.message.message.messageId))
        }
      }
      if model.hasMoreMessages {
        rows.append(.button("more", String(localized: "Show More"), isLoading: model.isLoadingMoreMessages) {
          [weak self] in self?.model.loadMoreMessages()
        })
      }
      sections.append(FormSection("messages", header: String(localized: "Messages"), rows: rows))
    }
    if sections.isEmpty {
      if model.isSearching {
        sections.append(FormSection("searching", rows: [.note("searching", String(localized: "Searching…"))]))
      } else {
        sections.append(FormSection("empty", footer: model.errorText ?? String(localized: "No results"), rows: []))
      }
    }
    return sections
  }

  private func open(_ destination: Destination) {
    if let peer = destination.chatPeer {
      ExperimentalHomeNavigationPerformance.beginChatOpen(peer: peer, source: "search")
    }
    shell.router.push(destination, for: .search)
  }
}
