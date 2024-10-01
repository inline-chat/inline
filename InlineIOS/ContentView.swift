//
//  ContentView.swift
//  InlineIOS
//
//  Created by Dena Sohrabi on 9/26/24.
//

import HeadlineKit
import SwiftUI

struct ContentView: View {
    @StateObject private var nav = Navigation()
    @StateObject var api = ApiClient()
    
    var body: some View {
        NavigationStack(path: $nav.path) {
            Welcome()
                .navigationDestination(for: Navigation.Destination.self) { destination in
                    switch destination {
                    case .welcome:
                        Welcome()
                    case let .email(prevEmail):
                        Email(prevEmail: prevEmail)
                    case let .code(email):
                        Code(email: email)
                    }
                }
        }
        .environmentObject(nav)
        .environmentObject(api)
        .onAppear{
            print("HEY")
        }
    }
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "en"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "ar"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "zh-CN"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "zh-TW"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "fr"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "de"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "it"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "ja"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "ko"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "fa"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "pl"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "ru"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "es"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "tr"))
}

#Preview {
    ContentView()
        .environment(\.locale, .init(identifier: "vi"))
}
