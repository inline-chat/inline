import GRDB
import SwiftUI
import Auth

public enum PreviewsEnvironemntPreset {
  case empty
  case populated
  case unauthenticated
}

public extension View {
  func previewsEnvironment(_ preset: PreviewsEnvironemntPreset) -> some View {
    let appDatabase: AppDatabase =
      if preset == .populated {
        .populated()
      } else {
        .empty()
      }

    let auth = Auth.mocked(authenticated: preset != .unauthenticated)

    return
      environment(\.transactions, Transactions.shared)
        .environment(\.appDatabase, appDatabase)
        .databaseContext(.readWrite { appDatabase.dbWriter })
        .environmentObject(RootData(db: appDatabase, auth: auth))
        .environmentObject(DataManager(database: appDatabase))
        .environment(\.auth, auth)
  }
}
