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
            if case let .success(result) = result {
                try await database.dbWriter.write { db in

                    let space = Space(from: result.space)
                    try space.save(db)

                    // Add our user as first member
                    let member = Member(createdAt: Date.now, userId: Auth.shared.getCurrentUserId()!, spaceId: result.space.id)
                    try member.save(db)

                    // Create main thread (default)
                    let thread = Chat(date: Date.now, type: .thread, title: "Main", spaceId: result.space.id)
                    try thread.save(db)
                }

                // Return for navigating to space using id
                return result.space.id
            } else {
                return nil
            }
        } catch {
            Log.shared.error("Failed to create space", error: error)
        }
        return nil
    }

    func createThread(spaceId: Int64, title: String) async throws -> Int64? {
        do {
            try await database.dbWriter.write { db in
                let thread = Chat(date: Date.now, type: .thread, title: title, spaceId: spaceId)
                try thread.save(db)
                return thread.id
            }
        } catch {
            Log.shared.error("Failed to create thread", error: error)
        }
        return nil
    }

    func sendMessage(chatId: Int64, text: String) async throws {
        try await database.dbWriter.write { db in
            let message = Message(date: Date.now, text: text, chatId: chatId, fromId: Auth.shared.getCurrentUserId()!)
            try message.save(db)
        }
    }
}
