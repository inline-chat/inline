import Foundation
import InlineKit

class DataManager: ObservableObject, @unchecked Sendable {
    private var database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func createSpace(name: String) async throws -> Int64? {
        do {
            let result = try await ApiClient.shared.createSpace(name: name)

            try await database.dbWriter.write { db in
                let space = Space(from: result.space)
                try space.save(db)

                let member = Member(createdAt: Date.now, userId: Auth.shared.getCurrentUserId()!, spaceId: result.space.id)
                try member.save(db)
            }
            return result.space.id
        } catch {
            Log.shared.error("Failed to create space", error: error)
        }
        return nil
    }
}
