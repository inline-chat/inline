import GRDB
import SwiftUI

public enum PreviewsEnvironemntPreset {
    case empty
    case populated
    case unauthenticated
}

extension View {
    public func previewsEnvironment(_ preset: PreviewsEnvironemntPreset) -> some View {
        let appDatabase: AppDatabase = if preset == .populated {
            .populated()
        } else {
            .empty()
        }
        
        let auth = Auth.mocked(authenticated: preset != .unauthenticated)

        return self
            .environment(\.appDatabase, appDatabase)
            .databaseContext(.readWrite { appDatabase.dbWriter })
            .environmentObject(WebSocketManager(token: nil, userId: nil))
            .environmentObject(RootData(db: appDatabase, auth: auth))
//            .environmentObject(MainWindowViewModel())
            .environment(\.auth, auth)
    }
}
