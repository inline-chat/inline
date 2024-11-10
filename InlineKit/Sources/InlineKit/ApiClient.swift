import Combine
import Foundation

public enum APIError: Error {
  case invalidURL
  case invalidResponse
  case httpError(statusCode: Int)
  case decodingError(Error)
  case networkError
  case rateLimited
  case error(errorCode: Int, description: String?)
}

public enum Path: String {
  case verifyCode = "verifyEmailCode"
  case sendCode = "sendEmailCode"
  case createSpace
  case updateProfile
  case getSpaces
  case createThread
  case checkUsername
  case searchContacts
  case createPrivateChat
  case getMe
  case deleteSpace
  case leaveSpace
  case getPrivateChats
  case getPinnedDialogs
  case getOpenDialogs
  case getSpaceMembers
  case sendMessage
  case getDialogs
}

public final class ApiClient: ObservableObject, @unchecked Sendable {
  public static let shared = ApiClient()
  public init() {}

  private var baseURL: String {
    #if targetEnvironment(simulator)
      return "http://localhost:8000/v1"
    #elseif DEBUG && os(iOS)
      return "http://192.168.3.122:8000/v1"
    #elseif DEBUG && os(macOS)
      return "http://localhost:8000/v1"
    #else
      return "https://api.inline.chat/v1"
    #endif
  }

  private let decoder = JSONDecoder()

  private func request<T: Decodable & Sendable>(
    _ path: Path,
    queryItems: [URLQueryItem] = [],
    includeToken: Bool = false
  ) async throws -> T {
    guard var urlComponents = URLComponents(string: "\(baseURL)/\(path.rawValue)") else {
      throw APIError.invalidURL
    }

    urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems

    guard let url = urlComponents.url else {
      throw APIError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"

    if let token = Auth.shared.getToken(), includeToken {
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw APIError.invalidResponse
      }

      switch httpResponse.statusCode {
      case 200...299:
        let apiResponse = try decoder.decode(APIResponse<T>.self, from: data)
        switch apiResponse {
        case let .success(data):
          return data
        case let .error(errorCode, description):
          throw
            APIError
            .error(errorCode: errorCode, description: description)
        }
      case 429:
        throw APIError.rateLimited
      default:
        throw APIError.httpError(statusCode: httpResponse.statusCode)
      }
    } catch let decodingError as DecodingError {
      throw APIError.decodingError(decodingError)
    } catch let apiError as APIError {
      throw apiError
    } catch {
      throw APIError.networkError
    }
  }

  // MARK: AUTH

  public func sendCode(email: String) async throws -> SendCode {
    try await request(.sendCode, queryItems: [URLQueryItem(name: "email", value: email)])
  }

  public func verifyCode(code: String, email: String) async throws -> VerifyCode {
    try await request(
      .verifyCode,
      queryItems: [
        URLQueryItem(name: "code", value: code), URLQueryItem(name: "email", value: email),
      ]
    )
  }

  public func createSpace(name: String) async throws -> CreateSpace {
    try await request(
      .createSpace, queryItems: [URLQueryItem(name: "name", value: name)], includeToken: true
    )
  }

  public func updateProfile(firstName: String?, lastName: String?, username: String?) async throws
    -> UpdateProfile
  {
    var queryItems: [URLQueryItem] = []

    if let firstName = firstName {
      queryItems.append(URLQueryItem(name: "firstName", value: firstName))
    }
    if let lastName = lastName {
      queryItems.append(URLQueryItem(name: "lastName", value: lastName))
    }
    if let username = username {
      queryItems.append(URLQueryItem(name: "username", value: username))
    }

    return try await request(.updateProfile, queryItems: queryItems, includeToken: true)
  }

  public func getSpaces() async throws -> GetSpaces {
    try await request(.getSpaces, includeToken: true)
  }

  public func createThread(title: String, spaceId: Int64) async throws -> CreateThread {
    try await request(
      .createThread,
      queryItems: [
        URLQueryItem(name: "title", value: title),
        URLQueryItem(name: "spaceId", value: "\(spaceId)"),
      ], includeToken: true
    )
  }

  public func checkUsername(username: String) async throws -> CheckUsername {
    try await request(
      .checkUsername, queryItems: [URLQueryItem(name: "username", value: username)],
      includeToken: true
    )
  }

  public func getMe() async throws -> GetMe {
    try await request(
      .getMe, queryItems: [],
      includeToken: true
    )
  }

  public func searchContacts(query: String) async throws -> SearchContacts {
    try await request(
      .searchContacts,
      queryItems: [URLQueryItem(name: "q", value: query)],
      includeToken: true
    )
  }

