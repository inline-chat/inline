import AppKit
import Combine
import SwiftUI

final class MainSidebarSearchView: NSView {
  private let dependencies: AppDependencies
  private let state = MainSidebarSearchState()
  private let listView: MainSidebarList
  private let placeholderView = MainSidebarSearchPlaceholderView()
  private var cancellables = Set<AnyCancellable>()

  private var lastResultCount: Int = 0
  private var arrowKeyUnsubscriber: (() -> Void)?
  private var vimKeyUnsubscriber: (() -> Void)?
  private var escapeKeyUnsubscriber: (() -> Void)?

  var onExitToInbox: (() -> Void)?

  private lazy var searchBarHostingView: NSHostingView<MainSidebarSearchBarView> = {
    let hostingView = NSHostingView(
      rootView: MainSidebarSearchBarView(
        state: state,
        onSubmit: { [weak self] in
          self?.handleSubmit()
        }
      )
    )
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.setContentHuggingPriority(.required, for: .vertical)
    return hostingView
  }()

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    listView = MainSidebarList(dependencies: dependencies)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupViews()
    setupBindings()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    unsubscribeKeyHandlers()
  }

  private func setupViews() {
    addSubview(searchBarHostingView)
    addSubview(listView)
    addSubview(placeholderView)

    NSLayoutConstraint.activate([
      searchBarHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      searchBarHostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      searchBarHostingView.topAnchor.constraint(equalTo: topAnchor),

      listView.leadingAnchor.constraint(equalTo: leadingAnchor),
      listView.trailingAnchor.constraint(equalTo: trailingAnchor),
      listView.topAnchor.constraint(equalTo: searchBarHostingView.bottomAnchor),
      listView.bottomAnchor.constraint(equalTo: bottomAnchor),

      placeholderView.centerXAnchor.constraint(equalTo: centerXAnchor),
      placeholderView.centerYAnchor.constraint(equalTo: listView.centerYAnchor),
      placeholderView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      placeholderView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
    ])

    placeholderView.isHidden = false
  }

  private func setupBindings() {
    listView.onChatCountChanged = { [weak self] mode, count in
      guard mode == .search else { return }
      self?.lastResultCount = count
      self?.updatePlaceholder()
    }

    listView.setMode(.search)

    state.$query
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] query in
        self?.listView.setSearchQuery(query)
        self?.updatePlaceholder()
      }
      .store(in: &cancellables)

    updatePlaceholder()
  }

  private func updatePlaceholder() {
    let trimmed = state.query.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.isEmpty {
      placeholderView.update(
        symbolName: "magnifyingglass",
        text: "Search chats and members"
      )
      placeholderView.isHidden = false
      return
    }

    if lastResultCount == 0 {
      placeholderView.update(
        symbolName: "x.circle",
        text: "No results found"
      )
      placeholderView.isHidden = false
    } else {
      placeholderView.isHidden = true
    }
  }

  func setActive(_ active: Bool) {
    if active {
      focusSearchField()
      subscribeKeyHandlers()
    } else {
      unsubscribeKeyHandlers()
    }
  }

  func reset() {
    state.query = ""
    listView.clearSelection()
    lastResultCount = 0
    updatePlaceholder()
  }

  func focusSearchField() {
    state.requestFocus()
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      if let textField = self.searchBarHostingView.firstTextField() {
        window.makeFirstResponder(textField)
      }
    }
  }

  private func subscribeKeyHandlers() {
    guard arrowKeyUnsubscriber == nil else { return }
    guard let keyMonitor = dependencies.keyMonitor else { return }

    escapeKeyUnsubscriber = keyMonitor.addHandler(for: .escape, key: "main_sidebar_search_escape") { [weak self] _ in
      self?.exitToInbox()
    }

    arrowKeyUnsubscriber = keyMonitor.addHandler(for: .arrowKeys, key: "main_sidebar_search_arrows") { [weak self] event in
      guard let self else { return }
      switch event.keyCode {
        case 126: // Up arrow
          self.listView.selectPreviousResult()
        case 125: // Down arrow
          self.listView.selectNextResult()
        default:
          break
      }
    }

    vimKeyUnsubscriber = keyMonitor.addHandler(for: .vimNavigation, key: "main_sidebar_search_vim") { [weak self] event in
      guard let self else { return }
      guard let char = event.charactersIgnoringModifiers?.lowercased() else { return }
      switch char {
        case "k", "p":
          self.listView.selectPreviousResult()
        case "j", "n":
          self.listView.selectNextResult()
        default:
          break
      }
    }
  }

  private func unsubscribeKeyHandlers() {
    escapeKeyUnsubscriber?()
    escapeKeyUnsubscriber = nil
    arrowKeyUnsubscriber?()
    arrowKeyUnsubscriber = nil
    vimKeyUnsubscriber?()
    vimKeyUnsubscriber = nil
  }

  private func handleSubmit() {
    let didNavigate = listView.activateSelection()
    if didNavigate {
      exitToInbox()
    }
  }

  private func exitToInbox() {
    reset()
    onExitToInbox?()
  }
}

final class MainSidebarSearchState: ObservableObject {
  @Published var query: String = ""
  @Published var focusToken: UUID = UUID()

  func requestFocus() {
    focusToken = UUID()
  }
}

private struct MainSidebarSearchBarView: View {
  @ObservedObject var state: MainSidebarSearchState
  let onSubmit: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    SidebarSearchBar(text: $state.query, isFocused: isFocused)
      .padding(.horizontal, MainSidebar.edgeInsets)
      .padding(.top, MainSidebar.outerEdgeInsets)
      .padding(.bottom, 8)
      .focused($isFocused)
      .onSubmit(onSubmit)
      .onAppear {
        isFocused = true
      }
      .onChange(of: state.focusToken) { _ in
        isFocused = true
      }
  }
}

private final class MainSidebarSearchPlaceholderView: NSView {
  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    setupView()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    let stack = NSStackView(views: [iconView, label])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    iconView.contentTintColor = .tertiaryLabelColor
    label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    label.textColor = .tertiaryLabelColor
    label.alignment = .center
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byWordWrapping
  }

  func update(symbolName: String, text: String) {
    let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
    iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    label.stringValue = text
  }
}

private extension NSView {
  func firstTextField() -> NSTextField? {
    if let textField = self as? NSTextField {
      return textField
    }

    for subview in subviews {
      if let match = subview.firstTextField() {
        return match
      }
    }

    return nil
  }
}
