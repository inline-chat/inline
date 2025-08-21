import Auth
import Logger
import RealtimeV2
import SwiftUI

public extension EnvironmentValues {
  @Entry var appDatabase = AppDatabase.empty()
  @Entry var auth = Auth.shared
  @Entry var transactions = Transactions.shared
  @Entry var realtime = Realtime.shared
  @Entry var realtimeV2 = RealtimeV2.shared
}

public extension View {
  func appDatabase(_ appDatabase: AppDatabase) -> some View {
    environment(\.appDatabase, appDatabase)
      .databaseContext(.readWrite { appDatabase.dbWriter })
  }
}
