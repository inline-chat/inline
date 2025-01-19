import GRDB
import GRDBQuery
import InlineKit
import Sentry
import SwiftUI

@main
struct InlineApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @StateObject var viewModel = MainWindowViewModel()
  @StateObject var ws = WebSocketManager()
  @StateObject var navigation: NavigationModel = .shared
  @StateObject var auth = Auth.shared
  @StateObject var overlay = OverlayManager()
  
  @Environment(\.openWindow) var openWindow
  
  init() {
    UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
  }

  var body: some Scene {
    // Note(@mo): Using Window here messes up with our title bar handling upon window re-open after close
    WindowGroup("main") {
      MainWindow()
        .environmentObject(self.ws)
        .environmentObject(self.viewModel)
        .environmentObject(self.navigation)
        .environment(\.auth, auth)
        .appDatabase(AppDatabase.shared)
        .environmentObject(overlay)
        .environment(\.logOut, logOut)
        .environment(\.transactions, Transactions.shared)
        .environment(
          \.requestNotifications,
          appDelegate.notifications.requestNotifications
        )
    }
    .defaultSize(width: 900, height: 600)
    .windowStyle(
      viewModel.topLevelRoute == .onboarding ? .hiddenTitleBar : .init()
    )
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      MainWindowCommands(
        isLoggedIn: auth.isLoggedIn,
        navigation: navigation,
        logOut: logOut
      )
    }
    
    // Chat single window
    WindowGroup(for: Peer.self) { $peerId in
      AuthenticatedWindowWrapper {
        if let peerId = peerId {
          ChatView(peerId: peerId)
        } else {
          Text("No chat selected.")
        }
      }
      .environmentObject(self.ws)
      .environmentObject(self.viewModel)
      .environmentObject(overlay)
      .environment(\.auth, Auth.shared)
      .environment(\.logOut, logOut)
      .appDatabase(AppDatabase.shared)
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .defaultSize(width: 680, height: 600)
    
    Settings {
      SettingsView()
        .environmentObject(self.ws)
        .environmentObject(self.viewModel)
        .environment(\.auth, Auth.shared)
        .environment(\.logOut, logOut)
        .appDatabase(AppDatabase.shared)
        .environmentObject(overlay)
    }
  }
  
  // Resets all state and data
  func logOut() {
    // Clear creds
    Auth.shared.logOut()
    
    // Stop WebSocket
    ws.loggedOut()
    
    // Clear database
    try? AppDatabase.loggedOut()
    
    // Navigate outside of the app
    viewModel.navigate(.onboarding)
    
    // Reset internal navigation
    navigation.reset()
    
    // Close Settings
    if let window = NSApplication.shared.keyWindow {
      window.close()
    }
  }
  
  // -----
}

public extension EnvironmentValues {
  @Entry var logOut: () -> Void = {}
}
