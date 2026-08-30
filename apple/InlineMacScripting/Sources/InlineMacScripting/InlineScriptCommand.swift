import AppKit

@MainActor
public enum InlineScripting {
  public typealias Handler = @MainActor (ScriptingRequest) async throws -> ScriptingValue
  private static var handler: Handler?
  private static var inFlight = 0

  public static func install(handler: @escaping Handler) {
    // A concrete reference also keeps the Objective-C command class linked into the app.
    _ = InlineScriptCommand.self
    self.handler = handler
  }

  static func begin() throws -> Handler {
    guard let handler else { throw ScriptingError.unavailable }
    guard inFlight < 16 else { throw ScriptingError(-10000, "Inline is busy with other AppleScript commands. Try again shortly.") }
    inFlight += 1
    return { request in
      // A timeout replies before cancellation necessarily stops the handler.
      // Keep its admission until the operation really exits.
      defer { inFlight -= 1 }
      return try await handler(request)
    }
  }
}

@objc(InlineScriptCommand)
@MainActor
public final class InlineScriptCommand: NSScriptCommand, @unchecked Sendable {
  // NSScriptCommand predates Sendable. All inherited mutable state stays in AppKit's
  // main-thread callback and main-actor reply. Only typed requests/results cross executors.
  public nonisolated override func performDefaultImplementation() -> Any? {
    // AppKit dispatches incoming scripting events on the main thread. Do not block it for I/O.
    MainActor.assumeIsolated {
      do {
        let request = try ScriptingRequest.decode(
          code: commandDescription.appleEventCode,
          direct: directParameter,
          arguments: evaluatedArguments ?? [:]
        )
        let handler = try InlineScripting.begin()
        suspendExecution()
        let execution = ScriptExecution(command: self)
        execution.start(request: request, handler: handler)
      } catch {
        let failure = error as? ScriptingError ?? .failed
        scriptErrorNumber = failure.number
        scriptErrorString = failure.message
      }
    }
    return nil
  }
}

/// Keeps a suspended command alive and pairs every suspension with exactly one reply.
@MainActor
final class ScriptExecution {
  private let reply: (Result<ScriptingValue, ScriptingError>) -> Void
  private var operation: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private var finished = false

  init(reply: @escaping (Result<ScriptingValue, ScriptingError>) -> Void) {
    self.reply = reply
  }

  convenience init(command: NSScriptCommand) {
    self.init { result in
      switch result {
      case let .success(value): command.resumeExecution(withResult: value.cocoaValue())
      case let .failure(error):
        command.scriptErrorNumber = error.number
        command.scriptErrorString = error.message
        command.resumeExecution(withResult: nil)
      }
    }
  }

  func start(request: ScriptingRequest, timeout: Duration = .seconds(30), handler: @escaping InlineScripting.Handler) {
    operation = Task {
      do { finish(.success(try await handler(request))) }
      catch { finish(.failure(error as? ScriptingError ?? .failed)) }
    }
    deadline = Task {
      do { try await Task.sleep(for: timeout) }
      catch { return }
      finish(.failure(.timeout))
    }
  }

  private func finish(_ result: Result<ScriptingValue, ScriptingError>) {
    guard !finished else { return }
    finished = true
    operation?.cancel()
    deadline?.cancel()
    operation = nil
    deadline = nil
    reply(result)
  }
}
