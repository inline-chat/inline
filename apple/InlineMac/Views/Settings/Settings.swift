import InlineKit
import SwiftUI

struct SettingsView: View {
    //    @AppStorage("showPreview") private var showPreview = true
    //    @AppStorage("fontSize") private var fontSize = 12.0

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

    var body: some View {
        HStack {
            UserProfile()
            Form {
                Button("Log Out", role: .destructive) {
                    Auth.shared.logOut()
                    try? AppDatabase.loggedOut()
                    self.mainWindowViewModel.navigate(.onboarding)

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
