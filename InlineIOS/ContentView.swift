//
//  ContentView.swift
//  InlineIOS
//
//  Created by Dena Sohrabi on 9/26/24.
//

import InlineKit
import SwiftUI

struct ContentView: View {
    @StateObject private var nav = Navigation()
    @StateObject var api = ApiClient()
    @StateObject var userData = UserData()
    @Environment(\.appDatabase) var database
    @EnvironmentStateObject var dataManager: DataManager

    init() {
        _dataManager = EnvironmentStateObject { env in
            DataManager(database: env.appDatabase)
        }
    }

    var body: some View {
        NavigationStack(path: $nav.path) {
            VStack {
                if Auth.shared.isLoggedIn {
                    MainView()
                } else {
                    Welcome()
                }
            }
            .navigationDestination(for: Navigation.Destination.self) { destination in
                switch destination {
                case .welcome:
                    Welcome()
                case let .email(prevEmail):
                    Email(prevEmail: prevEmail)
                case let .code(email):
                    Code(email: email)
                case .main:
                    MainView()
                case .addAccount:
                    AddAccount()
                case let .space(id):
                    SpaceView(spaceId: id)
                case let .chat(id):
                    ChatView(chatId: id)
                }
            }
        }
        .environmentObject(nav)
        .environmentObject(api)
        .environmentObject(userData)
        .environmentObject(dataManager)
    }
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "en"))
}
