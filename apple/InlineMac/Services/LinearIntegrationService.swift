import Foundation
import Auth
import InlineKit
import Logger

@MainActor
final class LinearIntegrationService {
  static let shared = LinearIntegrationService()

  private let log = Log.scoped("LinearIntegrationService")
  private var cache: [Int64: Bool] = [:]
  private var inflight: Set<Int64> = []

  private init() {}

  func isConnected(spaceId: Int64) -> Bool? {
    cache[spaceId]
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

  func invalidate(spaceId: Int64) {
    cache.removeValue(forKey: spaceId)
  }
}
