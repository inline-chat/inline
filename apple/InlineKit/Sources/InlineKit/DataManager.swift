import Foundation
import GRDB

enum DataManagerError: Error {
    case networkError
    case apiError(description: String, code: Int)
    case localSaveError
}

// ?? should we use main actor here?

/// Query or mutate data on the server and update local database
@MainActor
public class DataManager: ObservableObject {
    private var database: AppDatabase
    private var log = Log.scoped("DataManager")

    public init(database: AppDatabase) {
        self.database = database
    }

    public static let shared = DataManager(database: AppDatabase.shared)

    public func fetchMe() async throws -> User {
        log.debug("fetchMe")
        do {
            let result = try await ApiClient.shared.getMe()
            print("fetchMe result: \(result)")
            let user = User(from: result.user)
            try await database.dbWriter.write { db in
                try user.save(db)
                print("User saved: \(user)")
            }
            print("currentUserId: \(Auth.shared.getCurrentUserId() ?? Int64.min)")
            return user
        } catch {
            Log.shared.error("Error fetching user", error: error)
            throw error
        }
    }

    public func createSpace(name: String) async throws -> Space {
        log.debug("createSpace")
        do {
            let result = try await ApiClient.shared.createSpace(name: name)
            print("Create space result: \(result)")
            let space = Space(from: result.space)
            try await database.dbWriter.write { db in
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
            return space
        } catch {
            Log.shared.error("Failed to create space", error: error)
            throw error
        }
    }

    public func createThread(spaceId: Int64, title: String?) async throws -> Int64? {
        log.debug("createThread")
        do {
            return try await database.dbWriter.write { db in

                // TODO: API call to create thread

                // Create the chat
                let thread = Chat(
                    date: Date.now,
                    type: .thread,
                    title: title,
                    spaceId: spaceId
                )
                try thread.save(db)

                return thread.id
            }
        } catch {
            Log.shared.error("Failed to create thread", error: error)
            throw error
        }
    }

    public func createPrivateChat(peerId: Int64) async throws -> Int64? {
        log.debug("createPrivateChat")
        do {
            let result = try await ApiClient.shared.createPrivateChat(peerId: peerId)

            try await database.dbWriter.write { db in
                let chat = Chat(from: result.chat)
                try chat.save(db)
            }

            return result.chat.id
        } catch {
            Log.shared.error("Failed to create private chat", error: error)
        }
        return nil
    }

    /// Get list of user spaces and saves them
    @discardableResult
    public func getSpaces() async throws -> [Space] {
        log.debug("getSpaces")
        do {
            let result = try await ApiClient.shared.getSpaces()

            let spaces = try await database.dbWriter.write { db in
                let spaces = result.spaces.map { space in
                    Space(from: space)
                }
                try spaces.forEach { space in
                    try space.save(db)
                }
                for member in result.members {
                    let member = Member(from: member)
                    try member.save(db)
                }
                return spaces
            }

            return spaces
        } catch {
            throw error
        }
    }

    public func sendMessage(chatId: Int64, text: String) async throws {
        log.debug("sendMessage")
        try await database.dbWriter.write { db in
            let message = Message(date: Date.now, text: text, chatId: chatId, fromId: Auth.shared.getCurrentUserId()!)
            try message.save(db)
        }
    }
}
