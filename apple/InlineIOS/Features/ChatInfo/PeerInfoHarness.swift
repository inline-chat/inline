#if DEBUG
import InlineKit
import SwiftUI

/// Debug builds only: `--peerinfo-harness` lists every kind of chat info on an
/// in-memory database, signed in as a fixture user, with nothing sent to the
/// server. `--peerinfo-harness-case ID` opens one case directly (see
/// `PeerInfoDebugFixture.cases`), the way the chat opens it: a sheet.
struct PeerInfoHarnessRootView: View {
  static var isRequested: Bool { PeerInfoDebugFixture.isRequested }

  @State private var router = Router(initialTab: .allChats, persistence: .externallyManaged, restoresPersistedState: false)
  @StateObject private var nav = Navigation()
  @State private var presented: SpaceChatItem?
  @State private var didSeed = false

  /// A case named at launch renders as the root, so captures never race a sheet.
  @State private var launchItem: SpaceChatItem?
  @State private var launchFailure: String?

  var body: some View {
    if let launchItem {
      NavigationStack {
        ChatInfoView(chatItem: launchItem, isPresentedModally: true)
      }
      .environment(router)
      .environmentObject(nav)
    } else {
      list
    }
  }

  private var list: some View {
    NavigationStack {
      List(PeerInfoDebugFixture.cases) { item in
        Button(item.title) { open(item.peer) }
          .accessibilityIdentifier("peerinfo-\(item.id)")
      }
      .navigationTitle("Chat Info Harness")
      .safeAreaInset(edge: .top) {
        if let launchFailure { Text(launchFailure).font(.footnote).foregroundStyle(.red) }
      }
    }
    .sheet(item: $presented) { item in
      NavigationStack {
        ChatInfoView(chatItem: item, isPresentedModally: true)
      }
      .environment(router)
      .environmentObject(nav)
    }
    .environment(router)
    .environmentObject(nav)
    .task {
      guard !didSeed else { return }
      didSeed = true
      PeerInfoDebugFixture.seed()
      PeerInfoDebugFixture.seedAgents()
      if let id = TimelineHarnessRootView.argument("--peerinfo-harness-case"),
         let item = PeerInfoDebugFixture.cases.first(where: { $0.id == id })
      {
        launchItem = FullChatViewModel.cachedChatItem(peer: item.peer)
        if launchItem == nil { launchFailure = "No local chat for \(id)" }
      }
    }
  }

  private func open(_ peer: Peer) {
    presented = FullChatViewModel.cachedChatItem(peer: peer)
  }
}
#endif
