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
    var body: some View {
        NavigationStack(path: $nav.path) {
            VStack {
                if Auth.shared.getToken() != nil {
                    MainView()
                }
                else {
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
                case let .addAccount(email):
                    AddAccount(email: email)
                case let .space(id):
                    SpaceView(spaceId: id)
                }
            }
        }
        .environmentObject(nav)
        .environmentObject(api)
        .environmentObject(userData)
    }
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "en"))
}
