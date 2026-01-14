import Foundation
import Auth
import InlineKit
import Logger

@MainActor
final class LinearIntegrationService {
  static let shared = LinearIntegrationService()

  private let log = Log.scoped("LinearIntegrationService")
  private var cache: [Int64: Bool] = [:]
  private var anySpaceCache: Bool?
  private var inflight: Set<Int64> = []
  private var anySpaceInflight = false

  private init() {}

  func isConnected(spaceId: Int64) -> Bool? {
    cache[spaceId]
  }

  func isConnectedAnySpace() -> Bool? {
    anySpaceCache
  }

  func refresh(spaceId: Int64) {
    guard !inflight.contains(spaceId) else { return }
    inflight.insert(spaceId)

    Task {
      defer { Task { @MainActor in self.inflight.remove(spaceId) } }
      do {
        let integrations = try await ApiClient.shared.getIntegrations(
          userId: Auth.shared.getCurrentUserId() ?? 0,
          spaceId: spaceId
        )
        await MainActor.run {
          self.cache[spaceId] = integrations.hasLinearConnected
        }
      } catch {
        await MainActor.run {
          self.cache[spaceId] = false
        }
        log.error("Failed to refresh Linear integration status", error: error)
      }
    }
  }

  func refreshAnySpace() {
    guard !anySpaceInflight else { return }
    anySpaceInflight = true

    Task {
      defer { Task { @MainActor in self.anySpaceInflight = false } }
      do {
        let integrations = try await ApiClient.shared.getIntegrations(
          userId: Auth.shared.getCurrentUserId() ?? 0,
          spaceId: nil
        )
        let hasLinearSpaces = integrations.linearSpaces?.isEmpty == false
        await MainActor.run {
          self.anySpaceCache = hasLinearSpaces
        }
      } catch {
        await MainActor.run {
          self.anySpaceCache = false
        }
        log.error("Failed to refresh Linear integration status (any space)", error: error)
      }
    }
  }

  func invalidate(spaceId: Int64) {
    cache.removeValue(forKey: spaceId)
  }
}
