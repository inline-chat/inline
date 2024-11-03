import SwiftUI

public extension EnvironmentValues {
    @Entry var appDatabase = AppDatabase.empty()
    @Entry var auth = Auth.shared
}

extension View {
    public func appDatabase(_ appDatabase: AppDatabase) -> some View {
        self
            .environment(\.appDatabase, appDatabase)
            .databaseContext(.readWrite { appDatabase.dbWriter })
    }
}
