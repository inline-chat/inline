import Auth
import Combine
import Foundation
import InlineConfig
import InlineProtocol
import Logger
import MultipartFormDataKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public enum APIError: Error, LocalizedError {
  case invalidURL
  case invalidResponse
  case httpError(statusCode: Int)
  case decodingError(Error)
  case networkError
  case rateLimited
  case error(error: String, errorCode: Int?, description: String?)

  public var errorDescription: String? {
    switch self {
      case .invalidURL:
        "The upload URL is invalid."
      case .invalidResponse:
        "The server returned an invalid response."
      case let .httpError(statusCode):
        "The server returned HTTP \(statusCode)."
      case let .decodingError(error):
        "Failed to decode the server response: \(error.localizedDescription)"
      case .networkError:
        "Network request failed."
      case .rateLimited:
        "Too many requests. Please wait a bit and try again."
      case let .error(_, _, description):
        description ?? "The server rejected the request."
    }
  }
}

public enum Path: String {
  case verifyCode = "verifyEmailCode"
  case sendCode = "sendEmailCode"
  case checkInviteCode
  case createSpace
  case updateProfile
  case getSpaces
  case createThread
  case checkUsername
  case searchContacts
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
  case getIntegrations
  case disconnectIntegration
  case getAlphaText
  case sendSmsCode
  case verifySmsCode
  case providerAuthRedeem = "auth/provider/redeem"
  case nativeAppleAuthStart = "auth/provider/native/apple/start"
  case nativeAppleAuthComplete = "auth/provider/native/apple/complete"
  case nativeAppleAuthContinueInvite = "auth/provider/native/apple/continue-invite"
  case getNotionDatabases
  case saveNotionDatabaseId
  case getLinearTeams
  case saveLinearTeamId
  case createNotionTask
  case deleteAttachment
}

public final class ApiClient: ObservableObject, @unchecked Sendable {
  public static let shared = ApiClient()
  private let urlSession: URLSession
  private let auth: AuthHandle
  private let nativeLoginAvailable: Bool

  public convenience init() {
    self.init(urlSession: .shared)
  }

  init(
    urlSession: URLSession,
    auth: AuthHandle = Auth.shared.handle,
    nativeLoginAvailable: Bool = InlineProtocolNativeLogin.shared.isAvailable
  ) {
    self.urlSession = urlSession
    self.auth = auth
    self.nativeLoginAvailable = nativeLoginAvailable
  }

  private let log = Log.scoped("ApiClient", level: .trace)

  public struct UploadTransferProgress: Sendable, Equatable {
    public let bytesSent: Int64
    public let totalBytes: Int64
    public let fractionCompleted: Double

    public init(bytesSent: Int64, totalBytes: Int64, fractionCompleted: Double) {
      self.bytesSent = max(0, bytesSent)
      self.totalBytes = max(0, totalBytes)
      self.fractionCompleted = min(max(fractionCompleted, 0), 1)
    }
  }

  private final class UploadTaskDelegate: NSObject, URLSessionTaskDelegate {
    private let progressHandler: @Sendable (UploadTransferProgress) -> Void

    init(progressHandler: @escaping @Sendable (UploadTransferProgress) -> Void) {
      self.progressHandler = progressHandler
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      didSendBodyData bytesSent: Int64,
      totalBytesSent: Int64,
      totalBytesExpectedToSend: Int64
    ) {
      let fraction = totalBytesExpectedToSend > 0
        ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        : 0
      progressHandler(
        UploadTransferProgress(
          bytesSent: totalBytesSent,
          totalBytes: totalBytesExpectedToSend,
          fractionCompleted: fraction
        )
      )
    }
  }

  private enum MultipartUploadPart {
    case data(name: String, filename: String?, mimeType: MIMEType?, data: Data)
    case file(name: String, filename: String, mimeType: MIMEType, url: URL)
  }

  private struct MultipartUploadBody {
    let url: URL
    let contentType: String
    let totalBytes: Int64
  }

  public static let serverURL: String = {
    if ProjectConfig.useProductionApi {
      return "https://api.inline.chat"
    }

    #if targetEnvironment(simulator)
    return "http://\(ProjectConfig.devHost):8000"
    #elseif DEBUG && os(iOS)
    return "http://\(ProjectConfig.devHost):8000"
    #elseif DEBUG && os(macOS)
    return "http://\(ProjectConfig.devHost):8000"
    #else
    return "https://api.inline.chat"
    #endif
  }()

  public static let baseURL: String = "\(serverURL)/v1"

  public var baseURL: String { Self.baseURL }

  private let decoder = JSONDecoder()

  /// Cancellation is control flow for superseded searches, navigation, and auth work.
  /// Keep it distinguishable from genuine transport failures so callers do not retry
  /// or present a network alert for work they intentionally cancelled.
  static func normalizeTransportError(_ error: Error) -> Error {
    if error is CancellationError {
      return error
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return CancellationError()
    }
    return APIError.networkError
  }

  private func parseAPIError(_ data: Data) -> APIError? {
    guard !data.isEmpty else {
      return nil
    }

    if let apiResponse = try? decoder.decode(APIResponse<EmptyPayload>.self, from: data),
       case let .error(error, errorCode, description) = apiResponse
    {
      return APIError.error(error: error, errorCode: errorCode, description: description)
    }

    return nil
  }

  private func logHTTPError(
    method: String,
    endpointTemplate: String,
    response: HTTPURLResponse,
    data: Data,
    apiErrorCode: Int? = nil
  ) {
    guard let metadata = HTTPLogMetadata(
      method: method,
      endpointTemplate: endpointTemplate,
      statusCode: response.statusCode,
      requestID: response.value(forHTTPHeaderField: "x-request-id"),
      responseBytes: data.count,
      apiErrorCode: apiErrorCode
    ) else {
      return
    }
    log.httpError(metadata)
  }

