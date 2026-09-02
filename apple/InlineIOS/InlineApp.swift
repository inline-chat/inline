import Auth
import Foundation
import InlineKit
import Sentry
import SwiftUI
import UIKit

@main
struct InlineApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  init() {
    InlineShortcuts.registerNavigation(routerRegistry: appDelegate.sceneRouterRegistry)
    InlineShortcuts.updateAppShortcutParameters()
  }

  var body: some Scene {
    WindowGroup {
      InlineSceneRoot(appDelegate: appDelegate)
    }
  }
}

private struct InlineSceneRoot: View {
  private static let sceneMigrationKey = "ios.navigation.didMigrateToSceneStorage.v1"

  @ObservedObject private var appDelegate: AppDelegate

  @State private var router: Router
  @StateObject private var themeManager = ThemeManager.shared
  @State private var sceneID = UUID()
  @State private var didRestoreScene = false
  @ObservedObject private var auth = Auth.shared
  @SceneStorage("ios.navigation.routerState.v1") private var routerState: Data?
  @Environment(\.scenePhase) private var scenePhase

  init(appDelegate: AppDelegate) {
    _appDelegate = ObservedObject(wrappedValue: appDelegate)
    let shouldRestoreLegacyState = !UserDefaults.standard.bool(forKey: Self.sceneMigrationKey)
    _router = State(initialValue: Router(
      initialTab: .allChats,
      persistence: .externallyManaged,
      restoresPersistedState: shouldRestoreLegacyState
    ))
  }

  var body: some View {
    InlineRootView()
      .background(SceneNotificationWindowProbe { window in
        appDelegate.sceneRouterRegistry.attachWindow(window, sceneID: sceneID)
      })
      .environment(\.auth, Auth.shared)
      .environment(\.realtime, Realtime.shared)
      .environment(\.transactions, Transactions.shared)
      .environment(router)
      .environmentObject(themeManager)
      .appDatabase(AppDatabase.shared)
      .environmentObject(appDelegate.notificationHandler)
      .environmentObject(appDelegate.nav)
      .environmentObject(INUserSettings.current.notification)
      .onOpenURL { url in
        if ProviderSignInCoordinator.shared.canHandle(url) {
          Task { await ProviderSignInCoordinator.shared.handleCallback(url) }
        } else if InlineDeepLink.isCurrentAppScheme(url.scheme),
           ConnectorOAuthCallback(url: url) != nil {
          router.presentedSheet = .connectors(callbackURL: url.absoluteString)
        } else {
          _ = appDelegate.handleDeepLink(url, router: router)
        }
      }
      .onAppear {
        restoreSceneIfNeeded()
        appDelegate.sceneRouterRegistry.register(
          router,
          sceneID: sceneID,
          isActive: scenePhase == .active,
          accountUserID: auth.currentUserId
        )
        synchronizeUserSettings()
      }
      .onDisappear {
        appDelegate.sceneRouterRegistry.unregister(sceneID)
      }
      .onChange(of: scenePhase) { _, newValue in
        if newValue == .active {
          appDelegate.sceneRouterRegistry.activate(sceneID)
          synchronizeUserSettings()
        } else {
          appDelegate.sceneRouterRegistry.deactivate(sceneID)
        }
      }
      .onChange(of: auth.currentUserId) { oldValue, newValue in
        appDelegate.sceneRouterRegistry.accountDidChange(from: oldValue, to: newValue)
        if newValue != nil {
          appDelegate.resumePendingSpaceJoin(router: router)
        }
      }
      .onChange(of: router.persistenceRevision) { _, _ in
        guard didRestoreScene else { return }
        routerState = router.encodedPersistentState()
      }
      .alert(
        "Couldn’t join space",
        isPresented: Binding(
          get: { appDelegate.spaceJoinErrorMessage != nil },
          set: { presented in
            if !presented { appDelegate.dismissSpaceJoinError() }
          }
        )
      ) {
        Button("OK", role: .cancel) {
          appDelegate.dismissSpaceJoinError()
        }
      } message: {
        Text(appDelegate.spaceJoinErrorMessage ?? "")
      }
  }

  private func restoreSceneIfNeeded() {
    guard !didRestoreScene else { return }
    didRestoreScene = true
    if let routerState {
      _ = router.restorePersistentState(from: routerState)
    }
    routerState = router.encodedPersistentState()
    UserDefaults.standard.set(true, forKey: Self.sceneMigrationKey)
  }

  private func synchronizeUserSettings() {
    guard scenePhase == .active else { return }

    Task {
      await INUserSettings.current.refresh(reason: .authenticatedScene)
    }
  }
}

/// Reads the actual scene's presentation tree, including chat-owned sheets.
private struct SceneNotificationWindowProbe: UIViewRepresentable {
  let onWindowChange: (UIWindow?) -> Void

  func makeUIView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.isUserInteractionEnabled = false
    view.onWindowChange = onWindowChange
    return view
  }

  func updateUIView(_ view: ProbeView, context: Context) {
    view.onWindowChange = onWindowChange
    onWindowChange(view.window)
  }

  final class ProbeView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      onWindowChange?(window)
    }
  }
}
