import Foundation
import Combine
import Logger
import Auth

@MainActor
public class NotionTaskService: ObservableObject {
  public static let shared = NotionTaskService()

  @Published public private(set) var hasAccess: Bool = false
  private let log = Log.scoped("NotionTaskService")

  private init() {}

  public func checkIntegrationAccess(peerId: Peer, spaceId: Int64?) async {
    guard let userId = Auth.shared.getCurrentUserId() else {
      hasAccess = false
      return
    }

    do {
      let result = try await ApiClient.shared.getIntegrations(
        userId: userId,
        spaceId: peerId.isThread ? spaceId : nil
      )
      hasAccess = result.hasIntegrationAccess && result.hasNotionConnected
    } catch {
      log.error("Error checking integration access: \(error)")
      hasAccess = false
    }
  }

  public func getAvailableSpaces(for message: Message) async throws -> [NotionSpace] {
    guard let userId = Auth.shared.getCurrentUserId() else {
      throw NotionTaskError.noIntegrationAccess
    }

    let spaceId = message.peerId.isThread ? message.peerId.asThreadId() : nil

    do {
      let result = try await ApiClient.shared.getIntegrations(userId: userId, spaceId: spaceId)

      guard result.hasIntegrationAccess && result.hasNotionConnected else {
        throw NotionTaskError.noIntegrationAccess
      }

      guard let spaces = result.notionSpaces, !spaces.isEmpty else {
        throw NotionTaskError.noNotionSpaces
      }

      return spaces
    } catch let error as NotionTaskError {
      throw error
    } catch {
      throw NotionTaskError.apiError(error)
    }
  }

  public func createTask(message: Message, spaceId: Int64) async throws -> String {
    do {
      let result = try await ApiClient.shared.createNotionTask(
        spaceId: spaceId,
        messageId: message.messageId,
        chatId: message.chatId,
        peerId: message.peerId
      )
      return result.url
    } catch {
      throw NotionTaskError.apiError(error)
    }
  }
}
