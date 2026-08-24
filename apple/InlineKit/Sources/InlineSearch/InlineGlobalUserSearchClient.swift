import InlineKit

public protocol InlineGlobalUserSearching: Sendable {
  func searchUsers(query: String) async throws -> [ApiUser]
}

public struct InlineApiGlobalUserSearchClient: InlineGlobalUserSearching {
  // Retain the old initializer shape for source compatibility while the implementation migrates
  // from bearer REST to the account-owned realtime RPC.
  public init(api _: ApiClient = .shared) {}

  public func searchUsers(query: String) async throws -> [ApiUser] {
    // Keep the source-compatible client name, but use the account-owned realtime
    // RPC so V3-native sessions do not depend on a legacy bearer credential.
    try await InlineRPCClient.shared.searchContacts(query: query).users
  }
}
