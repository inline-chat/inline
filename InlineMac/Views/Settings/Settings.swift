import InlineKit
import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: Tabs = .general

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

            AccountSettingsView().tabItem {
                Label("Account", systemImage: "person.crop.circle")
            }
            .tag(Tabs.account)
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

    var body: some View {
        HStack {
            UserProfile()
            Form {
                Button("Log Out", role: .destructive) {
                    // TODO: Extract to toplevel
                    // Clear creds
                    Auth.shared.logOut()

                    // Stop WebSocket
                    ws.loggedOut()

                    // Clear database
                    try? AppDatabase.loggedOut()

                    // Navigate outside of the app
                    self.mainWindowViewModel.navigate(.onboarding)

                    // Close Settings
                    if let window = NSApplication.shared.keyWindow {
                        window.close()
                    }
                }
            }.padding(40)
        }
    }

    struct UserProfile: View {
        var body: some View {
            HStack {
                //                TODO: Initials
                Circle()
                    .foregroundStyle(.orange)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading) {
                    Text("Mo")
                        .font(.body)
                    Text("mo@inline.chat")
                        .font(.footnote)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(MainWindowViewModel())
}
