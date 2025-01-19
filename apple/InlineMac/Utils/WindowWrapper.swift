
import InlineKit
import SwiftUI

// Injects authenticated models into environemnt
struct AuthenticatedWindowWrapper<Content: View>: View {
  // Fetch authenticated user data
  @EnvironmentStateObject var rootData: RootData
  @EnvironmentStateObject var dataManager: DataManager

  init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
    _rootData = EnvironmentStateObject { env in
      RootData(db: env.appDatabase, auth: env.auth)
    }
    _dataManager = EnvironmentStateObject { env in
      DataManager(database: env.appDatabase)
    }
  }

  var content: () -> Content

  var body: some View {
    content()
      .environmentObject(rootData)
      .environmentObject(dataManager)
  }
}
