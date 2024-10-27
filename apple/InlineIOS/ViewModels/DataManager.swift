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

                let member = Member(from: result.member)
                try member.save(db)

                // Create main thread (default)
                for chat in result.chats {
                    let thread = Chat(from: chat)
                    try thread.save(db)
                }
            }

            // Return for navigating to space using id
            return result.space.id

        } catch {
            Log.shared.error("Failed to create space", error: error)
        }
        return nil
    }

    func createThread(spaceId: Int64?, title: String, peerUserId: Int64? = nil) async throws -> Int64? {
        do {
            return try await database.dbWriter.write { db in
                let currentUserId = Auth.shared.getCurrentUserId()
                guard let currentUserId = currentUserId else {
                    Log.shared.error("Current user not found")
                    throw NSError(domain: "AuthError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Current user not found"])
                }

                // Create the chat
                let thread = Chat(
                    date: Date.now,
                    type: .privateChat,
                    title: title,
                    spaceId: spaceId,
                    peerUserId: peerUserId
                )
                try thread.save(db)

                return thread.id
            }
        } catch {
            Log.shared.error("Failed to create thread", error: error)
            throw error
        }
    }

    func getSpaces() async throws -> [ApiSpace] {
        do {
            let result = try await ApiClient.shared.getSpaces()

            try await database.dbWriter.write { db in
                for space in result.spaces {
                    let space = Space(from: space)
                    try space.save(db)
                }
                for member in result.members {
                    let member = Member(from: member)
                    try member.save(db)
                }
            }
            return result.spaces

        } catch {
            return []
        }
    }

    func sendMessage(chatId: Int64, text: String) async throws {
        try await database.dbWriter.write { db in
            let message = Message(date: Date.now, text: text, chatId: chatId, fromId: Auth.shared.getCurrentUserId()!)
            try message.save(db)
        }
    }
}
