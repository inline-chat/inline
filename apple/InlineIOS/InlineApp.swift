import InlineKit
import Sentry
import SwiftUI

@main
struct InlineApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @StateObject var ws = WebSocketManager()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(ws)
        .environment(\.auth, Auth.shared)
        .environment(\.transactions, Transactions.shared)
        .appDatabase(AppDatabase.shared)
        .environmentObject(appDelegate.notificationHandler)
        .environmentObject(appDelegate.nav)
    }
  }
}
