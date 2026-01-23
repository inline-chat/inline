import AppKit
import Combine
import InlineKit
import InlineUI
import Logger
import SwiftUI

private enum QuickSearchLayout {
  static let preferredWidth: CGFloat = 420
  static let maxListHeight: CGFloat = 420
  static let rowHeight: CGFloat = Theme.sidebarItemHeight
  static let rowSpacing: CGFloat = 1
  static let rowInnerPadding: CGFloat = 4
  static let sectionHeaderHeight: CGFloat = 22
  static let sectionSpacing: CGFloat = 8
  static let searchBarHeight: CGFloat = 36
  static let contentHorizontalPadding: CGFloat = 10
  static let contentVerticalPadding: CGFloat = 10
  static let searchHeaderVerticalPadding: CGFloat = 6
  static let searchHeaderHeight: CGFloat = searchBarHeight + (searchHeaderVerticalPadding * 2)
  static let listContentHorizontalInset: CGFloat = contentHorizontalPadding
  static let listContentTopInset: CGFloat = contentVerticalPadding
  static let listContentBottomInset: CGFloat = contentVerticalPadding
  static let separatorHeight: CGFloat = 1
  static let searchBarTextInset: CGFloat = 6
  static let cornerRadius: CGFloat = 14
  static let iconSize: CGFloat = 24
  static let iconContainerSize: CGFloat = 28
  static let iconTextSpacing: CGFloat = Theme.sidebarIconSpacing
  static let itemTextSpacing: CGFloat = 6
}

@MainActor
final class QuickSearchViewModel: ObservableObject {
  @Published var query: String = ""
  @Published var selectedIndex: Int = 0
  @Published var focusToken: UUID = .init()

  let localSearch: HomeSearchViewModel
  let globalSearch: GlobalSearch

  private let dependencies: AppDependencies
  private var cancellables = Set<AnyCancellable>()

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    localSearch = HomeSearchViewModel(db: dependencies.database)
    globalSearch = GlobalSearch()
    bindSearchUpdates()
  }

  var localResults: [HomeSearchResultItem] {
    localSearch.results
  }

  var globalResults: [GlobalSearchResult] {
    globalSearch.results
  }

  var renderedGlobalResults: [GlobalSearchResult] {
    let localUserIds = Set(localResults.compactMap { result in
      if case let .user(user) = result {
        return user.id
      }
      return nil
    })
    return globalResults.filter { result in
      switch result {
        case let .users(user):
          localUserIds.contains(user.id) == false
      }
    }
  }

  var isLoading: Bool {
    globalSearch.isLoading
  }

  var error: Error? {
    globalSearch.error
  }

  var totalResults: Int {
    localResults.count + renderedGlobalResults.count
  }

  func performSearch() {
    localSearch.search(query: query)
    globalSearch.updateQuery(query)
    selectedIndex = 0
  }

  func requestFocus() {
    focusToken = UUID()
  }

  func reset() {
    query = ""
    localSearch.search(query: "")
    globalSearch.clear()
    selectedIndex = 0
  }

  func clampSelection() {
    guard totalResults > 0 else {
      selectedIndex = 0
      return
    }
    selectedIndex = max(0, min(selectedIndex, totalResults - 1))
  }

  func moveSelection(isForward: Bool) {
    guard totalResults > 0 else { return }
    let nextIndex = isForward ? min(selectedIndex + 1, totalResults - 1) : max(selectedIndex - 1, 0)
    selectedIndex = nextIndex
  }

  func activateSelection() -> Bool {
    guard totalResults > 0 else { return false }
    if selectedIndex < localResults.count {
      selectLocal(localResults[selectedIndex])
    } else {
      let index = selectedIndex - localResults.count
      if renderedGlobalResults.indices.contains(index) {
        if case let .users(user) = renderedGlobalResults[index] {
          selectRemote(user)
        }
      }
    }
    return true
  }

  func selectLocal(_ result: HomeSearchResultItem) {
    switch result {
      case let .thread(threadInfo):
        openChat(peer: .thread(id: threadInfo.chat.id), space: threadInfo.space)
      case let .user(user):
        openChat(peer: .user(id: user.id), space: nil)
    }
  }

  func selectRemote(_ user: ApiUser) {
    openHomeTabIfNeeded()
    Task { @MainActor in
      do {
        try await dependencies.data.createPrivateChatWithOptimistic(user: user)
        dependencies.nav2?.navigate(to: .chat(peer: .user(id: user.id)))
      } catch {
        Log.shared.error("Failed to open a private chat with \(user.anyName)", error: error)
        dependencies.overlay.showError(message: "Failed to open a private chat with \(user.anyName)")
      }
    }
  }

  private func openChat(peer: Peer, space: Space?) {
    guard let nav2 = dependencies.nav2 else { return }
    if let space {
      nav2.openSpace(space)
    } else {
      openHomeTabIfNeeded()
    }
    nav2.navigate(to: .chat(peer: peer))
  }

  private func openHomeTabIfNeeded() {
    guard let nav2 = dependencies.nav2 else { return }
    if case .home = nav2.activeTab { return }
    if let index = nav2.tabs.firstIndex(where: { tab in
      if case .home = tab { return true }
      return false
    }) {
      nav2.setActiveTab(index: index)
    }
  }

  private func bindSearchUpdates() {
    localSearch.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    globalSearch.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
  }
}