  public func createPrivateChat(peerId: Int64) async throws -> CreatePrivateChat {
    try await request(
      .createPrivateChat,
      queryItems: [URLQueryItem(name: "userId", value: "\(peerId)")],
      includeToken: true
    )
  }

  public func deleteSpace(spaceId: Int64) async throws -> EmptyPayload {
    try await request(
      .deleteSpace,
      queryItems: [URLQueryItem(name: "spaceId", value: "\(spaceId)")],
      includeToken: true
    )
  }

  public func leaveSpace(spaceId: Int64) async throws -> EmptyPayload {
    try await request(
      .leaveSpace,
      queryItems: [URLQueryItem(name: "spaceId", value: "\(spaceId)")],
      includeToken: true
    )
  }

  public func getPrivateChats() async throws -> GetPrivateChats {
    print("API CALLED")
    let result: GetPrivateChats = try await request(.getPrivateChats, includeToken: true)
    print("getPrivateChats resultttttt \(result)")
    return result
  }

  public func getDialogs(spaceId: Int64) async throws -> GetDialogs {
    try await request(
      .getDialogs, queryItems: [URLQueryItem(name: "spaceId", value: "\(spaceId)")],
      includeToken: true
    )
  }

  //    public func getFullSpace(spaceId: Int64) async throws -> FullSpacePayload {
  //        try await request(
  //            .getFullSpace,
  //            queryItems: [URLQueryItem(name: "spaceId", value: "\(spaceId)")],
  //            includeToken: true
  //        )
  //    }

  public func sendMessage(chatId: Int64, text: String) async throws -> SendMessage {
    try await request(
      .sendMessage,
      queryItems: [
        URLQueryItem(name: "chatId", value: "\(chatId)"), URLQueryItem(name: "text", value: text),
      ], includeToken: true)
  }
}

/// Example
/// {
///     "ok": true,
///     "result": {
///         "userId": 123,
///         "token": "123"
///     }
/// }
public enum APIResponse<T>: Decodable, Sendable where T: Decodable & Sendable {
  case success(T)
  case error(errorCode: Int, description: String?)

  private enum CodingKeys: String, CodingKey {
    case ok
    case errorCode
    case description
    case result
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    if try values.decode(Bool.self, forKey: .ok) {
      if T.self == EmptyPayload.self {
        self = .success(EmptyPayload() as! T)
      } else {
        self = try .success(values.decode(T.self, forKey: .result))
      }
    } else {
      self = try .error(
        errorCode: values.decode(Int.self, forKey: .errorCode),
        description: values.decodeIfPresent(String.self, forKey: .description)
      )
    }
  }
}

public struct VerifyCode: Codable, Sendable {
  public let userId: Int64
  public let token: String
  public let user: ApiUser
}

public struct SendCode: Codable, Sendable {
  public let existingUser: Bool?
}

public struct CreateSpace: Codable, Sendable {
  public let space: ApiSpace
  public let member: ApiMember
  public let chats: [ApiChat]
}

public struct UpdateProfile: Codable, Sendable {
  public let user: ApiUser
}

public struct GetSpaces: Codable, Sendable {
  public let spaces: [ApiSpace]
  public let members: [ApiMember]
}

public struct CreateThread: Codable, Sendable {
  public let chat: ApiChat
}

public struct CheckUsername: Codable, Sendable {
  public let available: Bool
}

public struct SearchContacts: Codable, Sendable {
  public let users: [ApiUser]
}

public struct CreatePrivateChat: Codable, Sendable {
  public let chat: ApiChat
}

public struct GetMe: Codable, Sendable {
  public let user: ApiUser
}

public struct EmptyPayload: Codable, Sendable {}

public struct GetPrivateChats: Codable, Sendable {
  public let chats: [ApiChat]
}

public struct SpaceMembersPayload: Codable, Sendable {
  public let members: [ApiMember]
  public let users: [ApiUser]
  // chats too?
}

public struct PinnedDialogsPayload: Codable, Sendable {
  // Threads you need in sidebar
  public let chats: [ApiChat]
  // Last messages for those threads
  public let messages: [ApiMessage]
  // Users you need in sidebar and senders of last messages
  public let dialogs: [ApiDialog]
}

public struct SendMessage: Codable, Sendable {
  public let message: ApiMessage
}

public struct GetDialogs: Codable, Sendable {
  // Threads
  public let chats: [ApiChat]
  // Last messages for those threads
  public let messages: [ApiMessage]
  // Users you need in sidebar and senders of last messages
  public let dialogs: [ApiDialog]
  // Users mentioned in last messages
  public let users: [ApiUser]
}
