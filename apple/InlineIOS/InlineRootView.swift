import InlineKit
import SwiftUI

struct InlineRootView: View {
  @AppStorage(ExperimentalHomePreferenceKeys.isEnabled)
  private var enableExperimentalView = true
  @AppStorage(ExperimentalHomePreferenceKeys.defaultMigrationVersion)
  private var defaultMigrationVersion = 0
  @AppStorage(ExperimentalHomePreferenceKeys.forceLegacyRollback)
  private var forceLegacyRollback = false
  @Environment(Router.self) private var router

  var body: some View {
    Group {
      if usesNewHome {
        ExperimentalRootView()
      } else {
        ContentView2()
      }
    }
    .onChange(of: enableExperimentalView) { _, _ in
      router.dismissSheet()
    }
    .onAppear {
      promoteNewHomeIfNeeded()
    }
  }

  private var usesNewHome: Bool {
    guard !forceLegacyRollback else { return false }
    return enableExperimentalView
      || defaultMigrationVersion < ExperimentalHomeRollout.currentDefaultMigrationVersion
  }

  private func promoteNewHomeIfNeeded() {
    guard defaultMigrationVersion < ExperimentalHomeRollout.currentDefaultMigrationVersion else { return }
    enableExperimentalView = true
    defaultMigrationVersion = ExperimentalHomeRollout.currentDefaultMigrationVersion
  }
}
