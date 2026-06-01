import Foundation

public struct DelayedDestructiveActionToken: Hashable, Sendable {
  fileprivate let id: UUID
}

@MainActor
public final class DelayedDestructiveActionScheduler {
  public static let shared = DelayedDestructiveActionScheduler()

  private var tasks: [UUID: Task<Void, Never>] = [:]

  public init() {}

  @discardableResult
  public func schedule(
    delay: TimeInterval = 5,
    onPerforming: (@MainActor @Sendable () -> Void)? = nil,
    action: @escaping @MainActor @Sendable () async throws -> Void,
    onSuccess: (@MainActor @Sendable () -> Void)? = nil,
    onFailure: (@MainActor @Sendable (Error) -> Void)? = nil
  ) -> DelayedDestructiveActionToken {
    let id = UUID()
    let token = DelayedDestructiveActionToken(id: id)
    let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)

    tasks[id] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: nanoseconds)
      } catch {
        return
      }

      guard let self, self.tasks[id] != nil else { return }
      self.tasks[id] = nil

      do {
        onPerforming?()
        try await action()
        onSuccess?()
      } catch {
        onFailure?(error)
      }
    }

    return token
  }

  @discardableResult
  public func cancel(_ token: DelayedDestructiveActionToken) -> Bool {
    guard let task = tasks.removeValue(forKey: token.id) else {
      return false
    }

    task.cancel()
    return true
  }

  public func cancelAll() {
    tasks.values.forEach { $0.cancel() }
    tasks.removeAll()
  }
}
