import Combine
import Foundation
import InlineConfig
import Logger
import MultipartFormDataKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public enum APIError: Error {
  case invalidURL
  case invalidResponse
  case httpError(statusCode: Int)
  case decodingError(Error)
  case networkError
  case rateLimited
  case error(error: String, errorCode: Int?, description: String?)
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
  case getChatHistory
  case savePushNotification
  case updateStatus
  case sendComposeAction
  case addReaction
  case updateDialog
  case addMember
  case getSpace
  case logout
  case getDraft
  case getUser
  case readMessages
  case updateProfilePhoto
  case deleteMessage
  case createLinearIssue
}

public final class ApiClient: ObservableObject, @unchecked Sendable {
  public static let shared = ApiClient()
  public init() {}

  private let log = Log.scoped("ApiClient")

  public static let baseURL: String = {
    if ProjectConfig.useProductionApi {
      return "https://api.inline.chat/v1"
    }

    #if targetEnvironment(simulator)
    return "http://\(ProjectConfig.devHost):8000/v1"
    #elseif DEBUG && os(iOS)
    return "http://\(ProjectConfig.devHost):8000/v1"
    #elseif DEBUG && os(macOS)
    return "http://\(ProjectConfig.devHost):8000/v1"
    #else
    return "https://api.inline.chat/v1"
    #endif
  }()

