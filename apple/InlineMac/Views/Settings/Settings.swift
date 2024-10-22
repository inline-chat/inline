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
        .navigationTitle("Settings")
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Text("Welcome to Inline!").padding(40)
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject private var mainWindowViewModel: MainWindowViewModel

    var body: some View {
        Form {
            Button("Log Out", role: .destructive) {
                Auth.shared.logOut()
                try? AppDatabase.clearDB()
                mainWindowViewModel.navigate(.onboarding)

                if let window = NSApplication.shared.keyWindow {
                    window.close()
                }
            }
        }.padding(40)
    }
}

#Preview {
    SettingsView()
        .environmentObject(MainWindowViewModel())
}
