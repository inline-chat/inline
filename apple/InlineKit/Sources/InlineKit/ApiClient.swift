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
  case checkInviteCode
  case logout
  case providerAuthRedeem = "auth/provider/redeem"
  case nativeAppleAuthStart = "auth/provider/native/apple/start"
  case nativeAppleAuthComplete = "auth/provider/native/apple/complete"
  case nativeAppleAuthContinueInvite = "auth/provider/native/apple/continue-invite"
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
    try requireNativeLogin()
    _ = try await InlineProtocolNativeLogin.shared.beginEmail(
      email,
      client: try await Self.inlineProtocolClientInfo()
    )
    return SendCode(existingUser: nil, needsInviteCode: nil, challengeToken: nil)
  }

  public func sendSmsCode(phoneNumber: String) async throws -> SendSmsCode {
    try await auth.requireLoginAllowed()
    try requireNativeLogin()
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

  public func checkInviteCode(_ inviteCode: String) async throws -> CheckInviteCode {
    try await postRequest(
      .checkInviteCode,
      body: ["inviteCode": inviteCode],
      includeToken: false
    )
  }

  /// Completes email login over the native protocol. The email and challenge
  /// token are bound to the pending native login started by `sendCode`.
  public func verifyCode(
    code: String,
    email: String,
    challengeToken: String? = nil,
    inviteCode: String? = nil
  ) async throws -> VerifyCode {
    try await completeNativeLogin(code: code, inviteCode: inviteCode)
  }

  public func verifySmsCode(code: String, phoneNumber: String, inviteCode: String? = nil) async throws -> VerifyCode {
    try await completeNativeLogin(code: code, inviteCode: inviteCode)
  }

  private func requireNativeLogin() throws {
    guard nativeLoginAvailable else { throw InlineProtocolNativeLoginError.unavailable }
  }

  private func completeNativeLogin(code: String, inviteCode: String?) async throws -> VerifyCode {
    try requireNativeLogin()
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

  //    public func getFullSpace(spaceId: Int64) async throws -> FullSpacePayload {
  //        try await request(
  //            .getFullSpace,
  //            queryItems: [URLQueryItem(name: "spaceId", value: "\(spaceId)")],
  //            includeToken: true
  //        )
  //    }

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

/// Result of a completed native code login.
public struct VerifyCode: Sendable {
  public let userId: Int64
  public let user: ApiUser
  public var accountMutationToken: AuthAccountMutationToken?

  public init(user: ApiUser, accountMutationToken: AuthAccountMutationToken? = nil) {
    userId = user.id
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

public struct UpdateProfile: Codable, Sendable {
  public let user: ApiUser
}

public struct SearchContacts: Codable, Sendable {
  public let users: [ApiUser]
}

public struct EmptyPayload: Codable, Sendable {}

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
    let deviceName = ProcessInfo.processInfo.hostName
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
  case working

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

      case .working:
        "Working"

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

      case .working:
        "Working"

      case .recordingVoice:
        "recording voice"
    }
  }
}

public struct SendSmsCode: Codable, Sendable {
  public let existingUser: Bool?
  public let needsInviteCode: Bool?
  public let phoneNumber: String
  public let formattedPhoneNumber: String
}