  public var baseURL: String { Self.baseURL }

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
        case 200 ... 299:
          let apiResponse = try decoder.decode(APIResponse<T>.self, from: data)
          switch apiResponse {
            case let .success(data):
              return data
            case let .error(error, errorCode, description):
              log.error("Error \(error): \(description ?? "")")
              throw
                APIError
                .error(error: error, errorCode: errorCode, description: description)
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

  private func postRequest<T: Decodable & Sendable>(
    _ path: Path,
    body: [String: Any],
    includeToken: Bool = true
  ) async throws -> T {
    guard let url = URL(string: "\(baseURL)/\(path.rawValue)") else {
      throw APIError.invalidURL
    }
    print("url: \(url)")

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    if let token = Auth.shared.getToken(), includeToken {
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)

      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw APIError.invalidResponse
      }

      switch httpResponse.statusCode {
        case 200 ... 299:
          let apiResponse = try decoder.decode(APIResponse<T>.self, from: data)
          switch apiResponse {
            case let .success(data):
              return data
            case let .error(error, errorCode, description):
              log.error("Error \(error): \(description ?? "")")
              throw APIError.error(error: error, errorCode: errorCode, description: description)
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
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "code", value: code), URLQueryItem(name: "email", value: email),
    ]

    if let sessionInfo = await SessionInfo.get() {
      queryItems.append(URLQueryItem(name: "clientType", value: sessionInfo.clientType))
      queryItems.append(URLQueryItem(name: "clientVersion", value: sessionInfo.clientVersion))
      queryItems.append(URLQueryItem(name: "osVersion", value: sessionInfo.osVersion))
      queryItems.append(URLQueryItem(name: "deviceName", value: sessionInfo.deviceName))
      queryItems.append(URLQueryItem(name: "timezone", value: sessionInfo.timezone))
    }

    let deviceId = try await DeviceIdentifier.shared.getIdentifier()
    queryItems.append(URLQueryItem(name: "deviceId", value: deviceId))

    return try await request(
      .verifyCode,
      queryItems: queryItems,
      includeToken: false
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

    if let firstName {
      queryItems.append(URLQueryItem(name: "firstName", value: firstName))
    }
    if let lastName {
      queryItems.append(URLQueryItem(name: "lastName", value: lastName))
    }
    if let username {
      queryItems.append(URLQueryItem(name: "username", value: username))
    }

    return try await request(.updateProfile, queryItems: queryItems, includeToken: true)
  }

  public func getSpaces() async throws -> GetSpaces {
    try await request(.getSpaces, includeToken: true)
  }

  public func createThread(title: String, spaceId: Int64, emoji: String? = nil) async throws -> CreateThread {
    try await request(
      .createThread,
      queryItems: [
        URLQueryItem(name: "title", value: title),
        URLQueryItem(name: "spaceId", value: "\(spaceId)"),
        URLQueryItem(name: "emoji", value: "\(emoji)"),
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

  public func getUser(userId: Int64) async throws -> GetUser {
    try await request(
      .getUser, queryItems: [URLQueryItem(name: "id", value: "\(userId)")],
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

  public func createPrivateChat(userId: Int64) async throws -> CreatePrivateChat {
    try await request(
      .createPrivateChat,
      queryItems: [URLQueryItem(name: "userId", value: "\(userId)")],
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
    let result: GetPrivateChats = try await request(.getPrivateChats, includeToken: true)
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

  public func sendMessage(
    peerUserId: Int64?,
    peerThreadId: Int64?,
    text: String?,
    randomId: Int64?,
    repliedToMessageId: Int64?,
    date: Double?,
    fileUniqueId: String? = nil
  ) async throws -> SendMessage {
    var body: [String: Any] = [
      "text": text as Any,
    ]

    if let peerUserId {
      body["peerUserId"] = peerUserId
    }

    if let peerThreadId {
      body["peerThreadId"] = peerThreadId
    }

    if let randomId {
      body["randomId"] = "\(randomId)"
    }

    if let repliedToMessageId {
      body["replyToMessageId"] = repliedToMessageId
    }

    if let fileUniqueId {
      body["fileUniqueId"] = fileUniqueId
    }

    return try await postRequest(
      .sendMessage,
      body: body,
      includeToken: true
    )
  }

  public func createLinearIssue(
    text: String,
    messageId: Int64,
    chatId: Int64
  ) async throws -> EmptyPayload {
    try await postRequest(
      .createLinearIssue,
      body: [
        "text": text,
        "messageId": messageId,
        "chatId": chatId,
      ],
      includeToken: true
    )
  }

  public func getChatHistory(peerUserId: Int64?, peerThreadId: Int64?) async throws
    -> GetChatHistory
  {
    var queryItems: [URLQueryItem] = []

    if let peerUserId {
      queryItems.append(URLQueryItem(name: "peerUserId", value: "\(peerUserId)"))
    }

    if let peerThreadId {
      queryItems.append(URLQueryItem(name: "peerThreadId", value: "\(peerThreadId)"))
    }

    return try await request(.getChatHistory, queryItems: queryItems, includeToken: true)
  }

  public func savePushNotification(pushToken: String) async throws -> EmptyPayload {
    try await request(
      .savePushNotification,
      queryItems: [
        URLQueryItem(name: "applePushToken", value: pushToken),
      ],
      includeToken: true
    )
  }

  public func updateStatus(online: Bool) async throws -> EmptyPayload {
    try await request(
      .updateStatus,
      queryItems: [
        URLQueryItem(name: "online", value: online ? "true" : "false"),
      ],
      includeToken: true
    )
  }

  public func sendComposeAction(peerId: Peer, action: ApiComposeAction?) async throws
    -> EmptyPayload
  {
    try await request(
      .sendComposeAction,
      queryItems: [
        URLQueryItem(name: "peerUserId", value: peerId.asUserId().map(String.init)),
        URLQueryItem(
          name: "peerThreadId",
          value: peerId.asThreadId().map(String.init)
        ),
        URLQueryItem(name: "action", value: action?.rawValue),
      ],
      includeToken: true
    )
  }

  public func logout() async throws -> EmptyPayload {
    try await request(.logout, includeToken: true)
  }

  public func addReaction(messageId: Int64, chatId: Int64, emoji: String) async throws
    -> AddReaction
  {
    try await request(
      .addReaction,
      queryItems: [
        URLQueryItem(name: "messageId", value: "\(messageId)"),
        URLQueryItem(name: "chatId", value: "\(chatId)"),
        URLQueryItem(name: "emoji", value: emoji),
      ],
      includeToken: true
    )
  }

  public func updateDialog(
    peerId: Peer,
    pinned: Bool?,
    draft: String?,
    archived: Bool?
  ) async throws -> UpdateDialog {
    var queryItems: [URLQueryItem] = []

    queryItems.append(URLQueryItem(name: "peerUserId", value: peerId.asUserId().map(String.init)))
    queryItems.append(
      URLQueryItem(name: "peerThreadId", value: peerId.asThreadId().map(String.init))
    )

    if let pinned {
      queryItems.append(URLQueryItem(name: "pinned", value: "\(pinned)"))
    }

    if let draft {
      queryItems.append(URLQueryItem(name: "draft", value: draft))
    }
    if let archived {
      queryItems.append(URLQueryItem(name: "archived", value: "\(archived)"))
    }
    return try await request(
      .updateDialog,
      queryItems: queryItems,
      includeToken: true
    )
  }

  public func addMember(spaceId: Int64, userId: Int64) async throws -> AddMember {
    try await request(
      .addMember,
      queryItems: [
        URLQueryItem(name: "spaceId", value: "\(spaceId)"),
        URLQueryItem(name: "userId", value: "\(userId)"),
      ],
      includeToken: true
    )
  }

  public func getSpace(spaceId: Int64) async throws -> GetSpace {
    try await request(
      .getSpace,
      queryItems: [URLQueryItem(name: "id", value: "\(spaceId)")],
      includeToken: true
    )
  }

  public func getDraft(peerId: Peer) async throws -> GetDraft {
    try await request(
      .getDraft,
      queryItems: [URLQueryItem(name: "peerUserId", value: peerId.asUserId().map(String.init))],
      includeToken: true
    )
  }

  public func readMessages(peerId: Peer, maxId: Int64?) async throws
    -> EmptyPayload
  {
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "peerUserId", value: peerId.asUserId().map(String.init)),
      URLQueryItem(
        name: "peerThreadId",
        value: peerId.asThreadId().map(String.init)
      ),
    ]

    if let maxId {
      queryItems.append(URLQueryItem(name: "maxId", value: "\(maxId)"))
    }

    return try await request(
      .readMessages,
      queryItems: queryItems,
      includeToken: true
    )
  }

  public func uploadFile(
    type: MessageFileType,
    data: Data,
    filename: String,
    mimeType: MIMEType,
    progress: @escaping (Double) -> Void
  ) async throws -> UploadFileResult {
    guard let url = URL(string: "\(baseURL)/uploadFile") else {
      throw APIError.invalidURL
    }

    let multipartFormData = try MultipartFormData.Builder.build(
      with: [
        (
          name: "type",
          filename: nil,
          mimeType: nil,
          data: type.rawValue.data(using: .utf8)!
        ),
        (
          name: "file",
          filename: filename,
          mimeType: mimeType,
          data: data
        ),
      ],
      willSeparateBy: RandomBoundaryGenerator.generate()
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(multipartFormData.contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartFormData.body

    if let token = Auth.shared.getToken() {
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw APIError.invalidResponse
      }

      switch httpResponse.statusCode {
        case 200 ... 299:
          let apiResponse = try decoder.decode(APIResponse<UploadFileResult>.self, from: data)
          switch apiResponse {
            case let .success(data):
              return data
            case let .error(error, errorCode, description):
              log.error("Error \(error): \(description ?? "")")
              throw APIError.error(error: error, errorCode: errorCode, description: description)
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

  public func updateProfilePhoto(fileUniqueId: String) async throws
    -> UpdateProfilePhoto
  {
    try await request(
      .updateProfilePhoto,
      queryItems: [
        URLQueryItem(name: "fileUniqueId", value: fileUniqueId),
      ],
      includeToken: true
    )
  }

  public func deleteMessage(messageId: Int64, chatId: Int64, peerId: Peer) async throws
    -> EmptyPayload
  {
    try await request(
      .deleteMessage,
      queryItems: [
        URLQueryItem(name: "messageId", value: "\(messageId)"),
        URLQueryItem(name: "chatId", value: "\(chatId)"),
        URLQueryItem(name: "peerUserId", value: peerId.asUserId().map(String.init)),
        URLQueryItem(name: "peerThreadId", value: peerId.asThreadId().map(String.init)),
      ],
      includeToken: true
    )
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
  case error(error: String, errorCode: Int?, description: String?)

  private enum CodingKeys: String, CodingKey {
    case ok
    case result
    case error
    case errorCode
    case description
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
        error: values.decode(String.self, forKey: .error),
        errorCode: values.decodeIfPresent(Int.self, forKey: .errorCode),
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
  public let dialogs: [ApiDialog]
}

public struct GetUser: Codable, Sendable {
  public let user: ApiUser
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
  public let dialog: ApiDialog
  public let user: ApiUser
}

public struct GetMe: Codable, Sendable {
  public let user: ApiUser
}

public struct EmptyPayload: Codable, Sendable {}

public struct UpdateProfilePhoto: Codable, Sendable {
  public let user: ApiUser
}

public struct GetPrivateChats: Codable, Sendable {
  public let messages: [ApiMessage]
  public let chats: [ApiChat]
  public let dialogs: [ApiDialog]
  public let peerUsers: [ApiUser]
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
  public let updates: [Update]?
}

public struct AddReaction: Codable, Sendable {
  public let reaction: ApiReaction
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

public struct GetChatHistory: Codable, Sendable {
  // Sorted by date asc
  // Limited by 70 by default
  public let messages: [ApiMessage]
}

public struct UpdateDialog: Codable, Sendable {
  public let dialog: ApiDialog
}

public struct AddMember: Codable, Sendable {
  public let member: ApiMember
}

public struct UploadFileResult: Codable, Sendable {
  public let fileUniqueId: String
}

public struct GetSpace: Codable, Sendable {
  public let space: ApiSpace
  public let members: [ApiMember]
  public let chats: [ApiChat]
  public let dialogs: [ApiDialog]
}

public struct GetDraft: Codable, Sendable {
  public let draft: String?
}

struct SessionInfo: Codable, Sendable {
  let clientType: String?
  let clientVersion: String?
  let osVersion: String?
  let deviceName: String?
  let timezone: String?

  @MainActor static func get() -> SessionInfo? {
    let timezone = TimeZone.current.identifier
    let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    // let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    #if os(iOS)
    let clientType = "ios"
    let osVersion = UIDevice.current.systemVersion
    let deviceName = UIDevice.current.name
    return SessionInfo(
      clientType: clientType,
      clientVersion: clientVersion,
      osVersion: osVersion,
      deviceName: deviceName,
      timezone: timezone
    )
    #elseif os(macOS)
    let clientType = "macos"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let deviceName = Host.current().name
    return SessionInfo(
      clientType: clientType,
      clientVersion: clientVersion,
      osVersion: osVersion,
      deviceName: deviceName,
      timezone: timezone
    )
    #else
    return nil
    #endif
  }
}

public enum ApiComposeAction: String, Codable, Sendable {
  case typing
}

public struct LinearAuthUrl: Codable, Sendable {
  public let url: String
}
