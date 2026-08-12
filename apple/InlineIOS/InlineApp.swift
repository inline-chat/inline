import Auth
import Foundation
import InlineKit
import Sentry
import SwiftUI

@main
struct InlineApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup {
      InlineRootView()
        .environment(\.auth, Auth.shared)
        .environment(\.realtime, Realtime.shared)
        .environment(\.transactions, Transactions.shared)
        .environment(appDelegate.router)
        .appDatabase(AppDatabase.shared)
        .environmentObject(appDelegate.notificationHandler)
        .environmentObject(appDelegate.nav)
        .environmentObject(INUserSettings.current.notification)
        .onOpenURL { url in
          if InlineDeepLink.isCurrentAppScheme(url.scheme),
             ConnectorOAuthCallback(url: url) != nil {
            appDelegate.router.presentedSheet = .connectors(callbackURL: url.absoluteString)
          } else {
            _ = appDelegate.handleDeepLink(url)
          }
        }
    }
  }
}
