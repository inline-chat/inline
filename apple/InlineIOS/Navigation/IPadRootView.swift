import InlineKit
import SwiftUI

/// The iPad container has no tabs and keeps selection in the existing router path.
@available(iOS 26.0, *)
struct IPadRootView<Sidebar: View>: View {
  @Binding var path: [Destination]
  let router: Router
  let tab: AppTab
  let nav: ExperimentalNavigationModel
  let onSelectSpace: (Int64) -> Void
  let onMigrateLegacySpaceDestination: (Int64) -> Void
  @ViewBuilder var sidebar: (Binding<Destination?>) -> Sidebar

  var body: some View {
    NavigationSplitView {
      sidebar(selection)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
    } detail: {
      IPadDetailView(
        path: $path,
        router: router,
        tab: tab,
        nav: nav,
        onSelectSpace: onSelectSpace,
        onMigrateLegacySpaceDestination: onMigrateLegacySpaceDestination
      )
    }
    .navigationSplitViewStyle(.balanced)
  }

  private var selection: Binding<Destination?> {
    Binding(
      get: {
        // Selection follows the page the person can currently see. Typed message
        // and Chat Info routes still project to their owning conversation row.
        IPadNavigationProjection.sidebarSelection(in: path) { destination in
          destination.sidebarPeer.map { .chat(peer: $0) }
        }
      },
      set: { destination in
        guard router.selectedTab == tab else { return }
        let replacement = IPadNavigationProjection.pathReplacingSelection(
          destination,
          currentPath: path,
          canonicalize: { destination in
            destination.sidebarPeer.map { .chat(peer: $0) } ?? destination
          }
        )
        if let replacement {
          path = replacement
        }
      }
    )
  }
}

@available(iOS 26.0, *)
private struct IPadDetailView: View {
  @Binding var path: [Destination]
  let router: Router
  let tab: AppTab
  let nav: ExperimentalNavigationModel
  let onSelectSpace: (Int64) -> Void
  let onMigrateLegacySpaceDestination: (Int64) -> Void

  var body: some View {
    let root = path.first

    NavigationStack(path: detailPath(root: root)) {
      IPadDetailPage(
        destination: root,
        isNested: false,
        router: router,
        nav: nav,
        onSelectSpace: onSelectSpace,
        onMigrateLegacySpaceDestination: onMigrateLegacySpaceDestination
      )
      .navigationDestination(for: Destination.self) { destination in
        IPadDetailPage(
          destination: destination,
          isNested: true,
          router: router,
          nav: nav,
          onSelectSpace: onSelectSpace,
          onMigrateLegacySpaceDestination: onMigrateLegacySpaceDestination
        )
      }
    }
    .id(root)
    .id(tab)
  }

  private func detailPath(root: Destination?) -> Binding<[Destination]> {
    Binding(
      get: { IPadNavigationProjection.detailPath(in: path) },
      set: { detailPath in
        // A replaced stack must not write its late pop back into a new selection.
        guard router.selectedTab == tab, path.first == root else { return }
        router.setPathFromNavigation(root.map { [$0] + detailPath } ?? [], for: tab)
      }
    )
  }
}

/// A toolbar belongs to the visible stack page, including every pushed destination.
/// Keeping it outside NavigationStack does not install it on a pushed page.
@available(iOS 26.0, *)
private struct IPadDetailPage: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let destination: Destination?
  let isNested: Bool
  let router: Router
  let nav: ExperimentalNavigationModel
  let onSelectSpace: (Int64) -> Void
  let onMigrateLegacySpaceDestination: (Int64) -> Void

  var body: some View {
    Group {
      if let destination {
        ExperimentalDestinationView(
          nav: nav,
          destination: destination,
          usesRouterNavigation: true,
          onSelectSpace: onSelectSpace,
          onMigrateLegacySpaceDestination: onMigrateLegacySpaceDestination
        )
      } else {
        IPadEmptyDetailView(spaceID: nav.activeSpaceId) { peer in
          router[IPadNavigationLane.canonicalTab] = [.chat(peer: peer)]
        }
      }
    }
    .voicePlaybackRootPill(router: router, destination: destination)
    .navigationBarBackButtonHidden(isNested)
    .toolbar {
      // A compact window collapses the split view and shows the system back button to
      // the sidebar. A second back chevron beside it read as a duplicate; history
      // navigation stays on the keyboard commands there.
      if horizontalSizeClass != .compact {
        ToolbarItemGroup(placement: .topBarLeading) {
          Button("Back", systemImage: "chevron.backward") { router.goBack() }
            .disabled(!router.canGoBack)
            .accessibilityIdentifier("iPadHistoryBack")
          Button("Forward", systemImage: "chevron.forward") { router.goForward() }
            .disabled(!router.canGoForward)
            .accessibilityIdentifier("iPadHistoryForward")
        }
      }
    }
  }
}

/// No chat selected: like the macOS empty page, the detail column is a place to start a
/// thread. The composer sits at the bottom where a chat's compose would be.
@available(iOS 26.0, *)
private struct IPadEmptyDetailView: View {
  let spaceID: Int64?
  let onCreated: (Peer) -> Void

  var body: some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 8) {
        Image(systemName: "bubble.left.and.text.bubble.right")
          .font(.system(size: 40, weight: .light))
          .foregroundStyle(.tertiary)
          .padding(.bottom, 4)
        Text("Start a Thread")
          .font(.title3.weight(.semibold))
        Text("Write the first message. It becomes a new thread in Home or the space you pick.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 320)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      NewThreadComposer(initialSpaceID: spaceID, onCreated: onCreated)
        .frame(maxWidth: 640)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
  }
}
