import Foundation
import InlineProtocol

public enum ConnectorKind: String, CaseIterable, Identifiable, Sendable {
  case notion
  case linear
  case github

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .notion: "Notion"
    case .linear: "Linear"
    case .github: "GitHub"
    }
  }

  public var assetName: String {
    switch self {
    case .notion: "notion-logo"
    case .linear: "linear-icon"
    case .github: "github-mark"
    }
  }

  init?(protocolValue: InlineProtocol.ConnectorProvider) {
    switch protocolValue {
    case .notion: self = .notion
    case .linear: self = .linear
    case .github: self = .github
    case .unspecified, .UNRECOGNIZED: return nil
    }
  }

  var protocolValue: InlineProtocol.ConnectorProvider {
    switch self {
    case .notion: .notion
    case .linear: .linear
    case .github: .github
    }
  }
}

public struct ConnectorScope: Identifiable, Hashable, Sendable {
  public let scope: Scope
  public let canManage: Bool
  public let allowsConnections: Bool

  public var id: ScopeID { scope.id }
  public var name: String { scope.name }

  init?(protocolValue: InlineProtocol.ConnectorScope) {
    guard protocolValue.hasScope,
          let scope = Scope(protocolValue: protocolValue.scope)
    else { return nil }
    self.scope = scope
    canManage = protocolValue.canManage
    allowsConnections = protocolValue.hasAllowsConnections
      ? protocolValue.allowsConnections
      : true
  }
}

public struct ConnectorAvailability: Identifiable, Hashable, Sendable {
  public let id: ConnectorKind
  public let isAvailable: Bool
  public let supportsUserScope: Bool
  public let supportsSpaceScope: Bool

  public func supports(_ scope: Scope) -> Bool {
    // Empty capability flags preserve compatibility with servers predating
    // per-scope connector availability.
    if !supportsUserScope, !supportsSpaceScope { return true }
    return switch scope {
    case .user: supportsUserScope
    case .space: supportsSpaceScope
    }
  }

  init?(protocolValue: InlineProtocol.ConnectorProviderInfo) {
    guard let id = ConnectorKind(protocolValue: protocolValue.provider) else { return nil }
    self.id = id
    isAvailable = protocolValue.available
    supportsUserScope = protocolValue.supportsUserScope
    supportsSpaceScope = protocolValue.supportsSpaceScope
  }
}

public struct ConnectorConnection: Identifiable, Hashable, Sendable {
  public struct ID: Hashable, Sendable {
    let provider: ConnectorKind
    let scope: ScopeID
  }

  public let id: ID
  public let scope: Scope
  public let connectedAt: Date
  public let connectedBy: UserInfo?
  public let needsConfiguration: Bool

  public var provider: ConnectorKind { id.provider }
  public var scopeID: ScopeID { id.scope }

  init?(protocolValue: InlineProtocol.ConnectorConnection) {
    guard protocolValue.hasScope,
          let provider = ConnectorKind(protocolValue: protocolValue.provider),
          let scope = Scope(protocolValue: protocolValue.scope)
    else { return nil }

    id = ID(provider: provider, scope: scope.id)
    self.scope = scope
    connectedAt = Date(timeIntervalSince1970: TimeInterval(protocolValue.connectedAt))
    connectedBy = protocolValue.hasConnectedBy
      ? UserInfo(user: User(from: protocolValue.connectedBy))
      : nil
    needsConfiguration = protocolValue.needsConfiguration
  }
}

public struct ConnectorSettingsSnapshot: Sendable {
  public let providers: [ConnectorAvailability]
  public let scopes: [ConnectorScope]
  public let connections: [ConnectorConnection]
}

public extension Notification.Name {
  static let connectorConfigurationUpdated = Notification.Name("connectorConfigurationUpdated")
}