struct QuickSearchOverlayView: View {
  @ObservedObject var viewModel: QuickSearchViewModel
  let onDismiss: () -> Void
  let onSizeChange: (NSSize) -> Void

  @FocusState private var isFocused: Bool
  @State private var lastSize: NSSize = .zero

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: QuickSearchLayout.cornerRadius, style: .continuous)
    let content = VStack(spacing: 0) {
      searchHeader
      if shouldShowDivider {
        Divider()
          .frame(height: QuickSearchLayout.separatorHeight)
      }
      if shouldShowList {
        QuickSearchResultsView(
          viewModel: viewModel,
          rowHeight: QuickSearchLayout.rowHeight,
          rowSpacing: QuickSearchLayout.rowSpacing,
          rowInnerPadding: QuickSearchLayout.rowInnerPadding,
          sectionHeaderHeight: QuickSearchLayout.sectionHeaderHeight,
          sectionSpacing: QuickSearchLayout.sectionSpacing,
          onSelectLocal: { result in
            viewModel.selectLocal(result)
            onDismiss()
          },
          onSelectRemote: { user in
            viewModel.selectRemote(user)
            onDismiss()
          }
        )
        .frame(height: listHeight)
      }
    }
    .frame(width: QuickSearchLayout.preferredWidth)
    .background(shape.fill(tint))
    .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 10)

    Group {
      if #available(macOS 26.0, *) {
        content.glassEffect(.regular, in: shape)
      } else {
        content
      }
    }
    .onAppear {
      isFocused = true
      notifySizeChange()
    }
    .onChange(of: viewModel.focusToken) { _ in
      isFocused = true
    }
    .onChange(of: viewModel.query) { _ in
      viewModel.performSearch()
      notifySizeChange()
    }
    .onChange(of: viewModel.localResults.count) { _ in
      viewModel.clampSelection()
      notifySizeChange()
    }
    .onChange(of: viewModel.renderedGlobalResults.count) { _ in
      viewModel.clampSelection()
      notifySizeChange()
    }
    .onChange(of: viewModel.isLoading) { _ in
      notifySizeChange()
    }
    .onChange(of: viewModel.error?.localizedDescription ?? "") { _ in
      notifySizeChange()
    }
  }

  private var searchHeader: some View {
    TextField(
      "",
      text: $viewModel.query,
      prompt: Text("Search chats and members")
        .foregroundStyle(.secondary)
    )
    .textFieldStyle(.plain)
    .font(.system(size: 15, weight: .medium))
    .frame(maxWidth: .infinity, minHeight: QuickSearchLayout.searchBarHeight, alignment: .leading)
    .submitLabel(.search)
    .autocorrectionDisabled()
    .focused($isFocused)
    .padding(.horizontal, QuickSearchLayout.searchBarTextInset)
    .padding(.horizontal, QuickSearchLayout.contentHorizontalPadding)
    .padding(.vertical, QuickSearchLayout.searchHeaderVerticalPadding)
    .frame(height: QuickSearchLayout.searchHeaderHeight)
    .onSubmit {
      if viewModel.activateSelection() {
        onDismiss()
      }
    }
  }

  private var trimmedQuery: String {
    viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var shouldShowList: Bool {
    !trimmedQuery.isEmpty || viewModel.isLoading || viewModel.error != nil
  }

  private var listHeight: CGFloat {
    guard shouldShowList else { return 0 }

    if viewModel.totalResults == 0, viewModel.isLoading == false, viewModel.error == nil {
      return QuickSearchLayout.rowHeight +
        QuickSearchLayout.listContentTopInset +
        QuickSearchLayout.listContentBottomInset
    }

    let visibleRows = min(viewModel.totalResults, 8)
    let rowBlockHeight = CGFloat(visibleRows) * QuickSearchLayout.rowHeight +
      CGFloat(max(visibleRows - 1, 0)) * QuickSearchLayout.rowSpacing
    var height = rowBlockHeight +
      QuickSearchLayout.listContentTopInset +
      QuickSearchLayout.listContentBottomInset
    let minimumHeight = QuickSearchLayout.rowHeight +
      QuickSearchLayout.listContentTopInset +
      QuickSearchLayout.listContentBottomInset

    if shouldShowGlobalHeader {
      height += QuickSearchLayout.sectionHeaderHeight + QuickSearchLayout.rowSpacing
      if shouldShowSectionSpacing {
        height += QuickSearchLayout.sectionSpacing
      }
    }

    return min(max(height, minimumHeight), QuickSearchLayout.maxListHeight)
  }

  private var preferredHeight: CGFloat {
    QuickSearchLayout.searchHeaderHeight +
      (shouldShowDivider ? QuickSearchLayout.separatorHeight : 0) +
      (shouldShowList ? listHeight : 0)
  }

  private var shouldShowDivider: Bool {
    shouldShowList
  }

  private var tint: Color {
    let opacity = colorScheme == .dark ? 0.14 : 0.16
    return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
  }

  private var shouldShowGlobalHeader: Bool {
    !viewModel.renderedGlobalResults.isEmpty
  }

  private var shouldShowSectionSpacing: Bool {
    !viewModel.localResults.isEmpty && shouldShowGlobalHeader
  }

  private func notifySizeChange() {
    let newSize = NSSize(width: QuickSearchLayout.preferredWidth, height: preferredHeight)
    guard abs(newSize.height - lastSize.height) > 0.5 else { return }
    lastSize = newSize
    onSizeChange(newSize)
  }
}

