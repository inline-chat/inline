import Foundation
import InlineIntents
import InlineKit
import Logger

enum IntentDonationCoordinator {
  private static let tasks = IntentDonationTaskRegistry()

  static func donateOutgoing(peerId: Peer, chatId: Int64) {
    tasks.start { token in
      guard let request = await AppDataUpdater.shared.outgoingIntentRequest(
        peerId: peerId,
        chatId: chatId
      ) else {
        Log.shared.warning("Skipped send-message intent donation: conversation metadata unavailable")
        return
      }
      guard tasks.shouldContinue(token) else { return }

      do {
        try await InlineMessageIntentDonation.donate(request)
      } catch {
        Log.shared.warning("Failed to donate send-message intent: \(error.localizedDescription)")
      }
    }
  }

  static func deleteAll() async {
    await tasks.suspendAndDrain()
    do {
      try await InlineMessageIntentDonation.deleteAll()
    } catch {
      Log.shared.warning("Failed to clear donated message intents: \(error.localizedDescription)")
    }
  }

  static func resume() {
    tasks.resume()
  }
}

private final class IntentDonationTaskRegistry: @unchecked Sendable {
  struct Token: Sendable {
    let id: UUID
    let generation: UInt64
  }

  private struct State {
    var acceptsNewTasks = true
    var generation: UInt64 = 0
    var tasks: [UUID: Task<Void, Never>] = [:]
  }

  private let lock = NSLock()
  private var state = State()

  func start(_ operation: @escaping @Sendable (Token) async -> Void) {
    lock.lock()
    guard state.acceptsNewTasks else {
      lock.unlock()
      return
    }

    let token = Token(id: UUID(), generation: state.generation)
    let task = Task(priority: .userInitiated) { [weak self] in
      guard let self, shouldContinue(token) else { return }
      await operation(token)
      finish(token)
    }
    state.tasks[token.id] = task
    lock.unlock()
  }

  func shouldContinue(_ token: Token) -> Bool {
    lock.withLock {
      state.acceptsNewTasks && state.generation == token.generation && !Task.isCancelled
    }
  }

  func suspendAndDrain() async {
    let tasks: [Task<Void, Never>] = lock.withLock {
      state.acceptsNewTasks = false
      state.generation &+= 1
      let tasks = Array(state.tasks.values)
      state.tasks.removeAll()
      return tasks
    }
    tasks.forEach { $0.cancel() }
    for task in tasks {
      await task.value
    }
  }

  func resume() {
    lock.withLock {
      state.acceptsNewTasks = true
    }
  }

  private func finish(_ token: Token) {
    lock.withLock {
      state.tasks[token.id] = nil
    }
  }
}
