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
        ContentUnavailableView("Select a Chat", systemImage: "bubble.left.and.bubble.right")
      }
    }
    .navigationBarBackButtonHidden(isNested)
    .toolbar {
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
