import InlineKit

public protocol InlineGlobalUserSearching: Sendable {
  func searchUsers(query: String) async throws -> [ApiUser]
}

public struct InlineApiGlobalUserSearchClient: InlineGlobalUserSearching {
  private let api: ApiClient

  public init(api: ApiClient = .shared) {
    self.api = api
  }

  public func searchUsers(query: String) async throws -> [ApiUser] {
    try await api.searchContacts(query: query).users
  }
}
