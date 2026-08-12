import Foundation
import InlineProtocol
import Observation

public enum ConnectorSettingsClientError: Error {
  case unexpectedResponse
  case invalidAuthorizationURL
}

public enum ConnectorSettingsClient {
  public static func load() async throws -> ConnectorSettingsSnapshot {
    let response = try await Api.realtime.callRpcDirect(
      method: .listConnectors,
      input: .listConnectors(.init())
    )
    guard case let .listConnectors(result)? = response else {
      throw ConnectorSettingsClientError.unexpectedResponse
    }
    return ConnectorSettingsSnapshot(
      providers: result.providers.compactMap(ConnectorAvailability.init),
      scopes: result.scopes.compactMap(ConnectorScope.init),
      connections: result.connections.compactMap(ConnectorConnection.init)
    )
  }

  public static func prepareOAuth(
    provider: ConnectorKind,
    scope: Scope
  ) async throws -> URL {
    let response = try await Api.realtime.callRpcDirect(
      method: .prepareConnectorOauth,
      input: .prepareConnectorOauth(.with {
        $0.provider = provider.protocolValue
        $0.scope = scope.protocolValue
        $0.callbackScheme = InlineDeepLink.configuredScheme
      })
    )
    guard case let .prepareConnectorOauth(result)? = response else {
      throw ConnectorSettingsClientError.unexpectedResponse
    }
    guard let url = URL(string: result.authorizationURL) else {
      throw ConnectorSettingsClientError.invalidAuthorizationURL
    }
    return url
  }

  public static func disconnect(
    provider: ConnectorKind,
    scope: Scope
  ) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .disconnectConnector,
      input: .disconnectConnector(.with {
        $0.provider = provider.protocolValue
        $0.scope = scope.protocolValue
      })
    )
    guard case .disconnectConnector? = response else {
      throw ConnectorSettingsClientError.unexpectedResponse
    }
  }
}

@MainActor
@Observable
public final class ConnectorSettingsModel {
  public private(set) var snapshot: ConnectorSettingsSnapshot?
  public var selectedScopeID: ScopeID?
  public private(set) var isLoading = false
  public private(set) var activeProviders: Set<ConnectorKind> = []
  public var errorMessage: String?

  private let initialScopeID: ScopeID?
  private var loadGeneration = 0

  public init(initialScopeID: ScopeID? = nil) {
    self.initialScopeID = initialScopeID
    selectedScopeID = initialScopeID
  }

  public var scopes: [ConnectorScope] { snapshot?.scopes ?? [] }
  public var providers: [ConnectorAvailability] { snapshot?.providers ?? [] }

  public var selectedScope: ConnectorScope? {
    guard let selectedScopeID else { return nil }
    return scopes.first { $0.id == selectedScopeID }
  }

  public func connection(
    for provider: ConnectorKind,
    scopeID: ScopeID
  ) -> ConnectorConnection? {
    snapshot?.connections.first {
      $0.provider == provider && $0.scopeID == scopeID
    }
  }

  public func load() async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = snapshot == nil
    defer {
      if generation == loadGeneration {
        isLoading = false
      }
    }

    do {
      let newSnapshot = try await ConnectorSettingsClient.load()
      guard generation == loadGeneration, !Task.isCancelled else { return }
      snapshot = newSnapshot
      if let selectedScopeID,
         newSnapshot.scopes.contains(where: { $0.id == selectedScopeID }) {
        // Preserve the user's current scope selection.
      } else if let initialScopeID,
                newSnapshot.scopes.contains(where: { $0.id == initialScopeID }) {
        selectedScopeID = initialScopeID
      } else {
        selectedScopeID = newSnapshot.scopes.first?.id
      }
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard generation == loadGeneration else { return }
      errorMessage = "Couldn’t load connectors. Please try again."
    }
  }

  public func prepareOAuth(for provider: ConnectorKind) async -> URL? {
    guard let scope = selectedScope,
          scope.canManage,
          scope.allowsConnections,
          activeProviders.insert(provider).inserted
    else { return nil }
    defer { activeProviders.remove(provider) }

    do {
      let url = try await ConnectorSettingsClient.prepareOAuth(
        provider: provider,
        scope: scope.scope
      )
      errorMessage = nil
      return url
    } catch {
      errorMessage = "Couldn’t start \(provider.title) authorization."
      return nil
    }
  }

  public func disconnect(
    _ provider: ConnectorKind,
    from scope: ConnectorScope
  ) async {
    guard scope.canManage,
          activeProviders.insert(provider).inserted
    else { return }
    defer { activeProviders.remove(provider) }

    do {
      try await ConnectorSettingsClient.disconnect(provider: provider, scope: scope.scope)
      await load()
    } catch {
      errorMessage = "Couldn’t disconnect \(provider.title)."
    }
  }

  @discardableResult
  public func handleOAuthCallback(_ url: URL) async -> Bool {
    guard let callback = ConnectorOAuthCallback(url: url) else { return false }
    activeProviders.remove(callback.provider)
    if callback.succeeded {
      await load()
    } else {
      errorMessage = callback.error.map(Self.humanReadableError)
        ?? "Couldn’t connect \(callback.provider.title)."
    }
    return true
  }

  private static func humanReadableError(_ value: String) -> String {
    let normalized = value.replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "Authorization failed." }
    return normalized.prefix(1).uppercased() + normalized.dropFirst()
  }
}
