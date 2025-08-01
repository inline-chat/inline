import Auth
import Combine
import Foundation
import InlineProtocol
import Logger

public actor Realtime {
  /// The shared instance of the Realtime actor used across the application.
  public static let shared = Realtime(transport: WebSocketTransport(), auth: Auth.shared)

  // MARK: - Core Components

  // private var transport: Transport
  private var auth: Auth
  private var client: ProtocolClient

  // TODO:
  // transactions
  // sync

  // MARK: - Private Properties

  private let log = Log.scoped("RealtimeV2")
  private var cancellables = Set<AnyCancellable>()
  private var tasks: Set<Task<Void, Never>> = []

  // MARK: - Options

  private let retryDelay: TimeInterval = 2.0

  // MARK: - Initialization

  init(transport: Transport, auth: Auth) {
    // self.transport = transport
    self.auth = auth
    client = ProtocolClient(transport: transport, auth: auth)

    Task {
      // Initialize everything and start
      await self.start()
    }
  }

  // MARK: - Deinitialization

  deinit {
    // Cancel all associated tasks
    for task in tasks {
      task.cancel()
    }
    tasks.removeAll()

    // Stop core components
    Task { [self] in
      await client.stopTransport()
    }
  }

  // MARK: - Lifecycle

  /// Start core components, register listeners and start run loops.
  private func start() async {
    await startListeners()

    if auth.isLoggedIn {
      await startTransport()
    }
  }

  /// Called when log out happens
  /// Reset all state to their initial values.
  /// Stop transport. But do not kill the listeners and tasks. This is state is recoverable via a transport start.
  private func stopAndReset() async {
    await client.stopTransport()
  }

  /// Listen for auth events, transport events, sync events, etc.
  private func startListeners() async {
    // Auth events
    Task.detached {
      self.log.debug("Starting auth events listener")
      for await event in await self.auth.events {
        guard Task.isCancelled else { return }

        switch event {
          case .login:
            Task {
              await self.startTransport()
            }

          case .logout:
            Task { await self.stopAndReset() }
        }
      }
    }.store(in: &tasks)

    // Transport events
    Task.detached {
      self.log.debug("Starting transport events listener")
      for await event in await self.client.events {
        guard Task.isCancelled else { return }

        switch event {
          case .open:
            self.log.debug("Transport connected")

          case .connecting:
            self.log.debug("Transport connecting")
        }
      }
    }.store(in: &tasks)
  }

  private func startTransport() async {
    await client.startTransport()
  }

  private func stopTransport() async {
    await client.stopTransport()
  }

  // MARK: - Public API

  /// Send an RPC call through the protocol client
  ///
  /// Note(@Mo): Unsure if we should keep this
  public func sendRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?
  ) async throws -> RpcResult.OneOf_Result? {
    try await client.sendRpc(method: method, input: input)
  }
}