private struct QuickSearchResultsView: View {
  @ObservedObject var viewModel: QuickSearchViewModel
  let rowHeight: CGFloat
  let rowSpacing: CGFloat
  let rowInnerPadding: CGFloat
  let sectionHeaderHeight: CGFloat
  let sectionSpacing: CGFloat
  let onSelectLocal: (HomeSearchResultItem) -> Void
  let onSelectRemote: (ApiUser) -> Void

  private var hasAnyResults: Bool {
    !viewModel.localResults.isEmpty || !viewModel.renderedGlobalResults.isEmpty
  }

  private var trimmedQuery: String {
    viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var shouldShowSectionSpacing: Bool {
    !viewModel.localResults.isEmpty && !viewModel.renderedGlobalResults.isEmpty
  }

  var body: some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: rowSpacing) {
        if hasAnyResults {
          if !viewModel.localResults.isEmpty {
            ForEach(Array(viewModel.localResults.enumerated()), id: \.element.id) { index, result in
              QuickSearchRow(
                item: result,
                highlighted: viewModel.selectedIndex == index,
                rowHeight: rowHeight,
                rowInnerPadding: rowInnerPadding,
                action: { onSelectLocal(result) }
              )
            }
          }

          if !viewModel.renderedGlobalResults.isEmpty {
            QuickSearchSectionHeader(
              title: "Global Search",
              height: sectionHeaderHeight,
              rowInnerPadding: rowInnerPadding
            )
            .padding(.top, shouldShowSectionSpacing ? sectionSpacing : 0)

            ForEach(Array(viewModel.renderedGlobalResults.enumerated()), id: \.element.id) { index, result in
              let globalIndex = index + viewModel.localResults.count
              switch result {
                case let .users(user):
                  QuickSearchRow(
                    user: user,
                    highlighted: viewModel.selectedIndex == globalIndex,
                    rowHeight: rowHeight,
                    rowInnerPadding: rowInnerPadding,
                    action: { onSelectRemote(user) }
                  )
              }
            }
          }
        } else if viewModel.isLoading {
          QuickSearchLoadingRow(rowHeight: rowHeight, rowInnerPadding: rowInnerPadding)
        } else if let error = viewModel.error {
          QuickSearchEmptyRow(
            text: "Failed to load: \(error.localizedDescription)",
            rowHeight: rowHeight,
            rowInnerPadding: rowInnerPadding
          )
        } else if !trimmedQuery.isEmpty {
          QuickSearchEmptyRow(text: "No results found", rowHeight: rowHeight, rowInnerPadding: rowInnerPadding)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentMargins(
      .horizontal,
      QuickSearchLayout.listContentHorizontalInset,
      for: .scrollContent
    )
    .contentMargins(
      .top,
      QuickSearchLayout.listContentTopInset,
      for: .scrollContent
    )
    .contentMargins(
      .bottom,
      QuickSearchLayout.listContentBottomInset,
      for: .scrollContent
    )
    .scrollIndicators(.hidden, axes: .horizontal)
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct QuickSearchSectionHeader: View {
  let title: String
  let height: CGFloat
  let rowInnerPadding: CGFloat

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
      .padding(.horizontal, rowInnerPadding)
  }
}

private struct QuickSearchRow: View {
  @State private var isHovered: Bool = false

  let item: HomeSearchResultItem?
  let user: ApiUser?
  let highlighted: Bool
  let rowHeight: CGFloat
  let rowInnerPadding: CGFloat
  let action: () -> Void

  init(
    item: HomeSearchResultItem,
    highlighted: Bool,
    rowHeight: CGFloat,
    rowInnerPadding: CGFloat,
    action: @escaping () -> Void
  ) {
    self.item = item
    user = nil
    self.highlighted = highlighted
    self.rowHeight = rowHeight
    self.rowInnerPadding = rowInnerPadding
    self.action = action
  }

  init(
    user: ApiUser,
    highlighted: Bool,
    rowHeight: CGFloat,
    rowInnerPadding: CGFloat,
    action: @escaping () -> Void
  ) {
    item = nil
    self.user = user
    self.highlighted = highlighted
    self.rowHeight = rowHeight
    self.rowInnerPadding = rowInnerPadding
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: QuickSearchLayout.iconTextSpacing) {
        if let item {
          switch item {
            case let .thread(threadInfo):
              ChatIcon(peer: .chat(threadInfo.chat), size: QuickSearchLayout.iconSize)
                .frame(
                  width: QuickSearchLayout.iconContainerSize,
                  height: QuickSearchLayout.iconContainerSize,
                  alignment: .center
                )
              HStack(spacing: QuickSearchLayout.itemTextSpacing) {
                Text(threadInfo.chat.title ?? "")
                  .lineLimit(1)
                if let spaceName = threadInfo.space?.name {
                  Text(spaceName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }

            case let .user(user):
              ChatIcon(peer: .user(UserInfo(user: user)), size: QuickSearchLayout.iconSize)
                .frame(
                  width: QuickSearchLayout.iconContainerSize,
                  height: QuickSearchLayout.iconContainerSize,
                  alignment: .center
                )
              HStack(spacing: QuickSearchLayout.itemTextSpacing) {
                Text(user.displayName)
                  .lineLimit(1)
                if let username = user.username {
                  Text("@\(username)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
          }
        } else if let user {
          UserAvatar(apiUser: user, size: QuickSearchLayout.iconSize)
            .frame(
              width: QuickSearchLayout.iconContainerSize,
              height: QuickSearchLayout.iconContainerSize,
              alignment: .center
            )
          HStack(spacing: QuickSearchLayout.itemTextSpacing) {
            Text(user.firstName ?? user.username ?? "")
              .lineLimit(1)
            if let username = user.username {
              Text("@\(username)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: rowHeight)
      .padding(.horizontal, rowInnerPadding)
      .background(
        RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
          .fill(backgroundColor)
      )
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .onHover { isHovered = $0 }
    }
    .buttonStyle(.plain)
  }

  private var backgroundColor: Color {
    if highlighted {
      return .primary.opacity(0.1)
    }
    if isHovered {
      return .primary.opacity(0.05)
    }
    return .clear
  }
}

private struct QuickSearchEmptyRow: View {
  let text: String
  let rowHeight: CGFloat
  let rowInnerPadding: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      Text(text)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(height: rowHeight)
    .padding(.horizontal, rowInnerPadding)
    .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
    .opacity(0.7)
    .allowsHitTesting(false)
  }
}

private struct QuickSearchLoadingRow: View {
  let rowHeight: CGFloat
  let rowInnerPadding: CGFloat

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
      Text("Searching…")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .frame(height: rowHeight)
    .padding(.horizontal, rowInnerPadding)
    .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
    .opacity(0.9)
    .allowsHitTesting(false)
  }
}
