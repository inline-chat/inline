import InlineKit
import InlineUI
import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: Tabs = .general
    @Environment(\.auth) var auth
    
    enum Tabs: String, CaseIterable, Identifiable {
        case general = "General"
        case account = "Account"
        
        var id: String { self.rawValue }
    }
    
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem {
                Label("General", systemImage: "gear")
            }
            .tag(Tabs.general)
            
            // Logged in only options
            if self.auth.isLoggedIn {
                AccountSettingsView().tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
                .tag(Tabs.account)
            }
        }
        .scenePadding()
        .navigationTitle("Settings")
    }
}

struct GeneralSettingsView: View {
    @State var launchAtLogin: Bool = false
    
    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: self.$launchAtLogin)
        }
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject private var mainWindowViewModel: MainWindowViewModel
    @EnvironmentObject private var ws: WebSocketManager
    @EnvironmentStateObject private var root: RootData
    @Environment(\.logOut) private var logOut
    
    init() {
        _root = EnvironmentStateObject { env in
            RootData(db: env.appDatabase, auth: env.auth)
        }
    }
        
    var body: some View {
        HStack {
            UserProfile()
            Button("Log Out", role: .destructive) {
                self.logOut()
            }
        }
        .frame(minWidth: 300)
        .environmentObject(self.root)
    }
        
    struct UserProfile: View {
        @EnvironmentObject private var root: RootData

        var body: some View {
            if let user = root.currentUser {
                HStack {
                    UserAvatar(user: user, size: 32)
                    
                    VStack(alignment: .leading) {
                        Text(user.fullName)
                            .font(.body)
                        Text(user.email ?? user.username ?? "")
                            .font(.footnote)
                    }
                }.padding(.trailing)
            }
        }
    }
}
    
#Preview {
    SettingsView()
        .previewsEnvironment(.populated)
        .environmentObject(MainWindowViewModel())
}
