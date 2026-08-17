import Auth
import Foundation
import InlineConfig
import InlineProtocol
import Logger

public enum InlineProtocolNativeLoginError: Error, Sendable {
  case unavailable
  case noPendingChallenge
  case inviteRequired
  case invalidResponse
}

public struct InlineProtocolNativeLoginResult: Sendable {
  public let user: InlineProtocol.User
  public let userId: Int64
  public let accountSessionId: Int64
}

public actor InlineProtocolNativeLogin {
  public static let shared = InlineProtocolNativeLogin()

  private struct Pending {
    let challengeID: Data
    let connection: InlineProtocolV3Connection
  }

  private let auth: AuthHandle
  private let log = Log.scoped("InlineProtocol.Login")
  private let url: URL
  private let rsaPublicKeys: [InlineProtocolRSAPublicKey]
  private var pending: Pending?

  public nonisolated var isAvailable: Bool { !rsaPublicKeys.isEmpty }

  public init(
    auth: AuthHandle = Auth.shared.handle,
    url: URL? = nil,
    rsaPublicKeys: [InlineProtocolRSAPublicKey] = InlineProtocolTrustRoots.production
  ) {
    self.auth = auth
    self.url = url ?? URL(string: InlineConfig.realtimeServerURL.replacingOccurrences(
      of: "/realtime", with: "/realtime/v3"
    ))!
    self.rsaPublicKeys = rsaPublicKeys
  }

  @discardableResult
  public func beginEmail(_ email: String, client: ClientInfo = ClientInfo()) async throws -> AuthBeginResult {
    try await begin(identifier: .email(email), client: client)
  }

  @discardableResult
  public func beginPhoneNumber(
    _ phoneNumber: String,
    client: ClientInfo = ClientInfo()
  ) async throws -> AuthBeginResult {
    try await begin(identifier: .phoneNumber(phoneNumber), client: client)
  }

  public func complete(
    code: String,
    inviteCode: String? = nil,
    timeZone: String? = nil
  ) async throws -> InlineProtocolNativeLoginResult {
    guard let pending else { throw InlineProtocolNativeLoginError.noPendingChallenge }
    log.info("Native login challenge completion started")
    var request = AuthCompleteRequest()
    request.challengeID = pending.challengeID
    request.code = code
    if let inviteCode, !inviteCode.isEmpty { request.inviteCode = inviteCode }
    if let timeZone, !timeZone.isEmpty { request.timeZone = timeZone }
    let result = try await pending.connection.authComplete(request)
    guard case let .authorized(authorized) = result.state else {
      throw InlineProtocolNativeLoginError.inviteRequired
    }
    log.info("Native login challenge authorized")
    let permanent = await pending.connection.authorization
    log.info("Creating temporary application authorization")
    let temporaryConnection = try await InlineProtocolV3Connection.connect(.init(
      url: url,
      rsaPublicKeys: rsaPublicKeys,
      temporary: true
    ))
    do {
      try await temporaryConnection.bindTemporary(to: permanent)
      log.info("Temporary application authorization bound")
      let temporary = await temporaryConnection.authorization
      try await auth.saveInlineProtocolCredentials(.init(
        userId: authorized.user.id,
        accountSessionId: authorized.accountSessionID,
        permanent: permanent,
        temporary: temporary
      ))
      log.info("Native login credentials stored")
      await temporaryConnection.close()
      await pending.connection.close()
      self.pending = nil
      log.info("Native login connections closed")
      return InlineProtocolNativeLoginResult(
        user: authorized.user,
        userId: authorized.user.id,
        accountSessionId: authorized.accountSessionID
      )
    } catch {
      log.error("Native login credential setup failed", error: error)
      await temporaryConnection.close()
      throw error
    }
  }

  public func cancel() async {
    log.info("Native login cancellation requested")
    if let pending { await pending.connection.close() }
    pending = nil
  }

  private func begin(
    identifier: AuthBeginRequest.OneOf_Identifier,
    client: ClientInfo
  ) async throws -> AuthBeginResult {
    guard !rsaPublicKeys.isEmpty else { throw InlineProtocolNativeLoginError.unavailable }
    await cancel()
    log.info("Native login permanent authorization handshake started")
    let connection = try await InlineProtocolV3Connection.connect(.init(
      url: url,
      rsaPublicKeys: rsaPublicKeys
    ))
    log.info("Native login permanent authorization handshake completed")
    do {
      var request = AuthBeginRequest()
      request.identifier = identifier
      request.client = client
      let result = try await connection.authBegin(request)
      pending = Pending(challengeID: result.challengeID, connection: connection)
      log.info("Native login challenge accepted")
      return result
    } catch {
      log.error("Native login challenge start failed", error: error)
      await connection.close()
      throw error
    }
  }
}
