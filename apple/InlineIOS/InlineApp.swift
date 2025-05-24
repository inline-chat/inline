import Auth
import InlineKit
import Sentry
import SwiftUI

@main
struct InlineApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(\.auth, Auth.shared)
        .environment(\.realtime, Realtime.shared)
        .environment(\.transactions, Transactions.shared)
        .appDatabase(AppDatabase.shared)
        .environmentObject(appDelegate.notificationHandler)
        .environmentObject(appDelegate.nav)
        .environmentObject(INUserSettings.current.notification)
    }
  }
}
