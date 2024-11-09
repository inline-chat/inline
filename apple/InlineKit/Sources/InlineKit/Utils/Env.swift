import SwiftUI

extension EnvironmentValues {
  @Entry public var appDatabase = AppDatabase.empty()
  @Entry public var auth = Auth.shared
}

extension View {
  public func appDatabase(_ appDatabase: AppDatabase) -> some View {
    self
      .environment(\.appDatabase, appDatabase)
      .databaseContext(.readWrite { appDatabase.dbWriter })
  }
}
