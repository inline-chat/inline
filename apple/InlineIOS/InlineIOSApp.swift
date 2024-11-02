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
struct InlineIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var ws = WebSocketManager()

    init() {
        SentrySDK.start { options in
            options.dsn = "https://1bd867ae25150dd18dad6100789649fd@o124360.ingest.us.sentry.io/4508058293633024"
//            options.debug = true

            // Enable tracing to capture 100% of transactions for tracing.
            // Use 'options.tracesSampleRate' to set the sampling rate.
            // We recommend setting a sample rate in production.
            options.enableTracing = true
            options.attachViewHierarchy = true
            options.enableMetricKit = true
            options.enableTimeToFullDisplayTracing = true
            options.swiftAsyncStacktraces = true
            options.enableAppLaunchProfiling = true
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(self.ws)
                .environment(\.auth, Auth.shared)
                .appDatabase(AppDatabase.shared)
        }
    }
}

// MARK: - Give SwiftUI access to the database

extension EnvironmentValues {
    @Entry var appDatabase = AppDatabase.empty()
    @Entry var auth = Auth.shared
}

extension View {
    func appDatabase(_ appDatabase: AppDatabase) -> some View {
        self
            .environment(\.appDatabase, appDatabase)
            .databaseContext(.readWrite { appDatabase.dbWriter })
    }
}
