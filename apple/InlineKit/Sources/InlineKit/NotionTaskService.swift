import Foundation
import Combine
import Logger
import Auth

@MainActor
public class NotionTaskService: ObservableObject {
  public static let shared = NotionTaskService()

  private struct AccessKey: Hashable {
    let accountId: Int64
    let peerId: Peer
  }

  private struct AccessEntry {
    let hasAccess: Bool
    let checkedAt: Date
  }

  private let log = Log.scoped("NotionTaskService")
  private let accessCacheTTL: TimeInterval = 5
  private let accessCacheLimit = 256
  private var accessByKey: [AccessKey: AccessEntry] = [:]
  private var accessCheckGenerations: [AccessKey: UInt64] = [:]
  private var accessKeyOrder: [AccessKey] = []
  private var sessionGeneration: UInt64 = 0

  private init() {}

  public func checkIntegrationAccess(peerId: Peer, spaceId: Int64?) async {
    guard let userId = Auth.shared.getCurrentUserId() else {
      resetSession()
      return
    }

    let key = AccessKey(accountId: userId, peerId: peerId)
    touchAccessKey(key)
    if let entry = accessByKey[key] {
      let age = Date().timeIntervalSince(entry.checkedAt)
      if age >= 0, age < accessCacheTTL {
        return
      }
    }

    let generation = (accessCheckGenerations[key] ?? 0) &+ 1
    accessCheckGenerations[key] = generation
    let sessionGeneration = sessionGeneration

    do {
      let result = try await InlineRPCClient.shared.integrations(
        userID: userId,
        spaceID: peerId.isThread ? spaceId : nil
      )
      try Task.checkCancellation()
      guard sessionGeneration == self.sessionGeneration,
            generation == accessCheckGenerations[key],
            Auth.shared.getCurrentUserId() == userId
      else { return }
      accessByKey[key] = AccessEntry(
        hasAccess: result.hasIntegrationAccess && result.hasNotionConnected,
        checkedAt: Date()
      )
    } catch {
      if Self.isCancellation(error) { return }
      guard sessionGeneration == self.sessionGeneration,
            generation == accessCheckGenerations[key],
            Auth.shared.getCurrentUserId() == userId
      else { return }
      log.error("Error checking integration access", error: error)
    }
  }

  public func hasAccess(peerId: Peer) -> Bool {
    guard let userId = Auth.shared.getCurrentUserId() else { return false }
    return accessByKey[AccessKey(accountId: userId, peerId: peerId)]?.hasAccess ?? false
  }

  public func resetSession() {
    sessionGeneration &+= 1
    accessByKey.removeAll()
    accessCheckGenerations.removeAll()
    accessKeyOrder.removeAll()
  }

  private func touchAccessKey(_ key: AccessKey) {
    accessKeyOrder.removeAll { $0 == key }
    accessKeyOrder.append(key)
    while accessKeyOrder.count > accessCacheLimit {
      let evicted = accessKeyOrder.removeFirst()
      accessByKey.removeValue(forKey: evicted)
      accessCheckGenerations.removeValue(forKey: evicted)
    }
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? URLError)?.code == .cancelled
  }

  public func getAvailableSpaces(for message: Message) async throws -> [NotionSpace] {
    guard let userId = Auth.shared.getCurrentUserId() else {
      throw NotionTaskError.noIntegrationAccess
    }

    do {
      let result = try await InlineRPCClient.shared.integrations(userID: userId, spaceID: nil)

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
      let result = try await InlineRPCClient.shared.createNotionTask(
        spaceID: spaceId,
        messageID: message.messageId,
        peerID: message.peerId
      )
      return result.url
    } catch {
      throw NotionTaskError.apiError(error)
    }
  }
}
