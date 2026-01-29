import SwiftUI

struct InlineRootView: View {
  @AppStorage("enableExperimentalView") private var enableExperimentalView = true
  @Environment(Router.self) private var router

  var body: some View {
    Group {
      if enableExperimentalView {
        ExperimentalRootView()
      } else {
        ContentView2()
      }
    }
    .onChange(of: enableExperimentalView) { _, _ in
      router.dismissSheet()
    }
  }
}

private struct ExperimentalRootView: View {
  @State private var showSettings = false
  @StateObject private var onboardingNavigation = OnboardingNavigation()
  @StateObject private var mainViewRouter = MainViewRouter()
  @StateObject private var fileUploadViewModel = FileUploadViewModel()

  var body: some View {
    NavigationStack {
      Text("")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              showSettings = true
            } label: {
              Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
          }
        }
    }
    .sheet(isPresented: $showSettings) {
      NavigationStack {
        SettingsView()
      }
    }
    .environmentObject(onboardingNavigation)
    .environmentObject(mainViewRouter)
    .environmentObject(fileUploadViewModel)
  }
}
