import AppKit
import Auth
import InlineKit
import InlineMacUI
import Logger
import SwiftUI

struct EmptyRouteView: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.nav) private var nav
  @Environment(SidebarViewModel.self) private var sidebar
  @ObservedObject private var auth = Auth.shared

  var body: some View {
    @Bindable var nav = nav

    ZStack {
      if let userID = auth.currentUserId {
        EmptyRouteCenterContent(
          userID: userID,
          openCommandBar: { nav.openCommandBar() },
          perform: perform
        )
        .id(userID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        EmptyRouteLogoButton {
          nav.openCommandBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if #available(macOS 26.0, *), let dependencies {
        AllChatsNewThreadComposeHost(
          dependencies: dependencies,
          spaces: composeSpaces,
          selectedSpaceID: nav.selectedSpaceId,
          placement: .bottom,
          focusRequested: $nav.newThreadComposeFocusRequested
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .routeContentBackground(.translucentPage)
    .emptyRouteWindowDragArea()
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
  }

  private var composeSpaces: [AllChatsComposeSpace] {
    sidebar.spaces
      .map { AllChatsComposeSpace(id: $0.id, title: $0.displayName) }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  @MainActor
  private func perform(_ action: GettingStartedAction) async {
    switch action {
    case .setUpAgent:
      guard let dependencies else {
        ToastCenter.shared.showError("Couldn’t open Agent Setup. Please try again.")
        return
      }
      AgentSetupWindowController.show(using: dependencies)

    case .inviteFriend:
      nav.beginInvite(spaceId: nil)

    case .createSpace:
      nav.open(.createSpace)

    case .installTools:
      guard let url = URL(string: "https://inline.chat/docs/add-inline") else { return }
      if NSWorkspace.shared.open(url) == false {
        ToastCenter.shared.showError("Couldn’t open the Inline setup guide. Please try again.")
      }

    case .messageFounder:
      guard let dependencies else {
        ToastCenter.shared.showError("Couldn’t start a DM with @mo. Please try again.")
        return
      }
      do {
        try await GettingStartedActions.openFounderDM(using: dependencies)
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to open getting-started founder DM", error: error)
        ToastCenter.shared.showError("Couldn’t start a DM with @mo. Please try again.")
      }

    case .joinCommunity:
      guard let dependencies else {
        ToastCenter.shared.showError("Couldn’t join the Inline community. Please try again.")
        return
      }
      do {
        let spaceID = try await GettingStartedActions.joinCommunity(using: dependencies)
        nav.selectSpace(spaceID)
      } catch is CancellationError {
        return
      } catch {
        Log.shared.error("Failed to join getting-started community", error: error)
        ToastCenter.shared.showError("Couldn’t join the Inline community. Please try again.")
      }
    }
  }
}

private struct EmptyRouteCenterContent: View {
  let userID: Int64
  let openCommandBar: () -> Void
  let perform: @MainActor (GettingStartedAction) async -> Void

  @AppStorage private var showsGettingStarted: Bool
  @State private var dismissedForcedPreview = false

  init(
    userID: Int64,
    openCommandBar: @escaping () -> Void,
    perform: @escaping @MainActor (GettingStartedAction) async -> Void
  ) {
    self.userID = userID
    self.openCommandBar = openCommandBar
    self.perform = perform
    _showsGettingStarted = AppStorage(
      wrappedValue: false,
      GettingStartedVisibility.preferenceKey(for: userID)
    )
  }

  var body: some View {
    ZStack {
      if shouldShowGettingStarted {
        GettingStartedView(
          dismiss: dismiss,
          openCommandBar: openCommandBar,
          perform: perform
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
      } else {
        EmptyRouteLogoButton(action: openCommandBar)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var shouldShowGettingStarted: Bool {
    showsGettingStarted || (GettingStartedPreview.isForced && !dismissedForcedPreview)
  }

  private func dismiss() {
    GettingStartedVisibility.dismiss(for: userID)
    withAnimation(.easeOut(duration: 0.2)) {
      dismissedForcedPreview = true
      showsGettingStarted = false
    }
  }
}

private struct EmptyRouteLogoButton: View {
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  private let size: CGFloat = 44

  var body: some View {
    Image("InlineLogoSymbol")
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .offset(y: -(size / 2)) // half the height
      .opacity(isHovered ? 0.112 : 0.07)
      .blendMode(blendMode)
      .contentShape(Rectangle())
      .onHover { hovering in
        withAnimation(.easeOut(duration: 0.3)) {
          isHovered = hovering
        }
      }
      .simultaneousGesture(WindowDragGesture())
      .onTapGesture(perform: action)
      .help("Open search")
      .accessibilityElement()
      .accessibilityLabel("Open search")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        action()
      }
  }

  private var blendMode: BlendMode {
    colorScheme == .dark ? .screen : .multiply
  }
}

private extension View {
  func emptyRouteWindowDragArea() -> some View {
    background {
      Color.clear
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
      }
  }
}
