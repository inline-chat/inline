import InlineKit
import SwiftUI

struct InlineRootView: View {
  @AppStorage("enableExperimentalView") private var enableExperimentalView = false
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
  @AppStorage("enableExperimentalView") private var enableExperimentalView = false
  @State private var showSettings = false
  @StateObject private var onboardingNavigation = OnboardingNavigation()
  @StateObject private var mainViewRouter = MainViewRouter()
  @StateObject private var fileUploadViewModel = FileUploadViewModel()
  @EnvironmentStateObject private var compactSpaceList: CompactSpaceList

  init() {
    _compactSpaceList = EnvironmentStateObject { env in
      CompactSpaceList(db: env.appDatabase)
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        Text("WIP")
          .font(.title2)
          .fontWeight(.semibold)

        Button("Return to previous UI") {
          enableExperimentalView = false
        }
        .buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .toolbar {
          ToolbarItem(placement: .principal) {
            SpacePickerMenu()
          }
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
    .environmentObject(compactSpaceList)
  }
}
