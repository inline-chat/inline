import Foundation

public struct ConnectorOAuthCallback: Equatable, Sendable {
  public let provider: ConnectorKind
  public let succeeded: Bool
  public let error: String?

  public init?(url: URL) {
    guard InlineDeepLink.isSupportedScheme(url.scheme),
          url.host?.lowercased() == "integrations"
    else { return nil }
    let path = url.pathComponents.filter { $0 != "/" }
    guard path.count == 1,
          let provider = ConnectorKind(rawValue: path[0].lowercased()),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }

    let queryItems = components.queryItems ?? []
    let success = queryItems.first { $0.name == "success" }?.value
    let callbackError = queryItems.first { $0.name == "error" }?.value
    self.provider = provider
    succeeded = success == "true"
    error = callbackError.flatMap { $0.isEmpty ? nil : $0 }
  }
}

public extension Notification.Name {
  static let connectorOAuthCallback = Notification.Name("connectorOAuthCallback")
}
