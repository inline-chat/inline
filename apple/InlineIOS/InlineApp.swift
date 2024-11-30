//
//  InlineIOSApp.swift
//  InlineIOS
//
//  Created by Dena Sohrabi on 9/26/24.
//

import AVFAudio
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
        .environmentObject(self.ws)
        .environment(\.auth, Auth.shared)
        .appDatabase(AppDatabase.shared)
        .environmentObject(appDelegate.notificationHandler)
        .environmentObject(appDelegate.nav)
    }
  }
}
