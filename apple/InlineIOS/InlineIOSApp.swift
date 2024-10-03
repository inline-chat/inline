//
//  InlineIOSApp.swift
//  InlineIOS
//
//  Created by Dena Sohrabi on 9/26/24.
//

import HeadlineKit
import SwiftUI

@main
struct InlineIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appDatabase, .shared)
        }
    }
}

extension EnvironmentValues {
    @Entry var appDatabase: AppDatabase = .empty()
}