  private func request<T: Decodable & Sendable>(
    _ path: Path,
    queryItems: [URLQueryItem] = [],
    includeToken: Bool = false,
    authorizationToken: String? = nil,
    timeoutInterval: TimeInterval? = nil
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
    if let timeoutInterval {
      request.timeoutInterval = timeoutInterval
    }

    if let token = authorizationToken ?? (includeToken ? auth.token() : nil) {
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, response) = try await urlSession.data(for: request)

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
              logHTTPError(
                method: request.httpMethod ?? "GET",
                endpointTemplate: "/v1/\(path.rawValue)",
                response: httpResponse,
                data: data,
                apiErrorCode: errorCode
              )
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
        case 429:
          logHTTPError(
            method: request.httpMethod ?? "GET",
            endpointTemplate: "/v1/\(path.rawValue)",
            response: httpResponse,
            data: data
          )
          throw APIError.rateLimited
        default:
          if let apiError = parseAPIError(data) {
            logHTTPError(
              method: request.httpMethod ?? "GET",
              endpointTemplate: "/v1/\(path.rawValue)",
              response: httpResponse,
              data: data
            )
            throw apiError
          }

          logHTTPError(
            method: request.httpMethod ?? "GET",
            endpointTemplate: "/v1/\(path.rawValue)",
            response: httpResponse,
            data: data
          )
          throw APIError.httpError(statusCode: httpResponse.statusCode)
      }
    } catch let decodingError as DecodingError {
      throw APIError.decodingError(decodingError)
    } catch let apiError as APIError {
      throw apiError
    } catch {
      throw Self.normalizeTransportError(error)
    }
  }

  private func postRequest<T: Decodable & Sendable>(
    _ path: Path,
    body: [String: Any],
    includeToken: Bool = true,
    timeoutInterval: TimeInterval? = nil
  ) async throws -> T {
    do {
      let request = try Self.makeJSONPostRequest(
        path,
        body: body,
        authorizationToken: includeToken ? auth.token() : nil,
        timeoutInterval: timeoutInterval
      )

      let (data, response) = try await urlSession.data(for: request)

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
              logHTTPError(
                method: request.httpMethod ?? "POST",
                endpointTemplate: "/v1/\(path.rawValue)",
                response: httpResponse,
                data: data,
                apiErrorCode: errorCode
              )
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
        case 429:
          logHTTPError(
            method: request.httpMethod ?? "POST",
            endpointTemplate: "/v1/\(path.rawValue)",
            response: httpResponse,
            data: data
          )
          throw APIError.rateLimited
        default:
          if let apiError = parseAPIError(data) {
            logHTTPError(
              method: request.httpMethod ?? "POST",
              endpointTemplate: "/v1/\(path.rawValue)",
              response: httpResponse,
              data: data
            )
            throw apiError
          }

          logHTTPError(
            method: request.httpMethod ?? "POST",
            endpointTemplate: "/v1/\(path.rawValue)",
            response: httpResponse,
            data: data
          )
          throw APIError.httpError(statusCode: httpResponse.statusCode)
      }
    } catch let decodingError as DecodingError {
      throw APIError.decodingError(decodingError)
    } catch let apiError as APIError {
      throw apiError
    } catch {
      throw Self.normalizeTransportError(error)
    }
  }

  static func makeJSONPostRequest(
    _ path: Path,
    body: [String: Any],
    baseURL: String = ApiClient.baseURL,
    authorizationToken: String? = nil,
    timeoutInterval: TimeInterval? = nil
  ) throws -> URLRequest {
    guard let url = URL(string: "\(baseURL)/\(path.rawValue)") else {
      throw APIError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    if let timeoutInterval {
      request.timeoutInterval = timeoutInterval
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    if let authorizationToken {
      request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  // MARK: AUTH

  public func sendCode(email: String) async throws -> SendCode {
    try await auth.requireLoginAllowed()
    if nativeLoginAvailable {
      _ = try await InlineProtocolNativeLogin.shared.beginEmail(
        email,
        client: try await Self.inlineProtocolClientInfo()
      )
      return SendCode(existingUser: nil, needsInviteCode: nil, challengeToken: nil)
    }
    return try await postRequest(
      .sendCode,
      body: ["email": email],
      includeToken: false
    )
  }

  public func sendSmsCode(phoneNumber: String) async throws -> SendSmsCode {
    try await auth.requireLoginAllowed()
    if nativeLoginAvailable {
      _ = try await InlineProtocolNativeLogin.shared.beginPhoneNumber(
        phoneNumber,
        client: try await Self.inlineProtocolClientInfo()
      )
      return SendSmsCode(
        existingUser: nil,
        needsInviteCode: nil,
        phoneNumber: phoneNumber,
        formattedPhoneNumber: phoneNumber
      )
    }
    return try await postRequest(
      .sendSmsCode,
      body: ["phoneNumber": phoneNumber],
      includeToken: false
    )
  }

  public func checkInviteCode(_ inviteCode: String) async throws -> CheckInviteCode {
    try await postRequest(
      .checkInviteCode,
      body: ["inviteCode": inviteCode],
      includeToken: false
    )
  }

  public func verifyCode(
    code: String,
    email: String,
    challengeToken: String? = nil,
    inviteCode: String? = nil
  ) async throws -> VerifyCode {
    if InlineProtocolNativeLogin.shared.isAvailable {
      let result = try await InlineProtocolNativeLogin.shared.complete(
        code: code,
        inviteCode: inviteCode,
        timeZone: TimeZone.current.identifier
      )
      return VerifyCode(
        user: ApiUser(from: result.user),
        accountMutationToken: result.accountMutationToken
      )
    }
    let sessionInfo = await SessionInfo.get()
    let deviceId = try await DeviceIdentifier.shared.getIdentifier()
    let body = Self.makeEmailCodeVerificationBody(
      code: code,
      email: email,
      challengeToken: challengeToken.flatMap { $0.isEmpty ? nil : $0 },
      inviteCode: inviteCode.flatMap { $0.isEmpty ? nil : $0 },
      sessionInfo: sessionInfo,
      deviceId: deviceId
    )

    return try await postRequest(.verifyCode, body: body, includeToken: false)
  }

  static func makeEmailCodeVerificationBody(
    code: String,
    email: String,
    challengeToken: String?,
    inviteCode: String?,
    sessionInfo: SessionInfo?,
    deviceId: String
  ) -> [String: Any] {
    var body: [String: Any] = [
      "code": code,
      "email": email,
      "deviceId": deviceId,
    ]
    for (key, optionalValue) in [
      "challengeToken": challengeToken,
      "inviteCode": inviteCode,
      "clientType": sessionInfo?.clientType,
      "clientVersion": sessionInfo?.clientVersion,
      "osVersion": sessionInfo?.osVersion,
      "deviceName": sessionInfo?.deviceName,
      "timezone": sessionInfo?.timezone,
    ] {
      if let value = optionalValue {
        body[key] = value
      }
    }
    return body
  }

  private static func inlineProtocolClientInfo() async throws -> InlineProtocol.ClientInfo {
    let sessionInfo = await SessionInfo.get()
    var client = InlineProtocol.ClientInfo()
    client.deviceID = try await DeviceIdentifier.shared.getIdentifier()
    if let value = sessionInfo?.clientType { client.clientType = value }
    if let value = sessionInfo?.clientVersion { client.clientVersion = value }
    if let value = sessionInfo?.osVersion { client.osVersion = value }
    if let value = sessionInfo?.deviceName { client.deviceName = value }
    return client
  }

  public func verifySmsCode(code: String, phoneNumber: String, inviteCode: String? = nil) async throws -> VerifyCode {
    if InlineProtocolNativeLogin.shared.isAvailable {
      let result = try await InlineProtocolNativeLogin.shared.complete(
        code: code,
        inviteCode: inviteCode,
        timeZone: TimeZone.current.identifier
      )
      return VerifyCode(
        user: ApiUser(from: result.user),
        accountMutationToken: result.accountMutationToken
      )
    }
    var body: [String: Any] = [
      "code": code,
      "phoneNumber": phoneNumber,
    ]

    if let inviteCode, !inviteCode.isEmpty {
      body["inviteCode"] = inviteCode
    }

    if let sessionInfo = await SessionInfo.get() {
      body["clientType"] = sessionInfo.clientType
      body["clientVersion"] = sessionInfo.clientVersion
      body["osVersion"] = sessionInfo.osVersion
      body["deviceName"] = sessionInfo.deviceName
      body["timezone"] = sessionInfo.timezone
    }

    let deviceId = try await DeviceIdentifier.shared.getIdentifier()
    body["deviceId"] = deviceId

    return try await postRequest(
      .verifySmsCode,
      body: body,
      includeToken: false
    )
  }

  public func redeemProviderAuth(ticket: String, codeVerifier: String) async throws -> ProviderAuthRedeemResult {
    try await postRequest(
      .providerAuthRedeem,
      body: ["ticket": ticket, "code_verifier": codeVerifier],
      includeToken: false,
      timeoutInterval: 15
    )
  }

  public func startNativeAppleAuth(codeChallenge: String) async throws -> NativeAppleAuthStartResult {
    let sessionInfo = await SessionInfo.get()
    let deviceId = try await DeviceIdentifier.shared.getIdentifier()
    var body: [String: Any] = [
      "callbackScheme": InlineDeepLink.configuredScheme,
      "codeChallenge": codeChallenge,
      "clientType": "ios",
      "deviceId": deviceId,
    ]
    for (key, value) in [
      "clientVersion": sessionInfo?.clientVersion,
      "osVersion": sessionInfo?.osVersion,
      "deviceName": sessionInfo?.deviceName,
      "timezone": sessionInfo?.timezone,
    ] {
      if let value, !value.isEmpty { body[key] = value }
    }
    return try await postRequest(.nativeAppleAuthStart, body: body, includeToken: false)
  }

  public func completeNativeAppleAuth(
    state: String,
    authorizationCode: String,
    identityToken: String,
    firstName: String?,
    lastName: String?
  ) async throws -> NativeAppleAuthCompleteResult {
    var body: [String: Any] = [
      "state": state,
      "authorizationCode": authorizationCode,
      "identityToken": identityToken,
    ]
    if let firstName, !firstName.isEmpty { body["firstName"] = firstName }
    if let lastName, !lastName.isEmpty { body["lastName"] = lastName }
    return try await postRequest(.nativeAppleAuthComplete, body: body, includeToken: false)
  }

  public func continueNativeAppleAuth(
    attemptId: String,
    continuation: String,
    inviteCode: String
  ) async throws -> NativeAppleAuthInviteResult {
    try await postRequest(
      .nativeAppleAuthContinueInvite,
      body: [
        "attemptId": attemptId,
        "continuation": continuation,
        "inviteCode": inviteCode,
      ],
      includeToken: false
    )
  }

  public func createSpace(name: String) async throws -> CreateSpace {
    try await request(
      .createSpace, queryItems: [URLQueryItem(name: "name", value: name)], includeToken: true
    )
  }

  public func updateProfile(
    firstName: String?,
    lastName: String?,
    username: String?,
    timeZone: String? = nil
  ) async throws
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
    if let timeZone {
      queryItems.append(URLQueryItem(name: "timeZone", value: timeZone))
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
        URLQueryItem(name: "emoji", value: emoji),
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
    fileUniqueId: String? = nil,
    isSticker: Bool? = nil
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

    if let isSticker {
      body["isSticker"] = isSticker
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
    peerId: Peer,
    chatId: Int64,
    fromId: Int64,
    spaceId: Int64? = nil
  ) async throws -> CreateLinearIssue {
    var body: [String: Any] = [
      "text": text,
      "messageId": messageId,
      "chatId": chatId,
      "fromId": fromId,
    ]

    // Create a proper peerId object structure as expected by the server
    var peerIdObject: [String: Any] = [:]

    if let userId = peerId.asUserId() {
      peerIdObject["userId"] = userId
    } else if let threadId = peerId.asThreadId() {
      peerIdObject["threadId"] = threadId
    }

    // Add the peerId object to the body
    body["peerId"] = peerIdObject
    if let spaceId {
      body["spaceId"] = spaceId
    }

    return try await postRequest(
      .createLinearIssue,
      body: body,
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

  public func disconnectIntegration(spaceId: Int64, provider: String) async throws -> DisconnectIntegration {
    try await request(
      .disconnectIntegration,
      queryItems: [
        URLQueryItem(name: "spaceId", value: "\(spaceId)"),
        URLQueryItem(name: "provider", value: provider),
      ],
      includeToken: true
    )
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
    return try await request(
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

  public func logout(
    bearerToken: String,
    timeoutInterval: TimeInterval = 2
  ) async throws -> EmptyPayload {
    try await request(
      .logout,
      authorizationToken: bearerToken,
      timeoutInterval: timeoutInterval
    )
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
    archived: Bool?,
    order: String? = nil,
    pinnedOrder: String? = nil
  ) async throws -> UpdateDialog {
    var queryItems: [URLQueryItem] = []

    queryItems.append(URLQueryItem(name: "peerUserId", value: peerId.asUserId().map(String.init)))
    queryItems.append(
      URLQueryItem(name: "peerThreadId", value: peerId.asThreadId().map(String.init))
    )

    if let pinned {
      queryItems.append(URLQueryItem(name: "pinned", value: "\(pinned)"))
    }

    if let archived {
      queryItems.append(URLQueryItem(name: "archived", value: "\(archived)"))
    }
    if let order {
      queryItems.append(URLQueryItem(name: "order", value: order))
    }
    if let pinnedOrder {
      queryItems.append(URLQueryItem(name: "pinnedOrder", value: pinnedOrder))
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

  public struct VideoUploadMetadata: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let duration: Int
    public let thumbnail: Data?
    public let thumbnailMimeType: MIMEType?
    public let isAnimated: Bool
    public let hasAudio: Bool?

    public init(
      width: Int,
      height: Int,
      duration: Int,
      thumbnail: Data?,
      thumbnailMimeType: MIMEType?,
      isAnimated: Bool = false,
      hasAudio: Bool? = nil
    ) {
      self.width = width
      self.height = height
      self.duration = duration
      self.thumbnail = thumbnail
      self.thumbnailMimeType = thumbnailMimeType
      self.isAnimated = isAnimated
      self.hasAudio = hasAudio
    }
  }

  public struct VoiceUploadMetadata: Sendable {
    public let duration: Int
    public let waveform: Data

    public init(duration: Int, waveform: Data) {
      self.duration = duration
      self.waveform = waveform
    }
  }

  public struct ThumbnailUploadMetadata: @unchecked Sendable {
    public let data: Data
    public let mimeType: MIMEType

    public init(data: Data, mimeType: MIMEType) {
      self.data = data
      self.mimeType = mimeType
    }
  }

  private func escapedMultipartQuotedString(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "\n", with: "")
  }

  private func writeMultipartString(_ string: String, to handle: FileHandle) throws {
    try handle.write(contentsOf: Data(string.utf8))
  }

  private func writeMultipartFile(from sourceURL: URL, to handle: FileHandle) throws {
    try Task.checkCancellation()
    let input = try FileHandle(forReadingFrom: sourceURL)
    defer { try? input.close() }

    while true {
      try Task.checkCancellation()
      let chunk = try input.read(upToCount: 512 * 1024)
      guard let chunk, !chunk.isEmpty else { break }
      try handle.write(contentsOf: chunk)
    }
  }

  private func makeMultipartUploadBody(parts: [MultipartUploadPart]) throws -> MultipartUploadBody {
    let boundary = "inline-\(UUID().uuidString)"
    let bodyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-upload-\(UUID().uuidString).tmp")

    guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let handle: FileHandle
    do {
      handle = try FileHandle(forWritingTo: bodyURL)
    } catch {
      try? FileManager.default.removeItem(at: bodyURL)
      throw error
    }
    var shouldKeepBody = false
    defer {
      try? handle.close()
      if !shouldKeepBody {
        try? FileManager.default.removeItem(at: bodyURL)
      }
    }

    for part in parts {
      try Task.checkCancellation()
      try writeMultipartString("--\(boundary)\r\n", to: handle)

      switch part {
      case let .data(name, filename, mimeType, data):
        var disposition = "Content-Disposition: form-data; name=\"\(escapedMultipartQuotedString(name))\""
        if let filename {
          disposition += "; filename=\"\(escapedMultipartQuotedString(filename))\""
        }
        try writeMultipartString("\(disposition)\r\n", to: handle)
        if let mimeType {
          try writeMultipartString("Content-Type: \(mimeType.text)\r\n", to: handle)
        }
        try writeMultipartString("\r\n", to: handle)
        try handle.write(contentsOf: data)
        try writeMultipartString("\r\n", to: handle)

      case let .file(name, filename, mimeType, url):
        let disposition = "Content-Disposition: form-data; name=\"\(escapedMultipartQuotedString(name))\"; filename=\"\(escapedMultipartQuotedString(filename))\""
        try writeMultipartString("\(disposition)\r\n", to: handle)
        try writeMultipartString("Content-Type: \(mimeType.text)\r\n", to: handle)
        try writeMultipartString("\r\n", to: handle)
        try writeMultipartFile(from: url, to: handle)
        try writeMultipartString("\r\n", to: handle)
      }
    }

    try writeMultipartString("--\(boundary)--\r\n", to: handle)
    try handle.synchronize()

    let totalBytes = try bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
    shouldKeepBody = true
    return MultipartUploadBody(
      url: bodyURL,
      contentType: "multipart/form-data; boundary=\(boundary)",
      totalBytes: totalBytes
    )
  }

  private func uploadMultipartBody(
    _ body: MultipartUploadBody,
    to url: URL,
    progress: @escaping @Sendable (UploadTransferProgress) -> Void
  ) async throws -> UploadFileResult {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")

    if let token = auth.token() {
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let delegate = UploadTaskDelegate(progressHandler: progress)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer {
      session.invalidateAndCancel()
      try? FileManager.default.removeItem(at: body.url)
    }

    progress(UploadTransferProgress(bytesSent: 0, totalBytes: body.totalBytes, fractionCompleted: 0))
    let (data, response) = try await session.upload(for: request, fromFile: body.url)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.invalidResponse
    }

    switch httpResponse.statusCode {
    case 200 ... 299:
      let apiResponse = try decoder.decode(APIResponse<UploadFileResult>.self, from: data)
      switch apiResponse {
      case let .success(data):
        progress(UploadTransferProgress(bytesSent: body.totalBytes, totalBytes: body.totalBytes, fractionCompleted: 1))
        return data
      case let .error(error, errorCode, description):
        logHTTPError(
          method: request.httpMethod ?? "POST",
          endpointTemplate: "/v1/uploadFile",
          response: httpResponse,
          data: data,
          apiErrorCode: errorCode
        )
        throw APIError.error(error: error, errorCode: errorCode, description: description)
      }
    case 429:
      logHTTPError(
        method: request.httpMethod ?? "POST",
        endpointTemplate: "/v1/uploadFile",
        response: httpResponse,
        data: data
      )
      if let apiResponse = try? decoder.decode(APIResponse<UploadFileResult>.self, from: data),
         case let .error(error, errorCode, description) = apiResponse
      {
        throw APIError.error(error: error, errorCode: errorCode, description: description)
      }
      throw APIError.rateLimited
    default:
      logHTTPError(
        method: request.httpMethod ?? "POST",
        endpointTemplate: "/v1/uploadFile",
        response: httpResponse,
        data: data
      )
      if let apiResponse = try? decoder.decode(APIResponse<UploadFileResult>.self, from: data),
         case let .error(error, errorCode, description) = apiResponse
      {
        throw APIError.error(error: error, errorCode: errorCode, description: description)
      }
      throw APIError.httpError(statusCode: httpResponse.statusCode)
    }
  }

  private func uploadFileParts(
    type: MessageFileType,
    filePart: MultipartUploadPart,
    videoMetadata: VideoUploadMetadata?,
    thumbnailMetadata: ThumbnailUploadMetadata?,
    voiceMetadata: VoiceUploadMetadata?
  ) -> [MultipartUploadPart] {
    var parts: [MultipartUploadPart] = [
      .data(name: "type", filename: nil, mimeType: nil, data: Data(type.rawValue.utf8)),
      filePart,
    ]

    if let videoMetadata {
      parts.append(contentsOf: [
        .data(name: "width", filename: nil, mimeType: nil, data: Data("\(videoMetadata.width)".utf8)),
        .data(name: "height", filename: nil, mimeType: nil, data: Data("\(videoMetadata.height)".utf8)),
        .data(name: "duration", filename: nil, mimeType: nil, data: Data("\(videoMetadata.duration)".utf8)),
        .data(name: "isAnimated", filename: nil, mimeType: nil, data: Data("\(videoMetadata.isAnimated)".utf8)),
      ])

      if let hasAudio = videoMetadata.hasAudio {
        parts.append(.data(name: "hasAudio", filename: nil, mimeType: nil, data: Data("\(hasAudio)".utf8)))
      }
    }

    let resolvedThumbnail = thumbnailMetadata ?? videoMetadata.flatMap { metadata in
      guard let data = metadata.thumbnail, let mimeType = metadata.thumbnailMimeType else { return nil }
      return ThumbnailUploadMetadata(data: data, mimeType: mimeType)
    }
    if let resolvedThumbnail {
      parts.append(.data(
        name: "thumbnail",
        filename: thumbnailFilename(for: resolvedThumbnail.mimeType),
        mimeType: resolvedThumbnail.mimeType,
        data: resolvedThumbnail.data
      ))
    }

    if let voiceMetadata {
      parts.append(contentsOf: [
        .data(name: "duration", filename: nil, mimeType: nil, data: Data("\(voiceMetadata.duration)".utf8)),
        .data(name: "waveform", filename: nil, mimeType: nil, data: voiceMetadata.waveform.base64EncodedData()),
      ])
    }

    return parts
  }

  public func uploadFile(
    type: MessageFileType,
    data: Data,
    filename: String,
    mimeType: MIMEType,
    videoMetadata: VideoUploadMetadata? = nil,
    thumbnailMetadata: ThumbnailUploadMetadata? = nil,
    voiceMetadata: VoiceUploadMetadata? = nil,
    progress: @escaping @Sendable (UploadTransferProgress) -> Void
  ) async throws -> UploadFileResult {
    let sourceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-native-upload-source-\(UUID().uuidString)")
    try data.write(to: sourceURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    return try await nativeUploadFile(
      type: type,
      fileURL: sourceURL,
      filename: filename,
      mimeType: mimeType,
      videoMetadata: videoMetadata,
      thumbnailMetadata: thumbnailMetadata,
      voiceMetadata: voiceMetadata,
      progress: progress
    )
    /* Legacy multipart implementation retained temporarily for source compatibility.
    guard let url = URL(string: "\(baseURL)/uploadFile") else {
      throw APIError.invalidURL
    }

    log.debug("[uploadFile] Uploading type \(type), \(data.count) bytes")

    var fields: [(name: String, filename: String?, mimeType: MIMEType?, data: Data)] = [
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
    ]

    if let videoMetadata {
      fields.append(contentsOf: [
        (name: "width", filename: nil, mimeType: nil, data: "\(videoMetadata.width)".data(using: .utf8)!),
        (name: "height", filename: nil, mimeType: nil, data: "\(videoMetadata.height)".data(using: .utf8)!),
        (name: "duration", filename: nil, mimeType: nil, data: "\(videoMetadata.duration)".data(using: .utf8)!),
        (name: "isAnimated", filename: nil, mimeType: nil, data: "\(videoMetadata.isAnimated)".data(using: .utf8)!),
      ])

      if let hasAudio = videoMetadata.hasAudio {
        fields.append((
          name: "hasAudio",
          filename: nil,
          mimeType: nil,
          data: "\(hasAudio)".data(using: .utf8)!
        ))
      }
    }

    let resolvedThumbnail = thumbnailMetadata ?? videoMetadata.flatMap { metadata in
      guard let data = metadata.thumbnail, let mimeType = metadata.thumbnailMimeType else { return nil }
      return ThumbnailUploadMetadata(data: data, mimeType: mimeType)
    }
    if let resolvedThumbnail {
      fields.append((
        name: "thumbnail",
        filename: thumbnailFilename(for: resolvedThumbnail.mimeType),
        mimeType: resolvedThumbnail.mimeType,
        data: resolvedThumbnail.data
      ))
    }

    if let voiceMetadata {
      fields.append(contentsOf: [
        (name: "duration", filename: nil, mimeType: nil, data: "\(voiceMetadata.duration)".data(using: .utf8)!),
        (name: "waveform", filename: nil, mimeType: nil, data: voiceMetadata.waveform.base64EncodedData()),
      ])
    }

    let multipartFormData = try MultipartFormData.Builder.build(
      with: fields,
      willSeparateBy: RandomBoundaryGenerator.generate()
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(multipartFormData.contentType, forHTTPHeaderField: "Content-Type")

    if let token = auth.token() {
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let delegate = UploadTaskDelegate(progressHandler: progress)
      let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
      let tempUploadFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("inline-upload-\(UUID().uuidString).tmp")
      defer {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: tempUploadFileURL)
      }
      try multipartFormData.body.write(to: tempUploadFileURL, options: .atomic)

      let totalBodyBytes = Int64(multipartFormData.body.count)
      progress(UploadTransferProgress(bytesSent: 0, totalBytes: totalBodyBytes, fractionCompleted: 0))
      let (data, response) = try await session.upload(for: request, fromFile: tempUploadFileURL)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw APIError.invalidResponse
      }

      switch httpResponse.statusCode {
        case 200 ... 299:
          let apiResponse = try decoder.decode(APIResponse<UploadFileResult>.self, from: data)
          switch apiResponse {
            case let .success(data):
              progress(UploadTransferProgress(bytesSent: totalBodyBytes, totalBytes: totalBodyBytes, fractionCompleted: 1))
              return data
            case let .error(error, errorCode, description):
              logHTTPError(
                method: request.httpMethod ?? "POST",
                endpointTemplate: "/v1/uploadFile",
                response: httpResponse,
                data: data,
                apiErrorCode: errorCode
              )
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
        case 429:
          logHTTPError(
            method: request.httpMethod ?? "POST",
            endpointTemplate: "/v1/uploadFile",
            response: httpResponse,
            data: data
          )
          if let apiResponse = try? decoder.decode(APIResponse<UploadFileResult>.self, from: data),
             case let .error(error, errorCode, description) = apiResponse
          {
            throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
          throw APIError.rateLimited
        default:
          logHTTPError(
            method: request.httpMethod ?? "POST",
            endpointTemplate: "/v1/uploadFile",
            response: httpResponse,
            data: data
          )
          if let apiResponse = try? decoder.decode(APIResponse<UploadFileResult>.self, from: data),
             case let .error(error, errorCode, description) = apiResponse
          {
            throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
          throw APIError.httpError(statusCode: httpResponse.statusCode)
      }
    } catch let decodingError as DecodingError {
      throw APIError.decodingError(decodingError)
    } catch let apiError as APIError {
      throw apiError
    } catch {
      throw Self.normalizeTransportError(error)
    }
    */
  }

  public func uploadFile(
    type: MessageFileType,
    fileURL: URL,
    filename: String,
    mimeType: MIMEType,
    videoMetadata: VideoUploadMetadata? = nil,
    thumbnailMetadata: ThumbnailUploadMetadata? = nil,
    voiceMetadata: VoiceUploadMetadata? = nil,
    progress: @escaping @Sendable (UploadTransferProgress) -> Void
  ) async throws -> UploadFileResult {
    return try await nativeUploadFile(
      type: type,
      fileURL: fileURL,
      filename: filename,
      mimeType: mimeType,
      videoMetadata: videoMetadata,
      thumbnailMetadata: thumbnailMetadata,
      voiceMetadata: voiceMetadata,
      progress: progress
    )
    /* Legacy multipart implementation retained temporarily for source compatibility.
    guard let url = URL(string: "\(baseURL)/uploadFile") else {
      throw APIError.invalidURL
    }

    do {
      try Task.checkCancellation()
      let parts = uploadFileParts(
        type: type,
        filePart: .file(name: "file", filename: filename, mimeType: mimeType, url: fileURL),
        videoMetadata: videoMetadata,
        thumbnailMetadata: thumbnailMetadata,
        voiceMetadata: voiceMetadata
      )
      let body = try makeMultipartUploadBody(parts: parts)
      defer { try? FileManager.default.removeItem(at: body.url) }
      try Task.checkCancellation()
      return try await uploadMultipartBody(body, to: url, progress: progress)
    } catch let decodingError as DecodingError {
      throw APIError.decodingError(decodingError)
    } catch let apiError as APIError {
      throw apiError
    } catch let urlError as URLError {
      throw Self.normalizeTransportError(urlError)
    }
    */
  }

  private func nativeUploadFile(
    type: MessageFileType,
    fileURL: URL,
    filename: String,
    mimeType: MIMEType,
    videoMetadata: VideoUploadMetadata?,
    thumbnailMetadata: ThumbnailUploadMetadata?,
    voiceMetadata: VoiceUploadMetadata?,
    progress: @escaping @Sendable (UploadTransferProgress) -> Void
  ) async throws -> UploadFileResult {
    let resolvedThumbnail = thumbnailMetadata ?? videoMetadata.flatMap { metadata in
      guard let data = metadata.thumbnail, let mimeType = metadata.thumbnailMimeType else { return nil }
      return ThumbnailUploadMetadata(data: data, mimeType: mimeType)
    }
    var thumbnailURL: URL?
    defer {
      if let thumbnailURL { try? FileManager.default.removeItem(at: thumbnailURL) }
    }
    var thumbnailFileUniqueID: String?
    if let resolvedThumbnail {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("inline-native-upload-thumbnail-\(UUID().uuidString)")
      try resolvedThumbnail.data.write(to: url, options: .atomic)
      thumbnailURL = url
      let thumbnail = try await DurableUploadCoordinator.shared.upload(
        NativeMediaUploadRequest(
          logicalID: UUID().uuidString,
          fileURL: url,
          fileName: thumbnailFilename(for: resolvedThumbnail.mimeType),
          mimeType: resolvedThumbnail.mimeType.text,
          kind: .photo
        ),
        progress: { _, _ in }
      )
      thumbnailFileUniqueID = thumbnail.fileUniqueID
    }

    let kind: UploadKind
    let metadata: CreateUploadInput.OneOf_Metadata?
    switch type {
    case .photo:
      kind = .photo
      metadata = nil
    case .document:
      kind = .document
      metadata = nil
    case .video:
      guard let videoMetadata else { throw APIError.invalidResponse }
      var value = UploadVideoMetadata()
      value.width = UInt32(videoMetadata.width)
      value.height = UInt32(videoMetadata.height)
      value.duration = UInt32(videoMetadata.duration)
      value.isAnimated = videoMetadata.isAnimated
      if let hasAudio = videoMetadata.hasAudio { value.hasAudio_p = hasAudio }
      kind = .video
      metadata = .video(value)
    case .voice:
      guard let voiceMetadata else { throw APIError.invalidResponse }
      var value = UploadVoiceMetadata()
      value.duration = UInt32(max(0, voiceMetadata.duration))
      value.waveform = voiceMetadata.waveform
      kind = .voice
      metadata = .voice(value)
    }
    let complete = try await DurableUploadCoordinator.shared.upload(
      NativeMediaUploadRequest(
        logicalID: UUID().uuidString,
        fileURL: fileURL,
        fileName: filename,
        mimeType: mimeType.text,
        kind: kind,
        thumbnailFileUniqueID: thumbnailFileUniqueID,
        metadata: metadata
      ),
      progress: { sent, total in
        progress(UploadTransferProgress(
          bytesSent: sent,
          totalBytes: total,
          fractionCompleted: total > 0 ? Double(sent) / Double(total) : 0
        ))
      }
    )
    switch complete.media {
    case let .photo(photo):
      return UploadFileResult(fileUniqueId: complete.fileUniqueID, photoId: photo.id)
    case let .video(video):
      return UploadFileResult(fileUniqueId: complete.fileUniqueID, videoId: video.id)
    case let .document(document):
      return UploadFileResult(fileUniqueId: complete.fileUniqueID, documentId: document.id)
    case let .voice(voice):
      return UploadFileResult(fileUniqueId: complete.fileUniqueID, voiceId: voice.id)
    case nil:
      throw NativeMediaUploadError.unexpectedResponse
    }
  }

  private func thumbnailFilename(for mimeType: MIMEType) -> String {
    let mime = mimeType.text.lowercased()
    if mime.contains("png") { return "thumbnail.png" }
    if mime.contains("gif") { return "thumbnail.gif" }
    return "thumbnail.jpg"
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

  public func getIntegrations(userId: Int64, spaceId: Int64? = nil) async throws -> GetIntegrations {
    var queryItems = [URLQueryItem(name: "userId", value: "\(userId)")]
    if let spaceId, spaceId > 0 {
      queryItems.append(URLQueryItem(name: "spaceId", value: "\(spaceId)"))
    }

    return try await request(
      .getIntegrations,
      queryItems: queryItems,
      includeToken: true
    )
  }

  public func getAlphaText() async throws -> String {
    try await request(.getAlphaText, includeToken: false)
  }

  public func getNotionDatabases(spaceId: Int64) async throws -> [NotionSimplifiedDatabase] {
    try await request(
      .getNotionDatabases,
      queryItems: [URLQueryItem(name: "spaceId", value: "\(spaceId)")],
      includeToken: true
    )
  }

  public func saveNotionDatabaseId(spaceId: Int64, databaseId: String) async throws -> EmptyPayload {
    try await request(
      .saveNotionDatabaseId,
      queryItems: [
        URLQueryItem(name: "spaceId", value: "\(spaceId)"),
        URLQueryItem(name: "databaseId", value: databaseId),
      ],
      includeToken: true
    )
  }

  public func getLinearTeams(spaceId: Int64) async throws -> [LinearTeam] {
    try await request(
      .getLinearTeams,
      queryItems: [URLQueryItem(name: "spaceId", value: "\(spaceId)")],
      includeToken: true
    )
  }

  public func saveLinearTeamId(spaceId: Int64, teamId: String) async throws -> EmptyPayload {
    try await request(
      .saveLinearTeamId,
      queryItems: [
        URLQueryItem(name: "spaceId", value: "\(spaceId)"),
        URLQueryItem(name: "teamId", value: teamId),
      ],
      includeToken: true
    )
  }

  public func createNotionTask(
    spaceId: Int64,
    messageId: Int64,
    chatId: Int64,
    peerId: Peer
  ) async throws -> NotionTaskResult {
    var peerIdObject: [String: Any] = [:]

    if let userId = peerId.asUserId() {
      peerIdObject["userId"] = userId
    } else if let threadId = peerId.asThreadId() {
      peerIdObject["threadId"] = threadId
    }

    return try await postRequest(
      .createNotionTask,
      body: [
        "spaceId": spaceId,
        "messageId": messageId,
        "chatId": chatId,
        "peerId": peerIdObject,
      ],
      includeToken: true
    )
  }

  public func deleteAttachment(
    externalTaskId: Int64,
    pageId: String,
    messageId: Int64,
    chatId: Int64
  ) async throws -> EmptyPayload {
    try await postRequest(
      .deleteAttachment,
      body: [
        "externalTaskId": externalTaskId,
        "pageId": pageId,
        "messageId": messageId,
        "chatId": chatId,
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

public struct NotionTaskResult: Codable, Sendable {
  public let url: String
  public let taskTitle: String
}

public struct GetIntegrations: Codable, Sendable {
  public let hasLinearConnected: Bool
  public let hasNotionConnected: Bool
  public let hasIntegrationAccess: Bool
  public let linearTeamId: String?
  public let notionDatabaseId: String?
  public let notionSpaces: [NotionSpace]?
  public let linearSpaces: [LinearSpace]?

  // Computed property for easy access to first Notion space
  public var firstNotionSpace: NotionSpace? {
    notionSpaces?.first
  }
}

public struct NotionSpace: Codable, Sendable {
  public let spaceId: Int64
  public let spaceName: String
}

public struct LinearSpace: Codable, Sendable {
  public let spaceId: Int64
  public let spaceName: String
}

public struct NotionSimplifiedDatabase: Codable, Sendable {
  public let id: String
  public let title: String
  public let icon: String?
}

public struct LinearTeam: Codable, Sendable {
  public let id: String
  public let name: String
  public let key: String
}

public struct CreateLinearIssue: Codable, Sendable {
  public let link: String?
}

public struct DisconnectIntegration: Codable, Sendable {
  public let ok: Bool
}

public struct VerifyCode: Codable, Sendable {
  public let userId: Int64
  public let token: String?
  public let user: ApiUser
  public var accountMutationToken: AuthAccountMutationToken? = nil

  enum CodingKeys: String, CodingKey {
    case userId
    case token
    case user
  }

  public init(
    user: ApiUser,
    token: String? = nil,
    accountMutationToken: AuthAccountMutationToken? = nil
  ) {
    userId = user.id
    self.token = token
    self.user = user
    self.accountMutationToken = accountMutationToken
  }
}

public struct ProviderAuthRedeemResult: Codable, Sendable {
  public let userId: Int64
  public let token: String
  public let user: ApiUser
}

public struct NativeAppleAuthStartResult: Codable, Sendable {
  public let state: String
  public let nonce: String
}

public enum NativeAppleAuthCompleteKind: String, Codable, Sendable {
  case complete
  case inviteRequired
}

public struct NativeAppleAuthCompleteResult: Codable, Sendable {
  public let kind: NativeAppleAuthCompleteKind
  public let ticket: String?
  public let attemptId: String?
  public let continuation: String?
}

public struct NativeAppleAuthInviteResult: Codable, Sendable {
  public let ticket: String
}

public struct SendCode: Codable, Sendable {
  public let existingUser: Bool?
  public let needsInviteCode: Bool?
  public let challengeToken: String?
}

public struct CheckInviteCode: Codable, Sendable {
  public let valid: Bool
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
  public let photoId: Int64?
  public let videoId: Int64?
  public let documentId: Int64?
  public let voiceId: Int64?

  public init(
    fileUniqueId: String,
    photoId: Int64? = nil,
    videoId: Int64? = nil,
    documentId: Int64? = nil,
    voiceId: Int64? = nil
  ) {
    self.fileUniqueId = fileUniqueId
    self.photoId = photoId
    self.videoId = videoId
    self.documentId = documentId
    self.voiceId = voiceId
  }
}

public struct GetSpace: Codable, Sendable {
  public let space: ApiSpace
  public let members: [ApiMember]
//  public let chats: [ApiChat]
//  public let dialogs: [ApiDialog]
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
    let timezone = TimeZone.autoupdatingCurrent.identifier
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
  case uploadingPhoto
  case uploadingDocument
  case uploadingVideo
  case recordingVoice

  public func toHumanReadable() -> String {
    switch self {
      case .typing:
        "typing..."

      case .uploadingPhoto:
        "uploading photo..."

      case .uploadingDocument:
        "uploading document..."

      case .uploadingVideo:
        "uploading video..."

      case .recordingVoice:
        "recording voice..."
    }
  }

  public func toHumanReadableForIOS() -> String {
    switch self {
      case .typing:
        "typing"

      case .uploadingPhoto:
        "uploading photo"

      case .uploadingDocument:
        "uploading document"

      case .uploadingVideo:
        "uploading video"

      case .recordingVoice:
        "recording voice"
    }
  }
}

public struct LinearAuthUrl: Codable, Sendable {
  public let url: String
}

public struct SendSmsCode: Codable, Sendable {
  public let existingUser: Bool?
  public let needsInviteCode: Bool?
  public let phoneNumber: String
  public let formattedPhoneNumber: String
}
